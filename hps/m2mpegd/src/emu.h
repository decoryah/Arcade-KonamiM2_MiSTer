// emu.h for the standalone decoder: the one thing 3dom2_mpeg.cpp takes from MAME's emu.h. The decoder comes from the M2 work in
// MAME (the M2 emulator's 3dom2_mpeg.cpp) and has m2mpegd-only parts: the two-thread split, marked "m2mpegd only (not in MAME)".
// BIT as in MAME's src/lib/util/coretmpl.h.
#ifndef M2MPEGD_EMU_H
#define M2MPEGD_EMU_H

template <typename T, typename U> constexpr T BIT(T x, U n) noexcept { return (x >> n) & T(1); }

#endif
