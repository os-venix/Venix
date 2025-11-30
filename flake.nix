{
  description = "Venix full Nixified build: cross toolchain + kernel + sysgen disk image";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Optional: cachix for binary cache
    # cachix.url = "github:cachix/cachix";
  };

  outputs = { self, nixpkgs /*, cachix */ }: let
    pkgs = import nixpkgs { system = "x86_64-linux"; };

    # ---- Configuration ----
    target = "x86_64-venix";
    sysrootRel = ./sysroot;     # repo-local sysroot
    binutilsSrc = ./cross/binutils-gdb;
    gccSrc      = ./cross/gcc;
    kernelCrate = ./.;          # root Cargo workspace (adjust if kernel subcrate path differs)
    outDir      = "build";
    fatSizeMB   = 64;
    imgSizeMB   = 128;
    sectorStart = 2048;
    sectorSize  = 512;
    offsetBytes = sectorStart * sectorSize;

    # Helper: packages required to build + sysgen
    devDeps = with pkgs; [
      gnumake
      coreutils
      gptfdisk    # sgdisk
      dosfstools  # mkfs.fat
      mtools
      qemu
      jq
      unzip
      xz
      gzip
      bison
      flex
      gmp
      mpfr
      libmpc
      isl
      texinfo
      pkg-config
      which
      rustc
      cargo
      git
      unzip
    ];

    ################################################
    # BINUTILS derivation (reproducible)
    ################################################
    cross-binutils = pkgs.stdenv.mkDerivation rec {
      pname = "binutils-${target}";
      version = "1";
      src = binutilsSrc;
      nativeBuildInputs = with pkgs; [ gnumake bison flex texinfo pkg-config ];
      buildInputs = [ pkgs.zlib ];

      configurePhase = ''
        ./configure \
          --target=${target} \
          --prefix=$out \
          --with-sysroot=${toString sysrootRel} \
          --disable-werror \
          target_alias=${target}
      '';

      buildPhase = ''
        make -j$NIX_BUILD_CORES
      '';

      installPhase = ''
        make install
      '';

      meta = with pkgs.lib; {
        description = "binutils for ${target}";
        license = licenses.gpl2Plus;
        maintainers = [];
      };
    };

    ################################################
    # GCC derivation (reproducible)
    ################################################
    cross-gcc = pkgs.stdenv.mkDerivation rec {
      pname = "gcc-${target}";
      version = "1";
      src = gccSrc;

      nativeBuildInputs = with pkgs; [ gnumake bison flex pkg-config texinfo ];
      buildInputs = with pkgs; [ gmp mpfr libmpc isl zlib ];
      # make sure binutils we just built are available during gcc build
      nativeBuildInputs = nativeBuildInputs ++ [ cross-binutils ];

      configurePhase = ''
        ./configure \
          --target=${target} \
          --prefix=$out \
          --with-sysroot=${toString sysrootRel} \
          --enable-languages=c,c++,lto \
          target_alias=${target}
      '';

      buildPhase = ''
        # build only the pieces we need to be faster and hermetic
        make -j$NIX_BUILD_CORES all-gcc
        make -j$NIX_BUILD_CORES all-target-libgcc
        make -j$NIX_BUILD_CORES all-target-libstdc++-v3
      '';

      installPhase = ''
        make install-gcc
        make install-target-libgcc
        make install-target-libstdc++-v3
      '';

      meta = with pkgs.lib; {
        description = "gcc cross compiler for ${target}";
        license = licenses.gpl2Plus;
        maintainers = [];
      };
    };

    ################################################
    # kernel build derivation (uses Cargo, exact artifact)
    # Builds kernel via cargo and exposes the artifact as $out/kernel
    ################################################
    kernel-package = pkgs.stdenv.mkDerivation rec {
      pname = "venix-kernel";
      version = "0";

      src = kernelCrate;
      buildInputs = with pkgs; [ pkgs.rustc pkgs.cargo jq ];

      # Ensure we have a clean build dirs
      buildPhase = ''
        export CARGO_HOME=$PWD/.cargo-cache
        mkdir -p $out/bin
        # build release and capture the exact executable path from cargo messages
        cargo build --release --message-format=json -p kernel | tee cargo-msgs.json
        # use jq to extract the executable path for the kernel target
        KFILE=$$(jq -r 'select(.reason=="compiler-artifact" and .target.name=="kernel" and .executable!=null).executable' cargo-msgs.json | tail -n1)
        if [ -z "$$KFILE" ]; then
          echo "Failed to find built kernel executable in cargo output"
          exit 1
        fi
        cp "$$KFILE" $out/bin/kernel
      '';

      installPhase = ''
        # nothing else; artifact already in $out/bin
        true
      '';

      meta = with pkgs.lib; {
        description = "Built Venix kernel artifact";
        license = licenses.unfree; # adjust if needed
      };
    };

    ################################################
    # sysgen/image derivation
    # Creates GPT disk with FAT partition and copies kernel + sysroot
    ################################################
    image = pkgs.stdenv.mkDerivation rec {
      pname = "venix-image";
      version = "0";

      # dependencies required at build time for the script
      nativeBuildInputs = devDeps ++ [ cross-binutils cross-gcc ];

      # source: kernel artifact and sysroot are available via inputs
      src = ./.;

      # declare outputs: the disk image file at $out/disk.img
      phases = [ "unpackPhase" "buildPhase" ];
      unpackPhase = ''
        mkdir -p work
        cp -r ${toString sysrootRel} work/sysroot
        # bring kernel artifact
        mkdir -p work/kernel
        cp -r ${kernel-package}/bin/kernel work/kernel/kernel
        # copy scripts
        mkdir -p work/scripts
        cp -r ./scripts/* work/scripts/
      '';

      buildPhase = ''
        export IMG=$out/disk.img
        export FAT=$out/fat.part
        export SYSROOT=work/sysroot
        export KERNEL=work/kernel/kernel
        export IMG_SIZE_MB=${toString imgSizeMB}
        export FAT_SIZE_MB=${toString fatSizeMB}
        export OFFSET_BYTES=${toString offsetBytes}
        export SECTOR_START=${toString sectorStart}
        mkdir -p $out
        chmod +x work/scripts/sysgen.sh
        work/scripts/sysgen.sh
        echo "Produced image at $IMG"
      '';

      installPhase = '' ; # nothing
      meta = with pkgs.lib; {
        description = "GPT disk image containing boot FAT partition and Venix kernel";
      };
    };

  in {
    packages.x86_64-linux = {
      cross-binutils = cross-binutils;
      cross-gcc      = cross-gcc;
      kernel         = kernel-package;
      image          = image;
    };

    devShells.x86_64-linux.default = pkgs.mkShell {
      buildInputs = [ cross-binutils cross-gcc kernel-package pkgs.qemu pkgs.mtools pkgs.gptfdisk pkgs.dosfstools pkgs.jq ];
      shellHook = ''
        echo "Venix dev shell: cross toolchain and kernel available in environment"
        echo "To build everything: nix build .#image"
        echo "To enter a shell: nix develop"
      '';
    };

    # convenience: defaultPackage points to image
    defaultPackage.x86_64-linux = image;
  }
}
