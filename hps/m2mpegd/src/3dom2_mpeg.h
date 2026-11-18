// license:BSD-3-Clause
// copyright-holders:Philip Bennett
/***************************************************************************

    3DO M2 MPEG unit: MPEG-1 video picture decoder (ISO 11172-2)

***************************************************************************/
#ifndef MAME_KONAMI_3DOM2_MPEG_H
#define MAME_KONAMI_3DOM2_MPEG_H

#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

class m2_mpeg1_decoder
{
public:
	// A decoded 4:2:0 picture
	struct picture
	{
		uint32_t width = 0;
		uint32_t height = 0;
		std::vector<uint8_t> y;
		std::vector<uint8_t> cb;
		std::vector<uint8_t> cr;

		void allocate(uint32_t w, uint32_t h);
	};

	enum : uint8_t
	{
		PICTURE_I = 1,
		PICTURE_P = 2,
		PICTURE_B = 3
	};

	struct picture_params
	{
		uint32_t mb_width;
		uint32_t mb_height;
		uint8_t type;
		uint8_t forward_r_size;     // forward_f_code - 1
		uint8_t backward_r_size;
		bool forward_full_pel;
		bool backward_full_pel;
		const uint8_t *intra_quant;     // Zig-zag order
		const uint8_t *nonintra_quant;
	};

	// Decode the slices of one picture into 'out'; returns nullptr on
	// success, otherwise a description of the bitstream error
	const char *decode(const uint8_t *data, size_t size, const picture_params &params,
			picture &out, const picture *forward, const picture *backward);

	// (m2mpegd: a picture's slices decoded in two parts by two decoders, each on a thread of its own.) prepare sets a
	// decoder up for a picture without touching 'out' (allocated by the caller). decode_range decodes the slices found
	// from byte 'from' on, as decode does, but stops before a slice whose start code is at byte 'until': stop is then
	// AT_UNTIL; PASSED if the search for a slice went past 'until' without finding one there (the two parts would not
	// be what decode alone does); END at the picture's end. lo and hi: the least and greatest macroblock address written
	// (lo > hi: none).
	enum range_stop { RANGE_END, RANGE_AT_UNTIL, RANGE_PASSED };
	void prepare(const uint8_t *data, size_t size, const picture_params &params, const picture *forward, const picture *backward);
	const char *decode_range(picture &out, size_t from, size_t until, range_stop &stop, int32_t &lo, int32_t &hi);

private:
	struct motion_vector
	{
		int32_t x = 0;
		int32_t y = 0;
	};

	uint32_t peek_bits(uint32_t count) const;
	uint32_t get_bits(uint32_t count) { const uint32_t result = peek_bits(count); m_bit_pos += count; return result; }
	bool at_start_code() const;
	int32_t get_vlc(const std::vector<uint16_t> &lut, uint32_t bits, uint32_t &a, uint32_t &b);

	bool decode_intra_block(int comp, int32_t *blk, int32_t qscale);
	bool decode_nonintra_block(int32_t *blk, int32_t qscale);
	bool decode_motion_vector(motion_vector &mv, uint32_t r_size);

	void predict_macroblock(picture &out, uint32_t mbx, uint32_t mby, bool use_forward, bool use_backward);
	void add_block(picture &out, uint32_t mbx, uint32_t mby, int b, const int32_t *blk, bool intra);

	const uint8_t *m_data = nullptr;
	size_t m_size = 0;
	size_t m_bit_pos = 0;

	picture_params m_params{};
	const picture *m_forward = nullptr;
	const picture *m_backward = nullptr;

	int32_t m_dc_pred[3]{};
	motion_vector m_pmv_forward;       // Predictors, in the stream's units
	motion_vector m_pmv_backward;
};

#endif // MAME_KONAMI_3DOM2_MPEG_H
