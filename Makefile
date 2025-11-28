### ============================================================
### Configuration
### ============================================================

IMG         := build/disk.img
FAT         := build/fat.part
SYSROOT     := sysroot
IMG_SIZE_MB := 512
FAT_SIZE_MB := 256
KERNEL_PATH := build/kernel

# GPT partition begins at LBA 2048
OFFSET_BYTES := $(shell echo $$((2048 * 512)))

QEMU := qemu-system-x86_64
QEMU_ARGS := \
    -bios /usr/share/OVMF/OVMF_CODE.fd \
    -drive file=$(IMG),format=raw \
    -accel kvm \
    -no-reboot \
    -m 1024 \
    -usb -device usb-kbd

### ============================================================
### Top-level targets
### ============================================================

all: $(IMG)

run: $(IMG)
	$(QEMU) $(QEMU_ARGS)

### ============================================================
### Build OS via Cargo
### ============================================================

# Adjust the target triple if needed
build-kernel:
# First build normally, outputting normally. Else the pipe swallows error output
	@cargo build --release

# Now attempt to do the copy
	@KERNEL_BUILD_PATH="$$(cargo build --release --message-format=json \
		| jq -r 'select(.reason=="compiler-artifact" and .target.name=="kernel" and .executable!=null).executable' \
		| tail -n 1)"; \
	mkdir -p build; \
	cp "$$KERNEL_BUILD_PATH" $(KERNEL_PATH)

### ============================================================
### Create disk image + FAT32 partition + copy sysroot + kernel
### ============================================================

$(IMG): $(SYSROOT) build-kernel
	@rm -f $(IMG) $(FAT)

	@echo "=== Creating empty GPT disk image ==="
	@truncate -s $(IMG_SIZE_MB)M $(IMG)

	@sgdisk $(IMG) \
	  --clear \
	  --new=1:2048:$$((2048 + $(FAT_SIZE_MB)*2048 - 1)) \
	  --typecode=1:EF00 \
	  --change-name=1:"boot"

	@echo "=== Creating FAT16 filesystem ==="
	@truncate -s $(FAT_SIZE_MB)M $(FAT)
	@mkfs.fat -F 16 -n "BOOT       " $(FAT)

	@echo "=== Writing mtools config ==="
	@echo 'drive x: file="$(FAT)" offset=0' > build/mtools.conf

	@echo "=== Copying sysroot ==="
	@MTOOLSRC=build/mtools.conf mcopy -s -D s $(SYSROOT)/* x:/ || true

	@echo "=== Copying kernel image ==="
	@test -n "$(KERNEL_PATH)"  # ensure kernel exists
	@MTOOLSRC=build/mtools.conf mcopy $(KERNEL_PATH) x:/boot/kernel

	@echo "=== Embedding FAT partition into GPT image ==="
	@dd if=$(FAT) of=$(IMG) bs=4096 seek=$$((OFFSET_BYTES / 4096)) conv=notrunc status=none

	@echo "=== Sysgen complete: $(IMG) ==="

### ============================================================
### Cleanup
### ============================================================

clean:
	rm -rf build target

.PHONY: all run build-kernel sysgen clean
