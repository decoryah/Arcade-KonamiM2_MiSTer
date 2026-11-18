#!/bin/bash
# build_arm.sh: build/m2mpegd, the MPEG daemon for the MiSTer's Cortex-A9 (DE10-Nano): static, NEON (M2MPEGD_FAST: the NEON
# output formatter), no fused multiply-add (-ffp-contract=off: the pixels are the emulator's, bit for bit; the A9's VFPv3 has no
# fused instructions anyway). Run on a Linux PC or in WSL: bash hps/m2mpegd/build_arm.sh
# Compiler: Ubuntu's arm-linux-gnueabihf-g++ (apt install g++-arm-linux-gnueabihf).
set -e
cd "$(dirname "$0")"
mkdir -p build
arm-linux-gnueabihf-g++ --version | head -1
F="-std=c++17 -O3 -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard -ffp-contract=off -Wall -Wno-psabi -static -Isrc"
arm-linux-gnueabihf-g++ $F -DM2MPEGD_FAST -o build/m2mpegd src/m2mpegd.cpp src/m2mpegd_core.cpp src/m2mpeg_unit.cpp src/3dom2_mpeg.cpp
ls -la build/m2mpegd
