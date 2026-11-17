#!/bin/bash
# kprep515.sh [CONFIG [WORK]]: m2_mem_wc.ko for the MiSTer kernel 5.15.1-MiSTer, built as that kernel was built (as kprep618.sh
# does for 6.18.38).
#   CONFIG  the kernel's own configuration (default: config-5.15.1-MiSTer here, a 5.15.1-MiSTer board's /proc/config.gz)
#   WORK    where the downloads, the kernel tree and the build go (default ~/m2mpegd_kernel)
# In WORK: the compiler that config names (Arm GNU Toolchain 10.2-2020.11, arm-none-linux-gnueabihf, x86_64 host; checked against
# Arm's published checksum), the MiSTer kernel source NDS4MiSTer pins for 5.15.1 (Linux-Kernel_MiSTer 794e6f00, the archive's
# sha256 from its kernel/nds_mem_wc/BUILD_PROVENANCE.json), CONFIG, olddefconfig (the config should come out unchanged),
# modules_prepare and the module: WORK/m2_mem_wc-5.15.1-MiSTer.ko, the name m2mpegd_service.sh loads.
# Needs a Linux PC or WSL with make, gcc, flex, bison, libssl-dev, libelf-dev, curl.
set -e
M=$(cd "$(dirname "$0")" && pwd)
CONFIG=$(readlink -f "${1:-$M/config-5.15.1-MiSTer}")
W=${2:-$HOME/m2mpegd_kernel}
REL=5.15.1-MiSTer
SRC=794e6f002d0f655c504733c126a01f8c1f0bc1d4
SHA=fc95ec23ce16d3f1662ba22cdf3b5730ef6a0c8c6fe796013aaf4ebb6c20d401

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
# (wmb() is the module's M2_MEM_WC_SYNC: on this kernel it calls arm_heavy_mb, which must be exported)
grep -q "EXPORT_SYMBOL(arm_heavy_mb)" arch/arm/mm/flush.c && echo "arm_heavy_mb exported" || echo "arm_heavy_mb not exported here"

# (KBUILD_MODPOST_WARN=1, as NDS4MiSTer's build: modules_prepare makes no Module.symvers, and the MiSTer kernel has
# CONFIG_MODVERSIONS off, so the module's symbols are found by name when it loads)
B=$W/m2_mem_wc-$REL; mkdir -p $B; cp "$M/m2_mem_wc.c" "$M/Makefile" $B/
cd $B && make KDIR=$K/tree CROSS_COMPILE=arm-none-linux-gnueabihf- KBUILD_MODPOST_WARN=1 > build.log 2>&1 \
  || { echo "module build failed: $B/build.log"; tail -20 build.log; exit 1; }
cp m2_mem_wc.ko $W/m2_mem_wc-$REL.ko
strings m2_mem_wc.ko | grep -E "^vermagic="
sha256sum $W/m2_mem_wc-$REL.ko
