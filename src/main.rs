fn main() {
    // read env variables that were set in build script
    let uefi_path = env!("UEFI_PATH");

    let mut cmd = std::process::Command::new("qemu-system-x86_64");
    cmd.arg("-bios").arg(ovmf_prebuilt::ovmf_pure_efi());
    cmd.arg("-drive").arg(format!("format=raw,file={uefi_path}"));
    cmd.arg("-accel").arg("kvm");
//    cmd.arg("-no-reboot");
    cmd.arg("-d").arg("int,page");
    //    cmd.arg("-s").arg("-S");
//    cmd.arg("-action").arg("reboot=shutdown,shutdown=pause");

    let mut child = cmd.spawn().unwrap();
    child.wait().unwrap();
}
