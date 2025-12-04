# Venix

Venix is a Unix-like OS written in Rust. It aims to be reasonably familiar to Unix users, though not POSIX-complete.

Venix is my hobby project :3

## Building

### Prerequisites
- Standard dev tools (coreutils, binutils, gcc, etc)
- Rust (via `rustup`)
- QEMU (necessary to run in a VM)
- Meson, ninja (necessary to build the C standard library Venix uses)
- sgdisk and mtools (necessary to build a filesystem image)

### Build and run

`$ make run` will compile the OS, build a system image, and run it in QEMU.

This will:
1.  Build the custom cross-compiler toolchain (requires a complete build of GCC and binutils. This is *slow*, but only happens once).
1.  Build the kernel.
1.  Build the C standard library.
1.  Build ported software.
1.  Assemble a bootable disk image.
1.  Launch Venix in a QEMU VM.

## Ported software

*  zsh
*  ncurses
