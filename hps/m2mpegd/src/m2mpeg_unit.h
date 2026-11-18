// m2mpeg_unit: the M2 MPEG unit's picture path outside MAME.
// Registers in, slice bytes in, the output formatter's bytes out. The decoder is MAME's 3dom2_mpeg.cpp unchanged; the
// picture bookkeeping and the formatter follow m2_mpeg_device::decode_picture and ::output_picture (MAME 3dom2.cpp) line for
// line, so the output matches the emulator byte for byte (checked on the emulator's MPEG dumps).
#ifndef M2MPEG_UNIT_H
#define M2MPEG_UNIT_H

#include "3dom2_mpeg.h"

#include <cstddef>
#include <cstdint>
#include <condition_variable>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

// The registers a picture uses, as the driver wrote them (M2 addresses, M2 values)
struct m2mpeg_regs
{
	uint32_t config = 0;
	uint32_t int_enable = 0;
	uint32_t parser_config = 0;     // 0x024
	uint32_t image_size = 0;        // 0x02c
	uint32_t fwd_pred = 0;          // 0x030
	uint32_t rev_pred = 0;          // 0x054
	uint32_t outdma_config = 0;     // 0x034
	uint32_t format_config = 0;     // 0x038
	uint32_t format_input = 0;      // 0x03c
	uint32_t format_crop = 0;       // 0x040
	uint32_t format_output = 0;     // 0x044
	uint32_t dither[2] = {};        // 0x048, 0x04c
	uint32_t format_size = 0;       // 0x050
	uint32_t alpha_fill = 0;        // 0x060
	uint8_t intra_quant[64];        // 0x200-0x23f, zig-zag order
	uint8_t nonintra_quant[64];     // 0x240-0x27f

	m2mpeg_regs();
	// Apply one register write (offset within the unit, data as the CPU wrote it); the quant tables take 4 bytes a word
	void write(uint32_t offset, uint32_t data);
};

// The formatter's output: rows y0..y1-1 of the cropped picture, row r at address format_output + r * stride
struct m2mpeg_output
{
	bool present = false;           // false: no picture in the formatter's input buffer, nothing written
	uint32_t x0 = 0, y0 = 0, x1 = 0, y1 = 0, stride = 0, bpp = 0;
	std::vector<uint8_t> written;   // per row: 1 if written (0: outside RAM, skipped)
	std::vector<uint8_t> bytes;     // the written rows' bytes, concatenated, in M2 memory order (big-endian pixels;
	                                // the 32-bit path assumes a little-endian host)

	uint32_t row_bytes() const { return x1 > x0 ? (x1 - x0) * bpp : 0; }
};

class m2mpeg_unit
{
public:
	m2mpeg_unit(uint32_t ram_start, uint32_t ram_end) : m_ram_start(ram_start), m_ram_end(ram_end) { }

	// The device's reset: forget every picture
	void reset() { m_pictures.clear(); }

	// Decode one picture's slice data (the bytes the unit took, up to and including the start code that ended it) and
	// keep it by its output buffer; returns nullptr or the decoder's error (the picture is kept either way, as in MAME)
	const char *decode(const m2mpeg_regs &regs, const uint8_t *slices, size_t size);

	// Format the picture in the formatter's input buffer (after decode)
	void format(const m2mpeg_regs &regs, m2mpeg_output &out) const;

	// decode, format and 'store' (what the caller does with the formatted picture: called once, after format, possibly
	// from another thread) with the work on two threads; the pictures and 'out' are what decode then format make, bit
	// for bit. An I or P picture: the formatter's picture is an earlier one, so the second thread formats and stores it,
	// then decodes the last part of the slices, while the first decodes the rest. A B picture (the formatter's picture
	// is the one being decoded): half the slices each, then format and store. The two parts are whole slices in
	// separate macroblocks; if they turn out not to be (an error, a part that doesn't end where the other starts,
	// macroblocks in both), the picture is decoded again by decode alone. threads < 2: decode, format, store in turn.
	// test_split: for tests, a split that isn't at a slice (odd values) or a share of the slices for the second
	// thread in percent (even values > 0); 0: the unit's own choice
	const char *decode_format(const m2mpeg_regs &regs, const uint8_t *slices, size_t size, m2mpeg_output &out, int threads,
			const std::function<void (const m2mpeg_output &)> &store, int test_split = 0);
	uint64_t split_pictures() const { return m_split; }     // pictures decoded in two parts
	uint64_t split_fallbacks() const { return m_fallback; } // ... of which decoded again alone

	// The picture the last decode made (4:2:0 planes), or nullptr
	const m2_mpeg1_decoder::picture *last_decoded() const { return find(m_last_key); }

private:
	uint32_t m_last_key = ~0U;
	const m2_mpeg1_decoder::picture *find(uint32_t key) const;

	uint32_t m_ram_start, m_ram_end;
	m2_mpeg1_decoder m_decoder, m_decoder2;
	// the second thread: one, kept from picture to picture (started at the first picture that uses it)
	struct worker
	{
		std::thread th;
		std::mutex m;
		std::condition_variable cv;
		std::function<void ()> job;
		bool has = false, done = true, quit = false;
		worker();
		~worker();
		void start(std::function<void ()> fn);
		void wait();
	};
	std::unique_ptr<worker> m_worker;
	uint64_t m_split = 0, m_fallback = 0;
	m2_mpeg1_decoder::picture_params params_of(const m2mpeg_regs &regs) const;
	void keep(const m2mpeg_regs &regs);
	void format_picture(const m2_mpeg1_decoder::picture *display, const m2mpeg_regs &regs, m2mpeg_output &out) const;
	std::map<uint32_t, m2_mpeg1_decoder::picture> m_pictures;
	m2_mpeg1_decoder::picture m_decoded;
};

#endif
