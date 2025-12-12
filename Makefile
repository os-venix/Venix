### ============================================================
### Configuration
### ============================================================

IMG         := build/disk.img
FAT         := build/fat.part
TOOLS       := build/tools
GCC         := build/tools/bin/x86_64-unknown-venix-gcc
BINUTILS    := build/tools/bin/x86_64-unknown-venix-nm
SYSROOT     := $(shell echo `pwd`/build/sysroot)
IMG_SIZE_MB := 512
FAT_SIZE_MB := 256
KERNEL_PATH := build/kernel

BUILD_PROCESS_PATH := build
BUILD_TOOLS_PATH := $(shell echo `pwd`/build/tools)
CROSS_DIRECTORY := $(shell echo `pwd`/cross)
SW_DIRECTORY := $(shell echo `pwd`/sw)
PATCHES_DIR := $(shell echo `pwd`/patches)
ASSETS_DIR := $(shell echo `pwd`/assets)

# GPT partition begins at LBA 2048
OFFSET_BYTES := $(shell echo $$((2048 * 512)))

QEMU := qemu-system-x86_64
QEMU_ARGS := \
    -bios $(ASSETS_DIR)/OVMF_CODE.fd \
    -drive file=$(IMG),format=raw \
    -accel kvm \
    -no-reboot \
    -m 1024 \
    -usb -device usb-kbd

# Stamp files
BUILD_MLIBC_HEADERS_STAMP := $(BUILD_PROCESS_PATH)/build/mlibc-headers/.built
BUILD_NCURSES_STAMP := $(BUILD_PROCESS_PATH)/build/ncurses/.built
BUILD_ZSH_STAMP := $(BUILD_PROCESS_PATH)/build/zsh/.built

### ============================================================
### Top-level targets
### ============================================================

all: $(IMG)

$(SYSROOT):
	@mkdir -p $(SYSROOT)/boot/limine
	@mkdir -p $(SYSROOT)/efi/boot

	@cp assets/limine.conf $(SYSROOT)/boot/limine/limine.conf
	@cp assets/BOOTX64.EFI $(SYSROOT)/efi/boot/BOOTX64.EFI

	@mkdir -p $(BUILD_TOOLS_PATH)

run: $(IMG)
	$(QEMU) $(QEMU_ARGS)

### ============================================================
### Build mlibc headers for cross-compilation
### ============================================================
$(BUILD_MLIBC_HEADERS_STAMP): $(SYSROOT)
	@echo "=== Building mlibc headers ==="
	@mkdir -p $(BUILD_PROCESS_PATH)/build/mlibc-headers
	@cd $(BUILD_PROCESS_PATH)/build/mlibc-headers && \
		meson setup $(CROSS_DIRECTORY)/mlibc \
			--prefix=$(SYSROOT)/usr \
			--cross-file=$(CROSS_DIRECTORY)/mlibc/x86_64-venix.txt \
			-Dheaders_only=true && \
		meson compile && \
		meson install
	@touch $@

### ============================================================
### Build binutils for cross-compilation
### ============================================================
$(BINUTILS): $(SYSROOT) $(BUILD_TOOLS_PATH) $(BUILD_MLIBC_HEADERS_STAMP)
	@echo "=== Building cross binutils ==="
	@mkdir -p $(BUILD_PROCESS_PATH)/build/binutils
	@cd $(BUILD_PROCESS_PATH)/build/binutils && \
		$(CROSS_DIRECTORY)/binutils-gdb/configure \
			--target=x86_64-unknown-venix \
			--prefix=$(BUILD_TOOLS_PATH) \
			--with-sysroot=$(SYSROOT) \
			--disable-werror \
			--disable-nls && \
		make all -j8 && \
		make install
	# @mkdir -p $(BUILD_PROCESS_PATH)/build/gdb
	# @cd $(BUILD_PROCESS_PATH)/build/gdb && \
	# 	$(CROSS_DIRECTORY)/binutils-gdb/gdb/configure \
	# 		--target=x86_64-unknown-venix \
	# 		--prefix=$(BUILD_TOOLS_PATH) \
	# 		--disable-werror && \
	# 	make all-gdb -j8 && \
	# 	make install-gdb

### ============================================================
### Build GCC for cross-compilation
### ============================================================
$(GCC): $(SYSROOT) $(BUILD_TOOLS_PATH) $(BINUTILS) $(BUILD_MLIBC_HEADERS_STAMP)
	@echo "=== Building cross GCC ==="
	@mkdir -p $(BUILD_PROCESS_PATH)/build/gcc
	@cd $(BUILD_PROCESS_PATH)/build/gcc && \
		$(CROSS_DIRECTORY)/gcc/configure \
			--target=x86_64-unknown-venix \
			--prefix=$(BUILD_TOOLS_PATH) \
			--with-sysroot=$(SYSROOT) \
			--enable-languages=c,c++,lto && \
		make all-gcc -j8 && \
		make install-gcc && \
		make all-target-libgcc -j8 && \
		make install-target-libgcc \
		# make all-target-libstdc++-v3 -j8 && \
		# make install-target-libstdc++-v3

### ============================================================
### Build mlibc headers for cross-compilation
### ============================================================
mlibc-lib: $(SYSROOT) $(GCC) $(BINUTILS)
	@echo "=== Building mlibc ==="
	@mkdir -p $(BUILD_PROCESS_PATH)/build/mlibc-library
	@cd $(BUILD_PROCESS_PATH)/build/mlibc-library && \
		meson setup \
			--prefix=$(SYSROOT)/usr \
			--cross-file=$(CROSS_DIRECTORY)/mlibc/x86_64-venix.txt \
			-Dheaders_only=false \
			$(CROSS_DIRECTORY)/mlibc && \
		meson compile && \
		meson install

### ============================================================
### Build OS via Cargo
### ============================================================

build-kernel:
# First build normally, outputting normally. Else the pipe swallows error output
	@TMPDIR=`pwd`/build CARGO_MANIFEST_DIR=`pwd`/kernel cargo -C kernel -Z unstable-options build --release

# Now attempt to do the copy
	@KERNEL_BUILD_PATH="$$(TMPDIR=`pwd`/build CARGO_MANIFEST_DIR=`pwd`/kernel cargo -C kernel -Z unstable-options build --release --message-format=json \
		| jq -r 'select(.reason=="compiler-artifact" and .target.name=="kernel" and .executable!=null).executable' \
		| tail -n 1)"; \
	mkdir -p build; \
	cp "$$KERNEL_BUILD_PATH" $(KERNEL_PATH)

$(BUILD_NCURSES_STAMP): $(GCC) $(BINUTILS) $(SYSROOT)
	@echo "=== Building ncurses ==="
	@mkdir -p $(BUILD_PROCESS_PATH)/build/ncurses

	@PATH=$PATH:$(TOOLS) cd $(SW_DIRECTORY)/ncurses && \
		patch -p1 < $(PATCHES_DIR)/ncurses.patch && \
		CC=$(BUILD_TOOLS_PATH)/bin/x86_64-unknown-venix-gcc \
		CXX=$(BUILD_TOOLS_PATH)/bin/x86_64-unknown-venix-g++ \
		AR=$(BUILD_TOOLS_PATH)/bin/x86_64-unknown-venix-ar \
		RANLIB=$(BUILD_TOOLS_PATH)/bin/x86_64-unknown-venix-ranlib \
		LD=$(BUILD_TOOLS_PATH)/bin/x86_64-unknown-venix-ld \
		$(SW_DIRECTORY)/ncurses/configure \
			--prefix=$(SYSROOT)/usr \
			--host=x86_64-linux \
			--build=x86_64-unknown-venix \
			--without-cxx-binding && \
		make -j8 && \
		make install
	touch $@

$(BUILD_ZSH_STAMP): $(BUILD_NCURSES_STAMP) $(GCC) $(BINUTILS) $(SYSROOT)
	@echo "=== Building zsh ==="
	@mkdir -p $(BUILD_PROCESS_PATH)/build/zsh

	@PATH=$PATH:$(TOOLS) cd $(SW_DIRECTORY)/zsh && \
		patch -p1 < $(PATCHES_DIR)/zsh.patch && \
		$(SW_DIRECTORY)/zsh/Util/preconfig && \
		CC=$(BUILD_TOOLS_PATH)/bin/x86_64-unknown-venix-gcc \
		CXX=$(BUILD_TOOLS_PATH)/bin/x86_64-unknown-venix-g++ \
		AR=$(BUILD_TOOLS_PATH)/bin/x86_64-unknown-venix-ar \
		RANLIB=$(BUILD_TOOLS_PATH)/bin/x86_64-unknown-venix-ranlib \
		LD=$(BUILD_TOOLS_PATH)/bin/x86_64-unknown-venix-ld \
		$(SW_DIRECTORY)/zsh/configure \
			--with-sysroot=$(SYSROOT) \
			--host=x86_64-linux \
			--build=x86_64-venix \
			--prefix=$(SYSROOT)/usr \
			--disable-doc \
			--without-cxx-binding && \
		make -j8 && \
		make install.bin && \
		make install.modules
	touch $@

build-init: $(GCC) $(BINUTILS) $(SYSROOT)
	@echo "=== Building init ==="
	@mkdir -p $(BUILD_PROCESS_PATH)/build/init

	@PATH=$(PATH):$(TOOLS) \
		CC=$(BUILD_TOOLS_PATH)/bin/x86_64-unknown-venix-gcc \
		CXX=$(BUILD_TOOLS_PATH)/bin/x86_64-unknown-venix-g++ \
		AR=$(BUILD_TOOLS_PATH)/bin/x86_64-unknown-venix-ar \
		RANLIB=$(BUILD_TOOLS_PATH)/bin/x86_64-unknown-venix-ranlib \
		LD=$(BUILD_TOOLS_PATH)/bin/x86_64-unknown-venix-ld \
		OUTDIR=$(SYSROOT)/usr/bin \
		BUILDDIR=$(BUILD_PROCESS_PATH)/build/init \
		SYSROOT=$(SYSROOT) \
		make -C sw/init all

### ============================================================
### Create disk image + FAT32 partition + copy sysroot + kernel
### ============================================================

$(IMG): $(SYSROOT) $(BUILD_ZSH_STAMP) build-kernel mlibc-lib build-init
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
	@dd if=$(FAT) of=$(IMG) bs=2048 seek=512 conv=notrunc status=none

	@echo "=== Sysgen complete: $(IMG) ==="

### ============================================================
### Cleanup
### ============================================================

clean:
	rm -rf build target

.PHONY: all run build-kernel sysgen clean build-init
