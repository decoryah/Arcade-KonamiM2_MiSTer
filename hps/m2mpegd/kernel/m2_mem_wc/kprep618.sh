#!/bin/bash
# kprep618.sh CONFIG [WORK]: m2_mem_wc.ko for the MiSTer kernel 6.18.38-MiSTer, built as that kernel was built (as NDS4MiSTer's
# build-release-6.18.sh builds its nds_mem_wc).
#   CONFIG  the kernel's own configuration: on the MiSTer, zcat /proc/config.gz (it is the same as NDS4MiSTer's saved
#           config-6.18.38-MiSTer)
#   WORK    where the downloads, the kernel tree and the build go (default ~/m2mpegd_kernel)
# In WORK: the compiler the kernel was built with (Arm GNU Toolchain 10.2-2020.11, arm-none-linux-gnueabihf, x86_64 host; checked
# against Arm's published checksum), the MiSTer kernel source NDS4MiSTer pins for 6.18.38 (Linux-Kernel_MiSTer 6a581bac, the
# archive's sha256 checked), CONFIG, olddefconfig (the config should come out unchanged), modules_prepare and the module:
# WORK/m2_mem_wc-6.18.38-MiSTer.ko, the name m2mpegd_service.sh loads.
# Needs a Linux PC or WSL with make, gcc, flex, bison, libssl-dev, libelf-dev, curl. Built with another compiler (e.g. Ubuntu's
# arm-linux-gnueabihf-gcc 13), olddefconfig changes the config (CONFIG_STACKPROTECTOR_PER_TASK, the asm-goto settings): an ABI
# the running kernel doesn't have. Don't load a module built that way.
set -e
CONFIG=$(readlink -f "${1:?usage: kprep618.sh CONFIG [WORK]}")
W=${2:-$HOME/m2mpegd_kernel}
M=$(cd "$(dirname "$0")" && pwd)
REL=6.18.38-MiSTer
SRC=6a581bac47c32dfd2525f9874fd263cf08058610
SHA=aa6c25d30b4de85022f65f6a3a626dd071343339a9fc4106f0b713439c03fe14

T=$W/toolchains; N=gcc-arm-10.2-2020.11-x86_64-arm-none-linux-gnueabihf
U=https://developer.arm.com/-/media/Files/downloads/gnu-a/10.2-2020.11/binrel
mkdir -p $T; cd $T
if [ ! -d $N ]; then
  [ -f $N.tar.xz ] || curl -sfL -o $N.tar.xz $U/$N.tar.xz
  curl -sfL -o $N.tar.xz.sha256asc $U/$N.tar.xz.sha256asc || true
  # (Arm's ".sha256asc" for this release holds an MD5, 32 digits: 14f706db78cfb43aafed9056174572b0)
  [ -s $N.tar.xz.sha256asc ] && [ "$(cut -c1-32 $N.tar.xz.sha256asc)" = "$(md5sum $N.tar.xz | cut -c1-32)" ] \
    || { echo "the toolchain's checksum isn't confirmed: stopping"; exit 1; }
  tar -xJf $N.tar.xz
fi
export PATH=$T/$N/bin:$PATH ARCH=arm CROSS_COMPILE=arm-none-linux-gnueabihf- LOCALVERSION=-MiSTer
arm-none-linux-gnueabihf-gcc --version | head -1

K=$W/kernel-$REL; mkdir -p $K; cd $K
[ -f src.tar.gz ] || curl -sfL -o src.tar.gz https://codeload.github.com/MiSTer-devel/Linux-Kernel_MiSTer/tar.gz/$SRC
echo "$SHA  src.tar.gz" | sha256sum -c - || exit 1
[ -d tree ] || { mkdir tree && tar -xzf src.tar.gz -C tree --strip-components=1; }
cd tree
cp "$CONFIG" .config
make olddefconfig > ../olddefconfig.log 2>&1
diff <(grep -v "^#" "$CONFIG" | grep .) <(grep -v "^#" .config | grep .) > ../configdiff.txt || true
echo "config lines changed by olddefconfig: $(grep -c '^[<>]' ../configdiff.txt || true) (should be 0; $K/configdiff.txt)"
make -j"$(nproc)" modules_prepare > ../prepare.log 2>&1 || { echo "modules_prepare failed: $K/prepare.log"; exit 1; }
r=$(make -s kernelrelease); echo "kernelrelease: $r"
[ "$r" = "$REL" ] || { echo "not $REL: stopping"; exit 1; }

# (KBUILD_MODPOST_WARN=1, as NDS4MiSTer's build: modules_prepare makes no Module.symvers, and the MiSTer kernel has
# CONFIG_MODVERSIONS off, so the module's symbols are found by name when it loads)
B=$W/m2_mem_wc-$REL; mkdir -p $B; cp "$M/m2_mem_wc.c" "$M/Makefile" $B/
cd $B && make KDIR=$K/tree CROSS_COMPILE=arm-none-linux-gnueabihf- KBUILD_MODPOST_WARN=1 > build.log 2>&1 \
  || { echo "module build failed: $B/build.log"; tail -20 build.log; exit 1; }
cp m2_mem_wc.ko $W/m2_mem_wc-$REL.ko
strings m2_mem_wc.ko | grep -E "^vermagic="
sha256sum $W/m2_mem_wc-$REL.ko
