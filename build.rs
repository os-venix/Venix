#![feature(exit_status_error)]

use anyhow::Context;
use std::{
    collections::BTreeMap,
    fs::{self, File},
    io::{self, Seek},
    path::{Path, PathBuf},
};
use tempfile::NamedTempFile;
use walkdir::WalkDir;

pub fn create_fat_filesystem(
    files: BTreeMap<String, File>,
    out_fat_path: &Path,
    volume_label: [u8; 11]
) -> anyhow::Result<()> {
    const MB: u64 = 1024 * 1024;

    // calculate needed size
    let mut needed_size = 0;
    for source in files.values() {
        needed_size += source.metadata()?.len();
    }

    // create new filesystem image file at the given path and set its length
    let fat_file = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(true)
        .open(out_fat_path)
        .unwrap();
    let fat_size_padded_and_rounded = ((needed_size + 1024 * 64 - 1) / MB + 1) * MB + MB;
    fat_file.set_len(fat_size_padded_and_rounded).unwrap();

    // format the file system and open it
    let format_options = fatfs::FormatVolumeOptions::new().volume_label(volume_label);
    fatfs::format_volume(&fat_file, format_options).context("Failed to format FAT file")?;
    let filesystem = fatfs::FileSystem::new(&fat_file, fatfs::FsOptions::new())
        .context("Failed to open FAT file system of UEFI FAT file")?;
    let root_dir = filesystem.root_dir();

    // copy files to file system    
    for (target_path_raw, mut source) in files {
        let target_path = Path::new(&target_path_raw);
        // create parent directories
        let ancestors: Vec<_> = target_path.ancestors().skip(1).collect();
        for ancestor in ancestors.into_iter().rev().skip(1) {
            root_dir
                .create_dir(&ancestor.display().to_string())
                .with_context(|| {
                    format!(
                        "failed to create directory `{}` on FAT filesystem",
                        ancestor.display()
                    )
                })?;
        }

        let mut new_file = root_dir
            .create_file(&target_path_raw)
            .with_context(|| format!("failed to create file at `{}`", target_path.display()))?;
        new_file.truncate().unwrap();

        io::copy(&mut source, &mut new_file).with_context(|| {
            format!(
                "failed to copy source data `{:?}` to file at `{}`",
                source,
                target_path.display()
            )
        })?;
    }

    Ok(())
}

pub fn create_gpt_disk(fat_image: &Path, out_gpt_path: &Path) -> anyhow::Result<()> {
    // create new file
    let mut disk = fs::OpenOptions::new()
        .create(true)
        .truncate(true)
        .read(true)
        .write(true)
        .open(out_gpt_path)
        .with_context(|| format!("failed to create GPT file at `{}`", out_gpt_path.display()))?;

    // set file size
    let partition_size: u64 = fs::metadata(fat_image)
        .context("failed to read metadata of fat image")?
        .len();
    let disk_size = partition_size + 1024 * 64; // for GPT headers
    disk.set_len(disk_size)
        .context("failed to set GPT image file length")?;

    // create a protective MBR at LBA0 so that disk is not considered
    // unformatted on BIOS systems
    let mbr = gpt::mbr::ProtectiveMBR::with_lb_size(
        u32::try_from((disk_size / 512) - 1).unwrap_or(0xFF_FF_FF_FF),
    );
    mbr.overwrite_lba0(&mut disk)
        .context("failed to write protective MBR")?;

    // create new GPT structure
    let block_size = gpt::disk::LogicalBlockSize::Lb512;
    let mut gpt = gpt::GptConfig::new()
        .writable(true)
        .initialized(false)
        .logical_block_size(block_size)
        .create_from_device(Box::new(&mut disk), None)
        .context("failed to create GPT structure in file")?;
    gpt.update_partitions(Default::default())
        .context("failed to update GPT partitions")?;

    // add new EFI system partition and get its byte offset in the file
    let partition_id = gpt
        .add_partition("boot", partition_size, gpt::partition_types::EFI, 0, None)
        .context("failed to add boot EFI partition")?;
    let partition = gpt
        .partitions()
        .get(&partition_id)
        .context("failed to open boot partition after creation")?;
    let start_offset = partition
        .bytes_start(block_size)
        .context("failed to get start offset of boot partition")?;

    // close the GPT structure and write out changes
    gpt.write().context("failed to write out GPT changes")?;

    // place the FAT filesystem in the newly created partition
    disk.seek(io::SeekFrom::Start(start_offset))
        .context("failed to seek to start offset")?;
    io::copy(
        &mut File::open(fat_image).context("failed to open FAT image")?,
        &mut disk,
    )
    .context("failed to copy FAT image to GPT disk")?;

    Ok(())
}

fn main() {
    // set by cargo, build scripts should use this directory for output files
    let out_dir = PathBuf::from(std::env::var_os("OUT_DIR").unwrap());
    // set by cargo's artifact dependency feature, see
    // https://doc.rust-lang.org/nightly/cargo/reference/unstable.html#artifact-dependencies
    let kernel = PathBuf::from(std::env::var_os("CARGO_BIN_FILE_KERNEL_kernel").unwrap());
    // let init = PathBuf::from(std::env::var_os("CARGO_BIN_FILE_INIT_init").unwrap());
    let init = PathBuf::from("tmpcinit/init");
    let test = PathBuf::from("tmpcinit/test");

    let mut files: BTreeMap<String, File> = BTreeMap::new();
    files.insert("boot/kernel".to_string(), File::open(kernel).expect("Unable to open kernel file"));
    files.insert("init/init".to_string(), File::open(init).expect("Unable to open init"));
    files.insert("bin/test".to_string(), File::open(test).expect("Unable to open test"));

    for entry in WalkDir::new("sysroot") {
	let entry = entry.unwrap();
	if !entry.file_type().is_file() {
	    continue;
	}

	let path = entry.path().to_str().unwrap().strip_prefix("sysroot/").unwrap().to_string();

	files.insert(
	    path,
	    File::open(entry.path()).expect(&format!("Unable to open {}", entry.path().display())));
    }

    let uefi_path = out_dir.join("uefi.img");

    let fat_out_file = NamedTempFile::new().context("Failed to create temp file").unwrap();
    create_fat_filesystem(files, fat_out_file.path(), *b"BOOT       ")
	.context("Failed to create FAT filesystem")
	.unwrap();
    create_gpt_disk(fat_out_file.path(), uefi_path.as_path())
	.context("Failed to create GPT image")
	.unwrap();
    fat_out_file
	.close()
	.context("Failed to delete FAT partition after disk image creation")
	.unwrap();

    // pass the disk image paths as env variables to the `main.rs`
    println!("cargo:rustc-env=UEFI_PATH={}", uefi_path.display());
}
