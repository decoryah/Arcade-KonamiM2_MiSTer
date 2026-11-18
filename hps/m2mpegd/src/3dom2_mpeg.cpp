// license:BSD-3-Clause
// copyright-holders:Philip Bennett
/***************************************************************************

    3DO M2 MPEG unit: MPEG-1 video picture decoder (ISO 11172-2)

    Decodes the slice data of an I, P or B picture. The M2 driver parses
    the sequence, GOP and picture headers itself and gives the unit the
    picture's parameters through registers.

***************************************************************************/

#include "emu.h"
#include "3dom2_mpeg.h"

#include <algorithm>
#include <cmath>
#include <cstring>

#if defined(M2MPEGD_FAST_IDCT) && defined(__ARM_NEON)
#include <arm_neon.h>
#endif


namespace {

// Variable length codes (ISO 11172-2 Annex B)
struct mpeg_vlc { uint16_t code; uint8_t len; uint8_t a; uint8_t b; };

const mpeg_vlc s_mb_addr_inc[] =
{
	{ 0x1, 1, 1 }, { 0x3, 3, 2 }, { 0x2, 3, 3 }, { 0x3, 4, 4 }, { 0x2, 4, 5 }, { 0x3, 5, 6 }, { 0x2, 5, 7 },
	{ 0x7, 7, 8 }, { 0x6, 7, 9 }, { 0xb, 8, 10 }, { 0xa, 8, 11 }, { 0x9, 8, 12 }, { 0x8, 8, 13 },
	{ 0x7, 8, 14 }, { 0x6, 8, 15 }, { 0x17, 10, 16 }, { 0x16, 10, 17 }, { 0x15, 10, 18 }, { 0x14, 10, 19 },
	{ 0x13, 10, 20 }, { 0x12, 10, 21 }, { 0x23, 11, 22 }, { 0x22, 11, 23 }, { 0x21, 11, 24 },
	{ 0x20, 11, 25 }, { 0x1f, 11, 26 }, { 0x1e, 11, 27 }, { 0x1d, 11, 28 }, { 0x1c, 11, 29 },
	{ 0x1b, 11, 30 }, { 0x1a, 11, 31 }, { 0x19, 11, 32 }, { 0x18, 11, 33 },
};

// Macroblock type flags
enum : uint8_t
{
	MB_INTRA    = 0x01,
	MB_PATTERN  = 0x02,
	MB_BACKWARD = 0x04,
	MB_FORWARD  = 0x08,
	MB_QUANT    = 0x10
};

const mpeg_vlc s_mb_type_i[] =
{
	{ 0x1, 1, MB_INTRA }, { 0x1, 2, MB_QUANT | MB_INTRA },
};

const mpeg_vlc s_mb_type_p[] =
{
	{ 0x1, 1, MB_FORWARD | MB_PATTERN }, { 0x1, 2, MB_PATTERN }, { 0x1, 3, MB_FORWARD },
	{ 0x3, 5, MB_INTRA }, { 0x2, 5, MB_QUANT | MB_FORWARD | MB_PATTERN }, { 0x1, 5, MB_QUANT | MB_PATTERN },
	{ 0x1, 6, MB_QUANT | MB_INTRA },
};

const mpeg_vlc s_mb_type_b[] =
{
	{ 0x2, 2, MB_FORWARD | MB_BACKWARD }, { 0x3, 2, MB_FORWARD | MB_BACKWARD | MB_PATTERN },
	{ 0x2, 3, MB_BACKWARD }, { 0x3, 3, MB_BACKWARD | MB_PATTERN },
	{ 0x2, 4, MB_FORWARD }, { 0x3, 4, MB_FORWARD | MB_PATTERN },
	{ 0x3, 5, MB_INTRA }, { 0x2, 5, MB_QUANT | MB_FORWARD | MB_BACKWARD | MB_PATTERN },
	{ 0x3, 6, MB_QUANT | MB_FORWARD | MB_PATTERN }, { 0x2, 6, MB_QUANT | MB_BACKWARD | MB_PATTERN },
	{ 0x1, 6, MB_QUANT | MB_INTRA },
};

// motion_code: magnitude, negative
const mpeg_vlc s_motion_code[] =
{
	{ 0x1, 1, 0 },
	{ 0x2, 3, 1 }, { 0x3, 3, 1, 1 }, { 0x2, 4, 2 }, { 0x3, 4, 2, 1 }, { 0x2, 5, 3 }, { 0x3, 5, 3, 1 },
	{ 0x6, 7, 4 }, { 0x7, 7, 4, 1 }, { 0xa, 8, 5 }, { 0xb, 8, 5, 1 }, { 0x8, 8, 6 }, { 0x9, 8, 6, 1 },
	{ 0x6, 8, 7 }, { 0x7, 8, 7, 1 }, { 0x16, 10, 8 }, { 0x17, 10, 8, 1 }, { 0x14, 10, 9 }, { 0x15, 10, 9, 1 },
	{ 0x12, 10, 10 }, { 0x13, 10, 10, 1 }, { 0x22, 11, 11 }, { 0x23, 11, 11, 1 }, { 0x20, 11, 12 },
	{ 0x21, 11, 12, 1 }, { 0x1e, 11, 13 }, { 0x1f, 11, 13, 1 }, { 0x1c, 11, 14 }, { 0x1d, 11, 14, 1 },
	{ 0x1a, 11, 15 }, { 0x1b, 11, 15, 1 }, { 0x18, 11, 16 }, { 0x19, 11, 16, 1 },
};

const mpeg_vlc s_coded_block_pattern[] =
{
	{ 0x7, 3, 60 }, { 0xd, 4, 4 }, { 0xc, 4, 8 }, { 0xb, 4, 16 }, { 0xa, 4, 32 },
	{ 0x13, 5, 12 }, { 0x12, 5, 48 }, { 0x11, 5, 20 }, { 0x10, 5, 40 }, { 0xf, 5, 28 }, { 0xe, 5, 44 },
	{ 0xd, 5, 52 }, { 0xc, 5, 56 }, { 0xb, 5, 1 }, { 0xa, 5, 61 }, { 0x9, 5, 2 }, { 0x8, 5, 62 },
	{ 0xf, 6, 24 }, { 0xe, 6, 36 }, { 0xd, 6, 3 }, { 0xc, 6, 63 },
	{ 0x17, 7, 5 }, { 0x16, 7, 9 }, { 0x15, 7, 17 }, { 0x14, 7, 33 }, { 0x13, 7, 6 }, { 0x12, 7, 10 },
	{ 0x11, 7, 18 }, { 0x10, 7, 34 },
	{ 0x1f, 8, 7 }, { 0x1e, 8, 11 }, { 0x1d, 8, 19 }, { 0x1c, 8, 35 }, { 0x1b, 8, 13 }, { 0x1a, 8, 49 },
	{ 0x19, 8, 21 }, { 0x18, 8, 41 }, { 0x17, 8, 14 }, { 0x16, 8, 50 }, { 0x15, 8, 22 }, { 0x14, 8, 42 },
	{ 0x13, 8, 15 }, { 0x12, 8, 51 }, { 0x11, 8, 23 }, { 0x10, 8, 43 }, { 0xf, 8, 25 }, { 0xe, 8, 37 },
	{ 0xd, 8, 26 }, { 0xc, 8, 38 }, { 0xb, 8, 29 }, { 0xa, 8, 45 }, { 0x9, 8, 53 }, { 0x8, 8, 57 },
	{ 0x7, 8, 30 }, { 0x6, 8, 46 }, { 0x5, 8, 54 }, { 0x4, 8, 58 },
	{ 0x7, 9, 31 }, { 0x6, 9, 47 }, { 0x5, 9, 55 }, { 0x4, 9, 59 }, { 0x3, 9, 27 }, { 0x2, 9, 39 },
};

const mpeg_vlc s_dc_size_lum[] =
{
	{ 0x4, 3, 0 }, { 0x0, 2, 1 }, { 0x1, 2, 2 }, { 0x5, 3, 3 }, { 0x6, 3, 4 }, { 0xe, 4, 5 },
	{ 0x1e, 5, 6 }, { 0x3e, 6, 7 }, { 0x7e, 7, 8 },
};

const mpeg_vlc s_dc_size_chr[] =
{
	{ 0x0, 2, 0 }, { 0x1, 2, 1 }, { 0x2, 2, 2 }, { 0x6, 3, 3 }, { 0xe, 4, 4 }, { 0x1e, 5, 5 },
	{ 0x3e, 6, 6 }, { 0x7e, 7, 7 }, { 0xfe, 8, 8 },
};

// dct_coeff_next: run, level (sign bit follows)
const mpeg_vlc s_dct_coeff[] =
{
	{ 0x3, 2, 0, 1 }, { 0x3, 3, 1, 1 }, { 0x4, 4, 0, 2 }, { 0x5, 4, 2, 1 }, { 0x5, 5, 0, 3 },
	{ 0x7, 5, 3, 1 }, { 0x6, 5, 4, 1 }, { 0x6, 6, 1, 2 }, { 0x7, 6, 5, 1 }, { 0x5, 6, 6, 1 },
	{ 0x4, 6, 7, 1 }, { 0x6, 7, 0, 4 }, { 0x4, 7, 2, 2 }, { 0x7, 7, 8, 1 }, { 0x5, 7, 9, 1 },
	{ 0x26, 8, 0, 5 }, { 0x21, 8, 0, 6 }, { 0x25, 8, 1, 3 }, { 0x24, 8, 3, 2 }, { 0x27, 8, 10, 1 },
	{ 0x23, 8, 11, 1 }, { 0x22, 8, 12, 1 }, { 0x20, 8, 13, 1 }, { 0xa, 10, 0, 7 }, { 0xc, 10, 1, 4 },
	{ 0xb, 10, 2, 3 }, { 0xf, 10, 4, 2 }, { 0x9, 10, 5, 2 }, { 0xe, 10, 14, 1 }, { 0xd, 10, 15, 1 },
	{ 0x8, 10, 16, 1 }, { 0x1d, 12, 0, 8 }, { 0x18, 12, 0, 9 }, { 0x13, 12, 0, 10 }, { 0x10, 12, 0, 11 },
	{ 0x1b, 12, 1, 5 }, { 0x14, 12, 2, 4 }, { 0x1c, 12, 3, 3 }, { 0x12, 12, 4, 3 }, { 0x1e, 12, 6, 2 },
	{ 0x15, 12, 7, 2 }, { 0x11, 12, 8, 2 }, { 0x1f, 12, 17, 1 }, { 0x1a, 12, 18, 1 }, { 0x19, 12, 19, 1 },
	{ 0x17, 12, 20, 1 }, { 0x16, 12, 21, 1 }, { 0x1a, 13, 0, 12 }, { 0x19, 13, 0, 13 }, { 0x18, 13, 0, 14 },
	{ 0x17, 13, 0, 15 }, { 0x16, 13, 1, 6 }, { 0x15, 13, 1, 7 }, { 0x14, 13, 2, 5 }, { 0x13, 13, 3, 4 },
	{ 0x12, 13, 5, 3 }, { 0x11, 13, 9, 2 }, { 0x10, 13, 10, 2 }, { 0x1f, 13, 22, 1 }, { 0x1e, 13, 23, 1 },
	{ 0x1d, 13, 24, 1 }, { 0x1c, 13, 25, 1 }, { 0x1b, 13, 26, 1 }, { 0x1f, 14, 0, 16 }, { 0x1e, 14, 0, 17 },
	{ 0x1d, 14, 0, 18 }, { 0x1c, 14, 0, 19 }, { 0x1b, 14, 0, 20 }, { 0x1a, 14, 0, 21 }, { 0x19, 14, 0, 22 },
	{ 0x18, 14, 0, 23 }, { 0x17, 14, 0, 24 }, { 0x16, 14, 0, 25 }, { 0x15, 14, 0, 26 }, { 0x14, 14, 0, 27 },
	{ 0x13, 14, 0, 28 }, { 0x12, 14, 0, 29 }, { 0x11, 14, 0, 30 }, { 0x10, 14, 0, 31 }, { 0x18, 15, 0, 32 },
	{ 0x17, 15, 0, 33 }, { 0x16, 15, 0, 34 }, { 0x15, 15, 0, 35 }, { 0x14, 15, 0, 36 }, { 0x13, 15, 0, 37 },
	{ 0x12, 15, 0, 38 }, { 0x11, 15, 0, 39 }, { 0x10, 15, 0, 40 }, { 0x1f, 15, 1, 8 }, { 0x1e, 15, 1, 9 },
	{ 0x1d, 15, 1, 10 }, { 0x1c, 15, 1, 11 }, { 0x1b, 15, 1, 12 }, { 0x1a, 15, 1, 13 }, { 0x19, 15, 1, 14 },
	{ 0x13, 16, 1, 15 }, { 0x12, 16, 1, 16 }, { 0x11, 16, 1, 17 }, { 0x10, 16, 1, 18 }, { 0x14, 16, 6, 3 },
	{ 0x1a, 16, 11, 2 }, { 0x19, 16, 12, 2 }, { 0x18, 16, 13, 2 }, { 0x17, 16, 14, 2 }, { 0x16, 16, 15, 2 },
	{ 0x15, 16, 16, 2 }, { 0x1f, 16, 27, 1 }, { 0x1e, 16, 28, 1 }, { 0x1d, 16, 29, 1 }, { 0x1c, 16, 30, 1 },
	{ 0x1b, 16, 31, 1 },
};

const uint8_t s_zigzag[64] =
{
	 0,  1,  8, 16,  9,  2,  3, 10, 17, 24, 32, 25, 18, 11,  4,  5,
	12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13,  6,  7, 14, 21, 28,
	35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
	58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63
};

// A VLC table and its lookup table, indexed by the next 'bits' bits:
// (code length << 8) | entry index, 0 if invalid
struct vlc_table
{
	const mpeg_vlc *entries;
	uint32_t bits;
	std::vector<uint16_t> lut;

	template <size_t N>
	vlc_table(const mpeg_vlc (&table)[N], uint32_t lut_bits) : entries(table), bits(lut_bits), lut(1 << lut_bits, 0)
	{
		for (size_t i = 0; i < N; ++i)
		{
			const uint32_t shift = bits - table[i].len;
			for (uint32_t j = 0; j < (1U << shift); ++j)
				lut[(table[i].code << shift) | j] = (table[i].len << 8) | i;
		}
	}
};

const vlc_table s_mb_addr_inc_vlc(s_mb_addr_inc, 11);
const vlc_table s_mb_type_vlc[3] = { { s_mb_type_i, 2 }, { s_mb_type_p, 6 }, { s_mb_type_b, 6 } };
const vlc_table s_motion_code_vlc(s_motion_code, 11);
const vlc_table s_cbp_vlc(s_coded_block_pattern, 9);
const vlc_table s_dc_size_lum_vlc(s_dc_size_lum, 7);
const vlc_table s_dc_size_chr_vlc(s_dc_size_chr, 8);
const vlc_table s_dct_coeff_vlc(s_dct_coeff, 16);

// 8x8 inverse DCT basis
struct idct_basis
{
	double c[8][8];
	idct_basis()
	{
		constexpr double pi = 3.14159265358979323846;
		for (int x = 0; x < 8; ++x)
			for (int u = 0; u < 8; ++u)
				c[x][u] = (u ? 0.5 : std::sqrt(0.125)) * std::cos((2 * x + 1) * u * pi / 16.0);
	}
} const s_idct;

// floor() of a double well inside the int32 range, without a library call
// (ARMv7's VFP has no rounding instruction): truncate, then step down if the
// truncation went up (negative non-integers); exactly std::floor's result
inline int32_t floor_to_int(double value)
{
	const int32_t truncated = int32_t(value);
	return (double(truncated) > value) ? truncated - 1 : truncated;
}

// The basis transposed: s_idct_t.c[u][x] = s_idct.c[x][u]
struct idct_basis_t
{
	double c[8][8];
	idct_basis_t()
	{
		for (int x = 0; x < 8; ++x)
			for (int u = 0; u < 8; ++u)
				c[u][x] = s_idct.c[x][u];
	}
} const s_idct_t;

// Separable floating point inverse DCT, rounded. Each output is the sum of
// basis x coefficient products added in order of the coefficient index, as a
// plain double loop would. Zero coefficients and all-zero rows are skipped:
// each skipped term is a signed zero added to a sum that is never -0, so the
// sums are unchanged. The eight sums of a row are kept side by side, which
// changes no sum's order of additions but lets them overlap in the pipeline
[[maybe_unused]] void idct_8x8(const int32_t *in, int32_t *out)
{
	double tmp[8][8];
	int rows[8];
	int row_count = 0;

	for (int v = 0; v < 8; ++v)
	{
		const int32_t *const row = &in[v * 8];
		int u = 0;
		while (u < 8 && row[u] == 0)
			++u;
		if (u == 8)
			continue;
		rows[row_count++] = v;

		double *const sum = tmp[v];
		for (int x = 0; x < 8; ++x)
			sum[x] = 0;
		for ( ; u < 8; ++u)
		{
			if (row[u] == 0)
				continue;
			const double coef = row[u];
			const double *const basis = s_idct_t.c[u];
			for (int x = 0; x < 8; ++x)
				sum[x] += basis[x] * coef;
		}
	}

	for (int y = 0; y < 8; ++y)
	{
		double sum[8] = { 0, 0, 0, 0, 0, 0, 0, 0 };
		for (int i = 0; i < row_count; ++i)
		{
			const double basis = s_idct.c[y][rows[i]];
			const double *const t = tmp[rows[i]];
			for (int x = 0; x < 8; ++x)
				sum[x] += basis * t[x];
		}
		for (int x = 0; x < 8; ++x)
			out[y * 8 + x] = floor_to_int(sum[x] + 0.5);
	}
}

#ifdef M2MPEGD_FAST_IDCT
//-------------------------------------------------
//  m2mpegd only (not in MAME): the same
//  results as idct_8x8, mostly in single precision
//-------------------------------------------------
//
// Each output is computed in float (F) and kept only where its rounding is
// certain; elsewhere it is recomputed exactly as idct_8x8 does.
//
// The bound. Take the double basis values c as exact and let S be the exact
// real sum of an output, Sin the block's sum of |coefficients| (|c| <= 0.5).
// - Row pass: T_v = sum_u fl(c_f * in): each product goes through at most 9
//   roundings (c to float, the product, 7 additions), so |T_v - t_v| <=
//   g9 * 0.5 * Sin_v, with g9 = 9u / (1 - 9u), u = 2^-24, and |T_v| <=
//   0.5 * Sin_v * (1 + g9).
// - Column pass the same way: |F - S| <= g9 * sum |c||T_v| + sum |c||T_v - t_v|
//   <= 0.25 * g9 * Sin * (2 + g9) = 2.682e-7 * Sin (to 4 digits).
// - G = fl(F + 0.5) adds at most u * (|F| + 0.5) <= 1.5e-8 * Sin + 6e-8
//   (|S| <= 0.25 * Sin); the double path's own error is about 1e-15 * Sin.
// So |G - (S_d + 0.5)| < 2.84e-7 * Sin + 6e-8 < E = 3e-7 * Sin + 1e-5. When G's
// fractional part is at least E away from 0 and from 1, floor(G) is the
// double path's floor(fl(S_d + 0.5)) (S_d + 0.5 is then far more than a double
// ulp from an integer). Otherwise the output is recomputed exactly.
// NEON flushes denormals to zero; none can occur: every nonzero value here is
// a sum of products whose ulps are at least 2^-55.
// The NEON and the plain float code both follow this bound (any order of the
// additions within a sum, fused or not, stays inside g9).

struct idct_basis_f
{
	float t[8][8];      // t[u][x] = c[x][u]
	float c[8][8];      // c[y][v]
	idct_basis_f()
	{
		for (int x = 0; x < 8; ++x)
			for (int u = 0; u < 8; ++u)
			{
				t[u][x] = float(s_idct.c[x][u]);
				c[x][u] = float(s_idct.c[x][u]);
			}
	}
} const s_idct_f;

uint64_t s_fast_outputs, s_fast_fallbacks;

// One output exactly as idct_8x8 computes it: the same products, added in
// the same order, in double
int32_t idct_exact_one(const int32_t *in, const int *rows, int row_count, int y, int x)
{
	double sum = 0;
	for (int i = 0; i < row_count; ++i)
	{
		const int32_t *const row = &in[rows[i] * 8];
		double t = 0;
		for (int u = 0; u < 8; ++u)
			if (row[u] != 0)
				t += s_idct_t.c[u][x] * double(row[u]);
		sum += s_idct.c[y][rows[i]] * t;
	}
	return floor_to_int(sum + 0.5);
}

void idct_8x8_fast(const int32_t *in, int32_t *out)
{
	int rows[8];
	int row_count = 0;
	int32_t abs_sum = 0;
	alignas(16) float tmp[8][8];

	for (int v = 0; v < 8; ++v)
	{
		const int32_t *const row = &in[v * 8];
		int u = 0;
		while (u < 8 && row[u] == 0)
			++u;
		if (u == 8)
			continue;
		rows[row_count++] = v;
#if defined(__ARM_NEON)
		float32x4_t a0 = vdupq_n_f32(0), a1 = vdupq_n_f32(0);
		for ( ; u < 8; ++u)
		{
			if (row[u] == 0)
				continue;
			abs_sum += std::abs(row[u]);
			const float coef = float(row[u]);
			a0 = vmlaq_n_f32(a0, vld1q_f32(&s_idct_f.t[u][0]), coef);
			a1 = vmlaq_n_f32(a1, vld1q_f32(&s_idct_f.t[u][4]), coef);
		}
		vst1q_f32(&tmp[v][0], a0);
		vst1q_f32(&tmp[v][4], a1);
#else
		float *const sum = tmp[v];
		for (int x = 0; x < 8; ++x)
			sum[x] = 0;
		for ( ; u < 8; ++u)
		{
			if (row[u] == 0)
				continue;
			abs_sum += std::abs(row[u]);
			const float coef = float(row[u]);
			for (int x = 0; x < 8; ++x)
				sum[x] += s_idct_f.t[u][x] * coef;
		}
#endif
	}

	if (!row_count)
	{
		std::fill_n(out, 64, 0); // the double path's sums are all +0 too
		return;
	}

	const float margin = 3e-7f * float(abs_sum) + 1e-5f;
#if defined(__ARM_NEON)
	// The flags stay in NEON registers and memory; one move to the ARM side per block (each NEON-to-ARM move stalls the A9)
	alignas(16) uint32_t flagmem[64];
	uint32x4_t any = vdupq_n_u32(0);
	const float32x4_t half = vdupq_n_f32(0.5f), lo = vdupq_n_f32(margin), hi = vdupq_n_f32(1.0f - margin);
	for (int y = 0; y < 8; ++y)
	{
		float32x4_t b0 = vdupq_n_f32(0), b1 = vdupq_n_f32(0);
		for (int i = 0; i < row_count; ++i)
		{
			const float c = s_idct_f.c[y][rows[i]];
			b0 = vmlaq_n_f32(b0, vld1q_f32(&tmp[rows[i]][0]), c);
			b1 = vmlaq_n_f32(b1, vld1q_f32(&tmp[rows[i]][4]), c);
		}
		for (int k = 0; k < 2; ++k)
		{
			const float32x4_t g = vaddq_f32(k ? b1 : b0, half);
			int32x4_t n = vcvtq_s32_f32(g);                                       // toward zero
			n = vaddq_s32(n, vreinterpretq_s32_u32(vcgtq_f32(vcvtq_f32_s32(n), g))); // -1 where it went up: floor
			const float32x4_t frac = vsubq_f32(g, vcvtq_f32_s32(n));
			const uint32x4_t f = vorrq_u32(vcltq_f32(frac, lo), vcgtq_f32(frac, hi));
			any = vorrq_u32(any, f);
			vst1q_u32(&flagmem[y * 8 + k * 4], f);
			vst1q_s32(&out[y * 8 + k * 4], n);
		}
	}
	s_fast_outputs += 64;
	const uint32x2_t a2 = vorr_u32(vget_low_u32(any), vget_high_u32(any));
	if (vget_lane_u32(a2, 0) | vget_lane_u32(a2, 1))
		for (int i = 0; i < 64; ++i)
			if (flagmem[i])
			{
				out[i] = idct_exact_one(in, rows, row_count, i >> 3, i & 7);
				++s_fast_fallbacks;
			}
#else
	for (int y = 0; y < 8; ++y)
	{
		int32_t *const o = &out[y * 8];
		bool unsure = false;
		float sum[8] = { 0, 0, 0, 0, 0, 0, 0, 0 };
		for (int i = 0; i < row_count; ++i)
		{
			const float c = s_idct_f.c[y][rows[i]];
			const float *const t = tmp[rows[i]];
			for (int x = 0; x < 8; ++x)
				sum[x] += c * t[x];
		}
		for (int x = 0; x < 8; ++x)
		{
			const float g = sum[x] + 0.5f;
			int32_t n = int32_t(g);
			if (float(n) > g)
				--n;
			const float frac = g - float(n);
			o[x] = n;
			unsure |= frac < margin || frac > 1.0f - margin;
		}
		s_fast_outputs += 8;
		if (unsure)
		{
			// An output of this line is near the edge: recompute the line exactly
			// (for the sure ones that gives the same value)
			for (int x = 0; x < 8; ++x)
				o[x] = idct_exact_one(in, rows, row_count, y, x);
			s_fast_fallbacks += 8;
		}
	}
#endif
}
#endif

} // anonymous namespace

#ifdef M2MPEGD_FAST_IDCT
// How many IDCT outputs the fast path made and how many it recomputed exactly
void m2mpegd_idct_stats(uint64_t &outputs, uint64_t &fallbacks)
{
	outputs = s_fast_outputs;
	fallbacks = s_fast_fallbacks;
}
#endif


void m2_mpeg1_decoder::picture::allocate(uint32_t w, uint32_t h)
{
	width = w;
	height = h;
	y.assign(w * h, 0);
	cb.assign(w * h / 4, 128);
	cr.assign(w * h / 4, 128);
}


//-------------------------------------------------
//  Bitstream access
//-------------------------------------------------

uint32_t m2_mpeg1_decoder::peek_bits(uint32_t count) const
{
	// Up to 32 bits from a 64-bit big-endian window; zeros past the end
	const size_t byte = m_bit_pos >> 3;
	uint64_t window = 0;
	if (byte + 8 <= m_size)
	{
		const uint8_t *const p = m_data + byte;
		window = (uint64_t(p[0]) << 56) | (uint64_t(p[1]) << 48) | (uint64_t(p[2]) << 40) | (uint64_t(p[3]) << 32) |
				(uint64_t(p[4]) << 24) | (uint64_t(p[5]) << 16) | (uint64_t(p[6]) << 8) | uint64_t(p[7]);
	}
	else
	{
		for (int i = 0; i < 8; ++i)
			window = (window << 8) | ((byte + i < m_size) ? m_data[byte + i] : 0);
	}
	return uint32_t((window << (m_bit_pos & 7)) >> (64 - count));
}

bool m2_mpeg1_decoder::at_start_code() const
{
	return peek_bits(23) == 0 || (m_bit_pos >> 3) >= m_size;
}


//-------------------------------------------------
//  Blocks
//-------------------------------------------------

bool m2_mpeg1_decoder::decode_intra_block(int comp, int32_t *blk, int32_t qscale)
{
	std::fill_n(blk, 64, 0);

	// DC coefficient: differential from the previous block of the same component
	const vlc_table &dc_vlc = comp ? s_dc_size_chr_vlc : s_dc_size_lum_vlc;
	const uint16_t dc_entry = dc_vlc.lut[peek_bits(dc_vlc.bits)];
	if (!dc_entry)
		return false;
	m_bit_pos += dc_entry >> 8;

	const uint32_t size = dc_vlc.entries[dc_entry & 0xff].a;
	int32_t diff = 0;
	if (size)
	{
		diff = get_bits(size);
		if (!BIT(diff, size - 1))
			diff = diff - (1 << size) + 1;
	}
	m_dc_pred[comp] += diff * 8;
	blk[0] = m_dc_pred[comp];

	// AC coefficients
	for (int i = 0; ; )
	{
		int32_t run, level;

		if (peek_bits(2) == 0x2)
		{
			m_bit_pos += 2; // End of block
			break;
		}
		else if (peek_bits(6) == 0x1)
		{
			m_bit_pos += 6; // Escape
			run = get_bits(6);
			level = get_bits(8);
			if (level == 0)
				level = get_bits(8);
			else if (level == 128)
				level = int32_t(get_bits(8)) - 256;
			else if (level > 128)
				level -= 256;
		}
		else
		{
			const uint16_t entry = s_dct_coeff_vlc.lut[peek_bits(16)];
			if (!entry)
				return false;
			m_bit_pos += entry >> 8;
			run = s_dct_coeff[entry & 0xff].a;
			level = s_dct_coeff[entry & 0xff].b;
			if (get_bits(1))
				level = -level;
		}

		i += run + 1;
		if (i > 63)
			return false;

		// Intra dequantisation with MPEG-1 mismatch control
		int32_t value = (2 * std::abs(level) * qscale * m_params.intra_quant[i]) / 16;
		if (value && !(value & 1))
			--value;
		blk[s_zigzag[i]] = std::clamp(level < 0 ? -value : value, -2048, 2047);
	}
	return true;
}

bool m2_mpeg1_decoder::decode_nonintra_block(int32_t *blk, int32_t qscale)
{
	std::fill_n(blk, 64, 0);

	for (int i = -1; ; )
	{
		int32_t run, level;

		if (i >= 0 && peek_bits(2) == 0x2)
		{
			m_bit_pos += 2; // End of block
			break;
		}
		else if (i < 0 && peek_bits(1) == 0x1)
		{
			// dct_coeff_first: '1s' is run 0, level 1
			m_bit_pos += 1;
			run = 0;
			level = get_bits(1) ? -1 : 1;
		}
		else if (peek_bits(6) == 0x1)
		{
			m_bit_pos += 6; // Escape
			run = get_bits(6);
			level = get_bits(8);
			if (level == 0)
				level = get_bits(8);
			else if (level == 128)
				level = int32_t(get_bits(8)) - 256;
			else if (level > 128)
				level -= 256;
		}
		else
		{
			const uint16_t entry = s_dct_coeff_vlc.lut[peek_bits(16)];
			if (!entry)
				return false;
			m_bit_pos += entry >> 8;
			run = s_dct_coeff[entry & 0xff].a;
			level = s_dct_coeff[entry & 0xff].b;
			if (get_bits(1))
				level = -level;
		}

		i += run + 1;
		if (i > 63 || level == 0)
			return false;

		// Non-intra dequantisation with MPEG-1 mismatch control
		const int32_t sign = (level < 0) ? -1 : 1;
		int32_t value = ((2 * level + sign) * qscale * m_params.nonintra_quant[i]) / 16;
		if (!(value & 1))
			value -= (value > 0) ? 1 : (value < 0) ? -1 : 0;
		blk[s_zigzag[i]] = std::clamp(value, -2048, 2047);
	}
	return true;
}

// Inverse transform a block and store it (intra) or add it to the prediction
void m2_mpeg1_decoder::add_block(picture &out, uint32_t mbx, uint32_t mby, int b, const int32_t *blk, bool intra)
{
	int32_t pels[64];
#ifdef M2MPEGD_FAST_IDCT
	idct_8x8_fast(blk, pels);
#else
	idct_8x8(blk, pels);
#endif

	uint8_t *dst;
	uint32_t stride;
	if (b < 4)
	{
		stride = out.width;
		dst = &out.y[(mby * 16 + (b >> 1) * 8) * stride + mbx * 16 + (b & 1) * 8];
	}
	else
	{
		stride = out.width / 2;
		dst = &((b == 4) ? out.cb : out.cr)[(mby * 8) * stride + mbx * 8];
	}

	for (int y = 0; y < 8; ++y)
		for (int x = 0; x < 8; ++x)
		{
			const int32_t pel = pels[y * 8 + x];
			uint8_t &d = dst[y * stride + x];
			d = intra ? uint8_t(std::clamp(pel, 0, 255)) : uint8_t(std::clamp(d + std::clamp(pel, -256, 255), 0, 255));
		}
}


//-------------------------------------------------
//  Motion compensation
//-------------------------------------------------

bool m2_mpeg1_decoder::decode_motion_vector(motion_vector &mv, uint32_t r_size)
{
	const int32_t f = 1 << r_size;

	for (int32_t *component : { &mv.x, &mv.y })
	{
		const uint16_t entry = s_motion_code_vlc.lut[peek_bits(s_motion_code_vlc.bits)];
		if (!entry)
			return false;
		m_bit_pos += entry >> 8;

		const int32_t code = s_motion_code[entry & 0xff].a;
		int32_t delta = code;
		if (code && f != 1)
			delta = ((code - 1) << r_size) + get_bits(r_size) + 1;
		if (s_motion_code[entry & 0xff].b)
			delta = -delta;

		// The reconstructed vector wraps within [-16f, 16f - 1]
		int32_t value = *component + delta;
		if (value > 16 * f - 1)
			value -= 32 * f;
		else if (value < -16 * f)
			value += 32 * f;
		*component = value;
	}
	return true;
}

namespace {

// Half-pel prediction of a size x size block of one plane; the vector is
// in half pels; samples outside the reference picture are clamped to its edge
void predict_block(const uint8_t *ref, uint32_t width, uint32_t height, int32_t x, int32_t y,
		int32_t mvx, int32_t mvy, uint32_t size, uint8_t *dst)
{
	const int32_t sx = x + (mvx >> 1);
	const int32_t sy = y + (mvy >> 1);
	const bool hx = mvx & 1;
	const bool hy = mvy & 1;

	// Inside the picture (the half-pel neighbours included): no clamping needed
	if (sx >= 0 && sy >= 0 && sx + int32_t(size) + hx <= int32_t(width) && sy + int32_t(size) + hy <= int32_t(height))
	{
		const uint8_t *src = ref + sy * width + sx;
		for (uint32_t j = 0; j < size; ++j, src += width, dst += size)
		{
			const uint8_t *const below = src + width;
			if (hx && hy)
				for (uint32_t i = 0; i < size; ++i)
					dst[i] = uint8_t((src[i] + src[i + 1] + below[i] + below[i + 1] + 2) >> 2);
			else if (hx)
				for (uint32_t i = 0; i < size; ++i)
					dst[i] = uint8_t((src[i] + src[i + 1] + 1) >> 1);
			else if (hy)
				for (uint32_t i = 0; i < size; ++i)
					dst[i] = uint8_t((src[i] + below[i] + 1) >> 1);
			else
				for (uint32_t i = 0; i < size; ++i)
					dst[i] = src[i];
		}
		return;
	}

	auto sample = [&] (int32_t px, int32_t py) -> int32_t
	{
		px = std::clamp<int32_t>(px, 0, width - 1);
		py = std::clamp<int32_t>(py, 0, height - 1);
		return ref[py * width + px];
	};

	for (uint32_t j = 0; j < size; ++j)
		for (uint32_t i = 0; i < size; ++i)
		{
			const int32_t px = sx + i;
			const int32_t py = sy + j;
			int32_t value;
			if (hx && hy)
				value = (sample(px, py) + sample(px + 1, py) + sample(px, py + 1) + sample(px + 1, py + 1) + 2) >> 2;
			else if (hx)
				value = (sample(px, py) + sample(px + 1, py) + 1) >> 1;
			else if (hy)
				value = (sample(px, py) + sample(px, py + 1) + 1) >> 1;
			else
				value = sample(px, py);
			dst[j * size + i] = uint8_t(value);
		}
}

} // anonymous namespace

// Form the macroblock's prediction in the output picture from the current
// motion vectors (which equal the predictors after decoding)
void m2_mpeg1_decoder::predict_macroblock(picture &out, uint32_t mbx, uint32_t mby, bool use_forward, bool use_backward)
{
	uint8_t pred[2][3][256];
	int count = 0;

	for (int dir = 0; dir < 2; ++dir)
	{
		if (!(dir ? use_backward : use_forward))
			continue;

		const picture *ref = dir ? m_backward : m_forward;
		if (!ref || ref->width != out.width || ref->height != out.height)
			continue;

		// Vectors in half pels; full pel vectors are scaled
		const motion_vector &pmv = dir ? m_pmv_backward : m_pmv_forward;
		const bool full_pel = dir ? m_params.backward_full_pel : m_params.forward_full_pel;
		int32_t mvx = pmv.x;
		int32_t mvy = pmv.y;
		if (full_pel)
		{
			mvx *= 2;
			mvy *= 2;
		}

		const uint32_t cw = out.width / 2;
		const uint32_t ch = out.height / 2;
		predict_block(ref->y.data(), out.width, out.height, mbx * 16, mby * 16, mvx, mvy, 16, pred[count][0]);
		predict_block(ref->cb.data(), cw, ch, mbx * 8, mby * 8, mvx / 2, mvy / 2, 8, pred[count][1]);
		predict_block(ref->cr.data(), cw, ch, mbx * 8, mby * 8, mvx / 2, mvy / 2, 8, pred[count][2]);
		++count;
	}

	for (int plane = 0; plane < 3; ++plane)
	{
		const uint32_t size = plane ? 8 : 16;
		const uint32_t stride = plane ? out.width / 2 : out.width;
		uint8_t *const dst = &(plane == 0 ? out.y : plane == 1 ? out.cb : out.cr)[(mby * size) * stride + mbx * size];

		for (uint32_t j = 0; j < size; ++j)
			for (uint32_t i = 0; i < size; ++i)
			{
				uint8_t value = 0;
				if (count == 2)
					value = (pred[0][plane][j * size + i] + pred[1][plane][j * size + i] + 1) >> 1;
				else if (count == 1)
					value = pred[0][plane][j * size + i];
				dst[j * stride + i] = value;
			}
	}
}


//-------------------------------------------------
//  decode - decode one picture's slices
//-------------------------------------------------

const char *m2_mpeg1_decoder::decode(const uint8_t *data, size_t size, const picture_params &params,
		picture &out, const picture *forward, const picture *backward)
{
	prepare(data, size, params, forward, backward);
	out.allocate(params.mb_width * 16, params.mb_height * 16);

	range_stop stop;
	int32_t lo, hi;
	return decode_range(out, 0, ~size_t(0), stop, lo, hi);
}

void m2_mpeg1_decoder::prepare(const uint8_t *data, size_t size, const picture_params &params,
		const picture *forward, const picture *backward)
{
	m_data = data;
	m_size = size;
	m_bit_pos = 0;
	m_params = params;
	m_forward = forward;
	m_backward = backward;
}

const char *m2_mpeg1_decoder::decode_range(picture &out, size_t from, size_t until, range_stop &stop, int32_t &lo, int32_t &hi)
{
	const uint8_t *const data = m_data;
	const size_t size = m_size;
	const picture_params &params = m_params;
	m_bit_pos = from * 8;
	stop = RANGE_END;
	lo = 0x7fffffff;
	hi = -1;

	const uint32_t mb_count = params.mb_width * params.mb_height;

	if (params.type < PICTURE_I || params.type > PICTURE_B)
		return "unsupported picture type";

	const vlc_table &mb_type_vlc = s_mb_type_vlc[params.type - 1];
	uint8_t mb_type = 0;

	while (true)
	{
		// Find the next slice start code
		size_t pos = (m_bit_pos + 7) >> 3;
		while (pos + 3 < size && !(data[pos] == 0 && data[pos + 1] == 0 && data[pos + 2] == 1))
			++pos;
		if (pos > until)
		{
			stop = RANGE_PASSED;
			break;
		}
		if (pos + 3 >= size)
			break;

		const uint8_t code = data[pos + 3];
		if (code < 0x01 || code > 0xaf)
			break;
		if (pos == until)
		{
			stop = RANGE_AT_UNTIL;
			break;
		}

		m_bit_pos = (pos + 4) * 8;
		int32_t qscale = get_bits(5);
		while (get_bits(1))
			get_bits(8); // extra_information_slice

		// Predictors are reset at the start of each slice
		int32_t address = (code - 1) * params.mb_width - 1;
		m_dc_pred[0] = m_dc_pred[1] = m_dc_pred[2] = 1024;
		m_pmv_forward = m_pmv_backward = motion_vector();
		bool first = true;
		bool previous_intra = false;
		mb_type = 0;

		do
		{
			// Macroblock address increment, with stuffing and escapes
			uint32_t increment = 0;
			while (true)
			{
				const uint32_t bits = peek_bits(11);
				if (bits == 0x0f)
				{
					m_bit_pos += 11;
				}
				else if (bits == 0x08)
				{
					m_bit_pos += 11;
					increment += 33;
				}
				else
				{
					const uint16_t entry = s_mb_addr_inc_vlc.lut[bits];
					if (!entry)
						return "bad macroblock address increment";
					m_bit_pos += entry >> 8;
					increment += s_mb_addr_inc[entry & 0xff].a;
					break;
				}
			}

			// Skipped macroblocks: P pictures copy the forward reference
			// with a zero vector, B pictures repeat the previous
			// macroblock's prediction
			if (!first && increment > 1 && params.type != PICTURE_I)
			{
				if (params.type == PICTURE_P)
					m_pmv_forward = motion_vector();
				for (uint32_t skip = 1; skip < increment; ++skip)
				{
					const int32_t skipped = address + skip;
					if (skipped >= int32_t(mb_count))
						break;
					lo = std::min(lo, skipped);
					hi = std::max(hi, skipped);
					if (params.type == PICTURE_P)
						predict_macroblock(out, skipped % params.mb_width, skipped / params.mb_width, true, false);
					else
						predict_macroblock(out, skipped % params.mb_width, skipped / params.mb_width, mb_type & MB_FORWARD, mb_type & MB_BACKWARD);
				}
				m_dc_pred[0] = m_dc_pred[1] = m_dc_pred[2] = 1024;
				previous_intra = false;
			}
			first = false;

			address += increment;
			if (address >= int32_t(mb_count))
				break;

			const uint32_t mbx = address % params.mb_width;
			const uint32_t mby = address / params.mb_width;
			lo = std::min(lo, address);
			hi = std::max(hi, address);

			const uint16_t type_entry = mb_type_vlc.lut[peek_bits(mb_type_vlc.bits)];
			if (!type_entry)
				return "bad macroblock type";
			m_bit_pos += type_entry >> 8;
			mb_type = mb_type_vlc.entries[type_entry & 0xff].a;

			if (mb_type & MB_QUANT)
				qscale = get_bits(5);

			if (mb_type & MB_FORWARD)
				if (!decode_motion_vector(m_pmv_forward, params.forward_r_size))
					return "bad forward motion vector";
			if (mb_type & MB_BACKWARD)
				if (!decode_motion_vector(m_pmv_backward, params.backward_r_size))
					return "bad backward motion vector";

			int32_t blk[64];
			if (mb_type & MB_INTRA)
			{
				// Motion vector predictors reset; DC predictors reset
				// unless the previous macroblock was also intra
				m_pmv_forward = m_pmv_backward = motion_vector();
				if (!previous_intra)
					m_dc_pred[0] = m_dc_pred[1] = m_dc_pred[2] = 1024;
				previous_intra = true;

				for (int b = 0; b < 6; ++b)
				{
					if (!decode_intra_block((b < 4) ? 0 : b - 3, blk, qscale))
						return "bad intra block data";
					add_block(out, mbx, mby, b, blk, true);
				}
			}
			else
			{
				previous_intra = false;

				uint32_t cbp = 0;
				if (mb_type & MB_PATTERN)
				{
					const uint16_t entry = s_cbp_vlc.lut[peek_bits(s_cbp_vlc.bits)];
					if (!entry)
						return "bad coded block pattern";
					m_bit_pos += entry >> 8;
					cbp = s_coded_block_pattern[entry & 0xff].a;
				}

				// P macroblocks without motion compensation use a zero vector
				if (params.type == PICTURE_P)
				{
					if (!(mb_type & MB_FORWARD))
						m_pmv_forward = motion_vector();
					predict_macroblock(out, mbx, mby, true, false);
				}
				else
				{
					predict_macroblock(out, mbx, mby, mb_type & MB_FORWARD, mb_type & MB_BACKWARD);
				}

				for (int b = 0; b < 6; ++b)
				{
					if (!BIT(cbp, 5 - b))
						continue;
					if (!decode_nonintra_block(blk, qscale))
						return "bad non-intra block data";
					add_block(out, mbx, mby, b, blk, false);
				}
			}
		} while (!at_start_code());
	}

	return nullptr;
}
