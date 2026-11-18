// m2mpeg_unit: see m2mpeg_unit.h. The code below follows MAME's 3dom2.cpp (m2_mpeg_device::decode_picture, ::output_picture;
// license BSD-3-Clause, copyright-holders Philip Bennett) with the device's bus calls replaced by an output buffer.
#include "emu.h"
#include "m2mpeg_unit.h"

#include <algorithm>
#include <cstring>

#if defined(M2MPEGD_FAST) && defined(__ARM_NEON)
#include <arm_neon.h>
#endif

namespace {

enum : uint32_t
{
	MPG_CONFIG          = 0x004,
	MPG_INTENABLE       = 0x008,
	MPG_PARSERCONFIG    = 0x024,
	MPG_IMAGESIZE       = 0x02c,
	MPG_FWDPREDBUF      = 0x030,
	MPG_OUTDMACONFIG    = 0x034,
	MPG_FORMATCONFIG    = 0x038,
	MPG_FORMATINPUT     = 0x03c,
	MPG_FORMATCROP      = 0x040,
	MPG_FORMATOUTPUT    = 0x044,
	MPG_UPPERDITHERMTX  = 0x048,
	MPG_LOWERDITHERMTX  = 0x04c,
	MPG_FORMATSIZE      = 0x050,
	MPG_REVPREDBUF      = 0x054,
	MPG_FORMATALPHAFILL = 0x060,
	MPG_INTRAQUANT      = 0x200,
	MPG_NONINTRAQUANT   = 0x240,

	MPG_FORMAT_16BPP            = 0x00100000,
	MPG_FORMAT_CSC              = 0x00001000,
	MPG_FORMAT_ROWCHUNKS        = 0x000001ff,

	MPG_PARSER_TYPE             = 0x00000007,
	MPG_PARSER_FWD_RSIZE_SHIFT  = 16,
	MPG_PARSER_FWD_FULLPEL      = 0x00100000,
	MPG_PARSER_BWD_RSIZE_SHIFT  = 24,
	MPG_PARSER_BWD_FULLPEL      = 0x10000000,
};

// Picture buffers (reference pictures and the strip buffer) are page aligned
uint32_t picture_buffer_key(uint32_t address)
{
	return address & 0x01fff000;
}

} // anonymous namespace


m2mpeg_regs::m2mpeg_regs()
{
	std::fill(std::begin(intra_quant), std::end(intra_quant), 16);
	std::fill(std::begin(nonintra_quant), std::end(nonintra_quant), 16);
}

void m2mpeg_regs::write(uint32_t reg, uint32_t data)
{
	if (reg >= MPG_INTRAQUANT && reg < MPG_NONINTRAQUANT + 0x40)
	{
		uint8_t *const table = (reg < MPG_NONINTRAQUANT) ? intra_quant : nonintra_quant;
		const uint32_t index = (reg & 0x3c);
		for (int i = 0; i < 4; ++i)
			table[index + i] = data >> (24 - i * 8);
		return;
	}
	switch (reg)
	{
		case MPG_CONFIG:            config = data;          break;
		case MPG_INTENABLE:         int_enable = data;      break;
		case MPG_PARSERCONFIG:      parser_config = data;   break;
		case MPG_IMAGESIZE:         image_size = data;      break;
		case MPG_FWDPREDBUF:        fwd_pred = data;        break;
		case MPG_REVPREDBUF:        rev_pred = data;        break;
		case MPG_OUTDMACONFIG:      outdma_config = data;   break;
		case MPG_FORMATCONFIG:      format_config = data;   break;
		case MPG_FORMATINPUT:       format_input = data;    break;
		case MPG_FORMATCROP:        format_crop = data;     break;
		case MPG_FORMATOUTPUT:      format_output = data;   break;
		case MPG_UPPERDITHERMTX:    dither[0] = data;       break;
		case MPG_LOWERDITHERMTX:    dither[1] = data;       break;
		case MPG_FORMATSIZE:        format_size = data;     break;
		case MPG_FORMATALPHAFILL:   alpha_fill = data;      break;
		default:                                            break;
	}
}


const m2_mpeg1_decoder::picture *m2mpeg_unit::find(uint32_t key) const
{
	auto const it = m_pictures.find(key);
	return (it != m_pictures.end()) ? &it->second : nullptr;
}

m2_mpeg1_decoder::picture_params m2mpeg_unit::params_of(const m2mpeg_regs &r) const
{
	m2_mpeg1_decoder::picture_params params;
	params.mb_width = r.image_size & 0xff;
	params.mb_height = (r.image_size >> 8) & 0xff;
	params.type = r.parser_config & MPG_PARSER_TYPE;
	params.forward_r_size = (r.parser_config >> MPG_PARSER_FWD_RSIZE_SHIFT) & 7;
	params.backward_r_size = (r.parser_config >> MPG_PARSER_BWD_RSIZE_SHIFT) & 7;
	params.forward_full_pel = r.parser_config & MPG_PARSER_FWD_FULLPEL;
	params.backward_full_pel = r.parser_config & MPG_PARSER_BWD_FULLPEL;
	params.intra_quant = r.intra_quant;
	params.nonintra_quant = r.nonintra_quant;
	return params;
}

const char *m2mpeg_unit::decode(const m2mpeg_regs &r, const uint8_t *slices, size_t size)
{
	const m2_mpeg1_decoder::picture_params params = params_of(r);

	// The driver only programs the reference buffers a picture type uses
	const uint32_t fwd_key = picture_buffer_key(r.fwd_pred);
	const uint32_t rev_key = picture_buffer_key(r.rev_pred);
	const m2_mpeg1_decoder::picture *forward = (params.type >= 2) ? find(fwd_key) : nullptr;
	const m2_mpeg1_decoder::picture *backward = (params.type == 3) ? find(rev_key) : nullptr;

	const char *const error = m_decoder.decode(slices, size, params, m_decoded, forward, backward);
	keep(r);
	return error;
}

void m2mpeg_unit::keep(const m2mpeg_regs &r)
{
	const uint32_t out_key = picture_buffer_key(r.outdma_config);
	const uint32_t fwd_key = picture_buffer_key(r.fwd_pred);
	const uint32_t rev_key = picture_buffer_key(r.rev_pred);

	// Keep the pictures in use; drop stale buffers if the driver reallocates
	if (m_pictures.size() >= 4)
	{
		const uint32_t in_key = picture_buffer_key(r.format_input);
		for (auto it = m_pictures.begin(); it != m_pictures.end(); )
		{
			if (it->first != fwd_key && it->first != rev_key && it->first != in_key)
				it = m_pictures.erase(it);
			else
				++it;
		}
	}
	std::swap(m_pictures[out_key], m_decoded);
	m_last_key = out_key;
}

m2mpeg_unit::worker::worker()
{
	th = std::thread([this] {
		std::unique_lock<std::mutex> l(m);
		while (true)
		{
			cv.wait(l, [this] { return has || quit; });
			if (quit)
				return;
			has = false;
			l.unlock();
			job();
			l.lock();
			done = true;
			cv.notify_all();
		}
	});
}

m2mpeg_unit::worker::~worker()
{
	{
		std::lock_guard<std::mutex> l(m);
		quit = true;
	}
	cv.notify_all();
	th.join();
}

void m2mpeg_unit::worker::start(std::function<void ()> fn)
{
	{
		std::lock_guard<std::mutex> l(m);
		job = std::move(fn);
		has = true;
		done = false;
	}
	cv.notify_all();
}

void m2mpeg_unit::worker::wait()
{
	std::unique_lock<std::mutex> l(m);
	cv.wait(l, [this] { return done; });
}

const char *m2mpeg_unit::decode_format(const m2mpeg_regs &r, const uint8_t *slices, size_t size, m2mpeg_output &out, int threads,
		const std::function<void (const m2mpeg_output &)> &store, int test_split)
{
	const m2_mpeg1_decoder::picture_params params = params_of(r);
	const uint32_t out_key = picture_buffer_key(r.outdma_config);
	const uint32_t in_key = picture_buffer_key(r.format_input);
	// (the formatter's picture isn't the one being decoded: it can be formatted meanwhile. It is the same picture before
	// and after this decode: keep() leaves the formatter's input alone and puts the new picture under another key)
	const bool early = in_key != out_key;

	// where the second part starts: the first slice at or after the share of the bytes left to the first thread (the
	// slices' sizes are about their work; the second thread has the format and the store of an I or P picture first)
	size_t split = 0;
#ifndef M2MPEGD_NO_SPLIT    // (a build with MAME's own 3dom2_mpeg.cpp, which has no decode_range: always one thread)
	if (threads >= 2 && params.type >= m2_mpeg1_decoder::PICTURE_I && params.type <= m2_mpeg1_decoder::PICTURE_B)
	{
		const int share = (test_split > 0 && !(test_split & 1)) ? test_split : early ? 40 : 50;
		const size_t target = size - size * size_t(share) / 100;
		bool first = true;
		for (size_t pos = 0; pos + 3 < size; ++pos)
		{
			if (slices[pos] != 0 || slices[pos + 1] != 0 || slices[pos + 2] != 1)
				continue;
			if (slices[pos + 3] < 0x01 || slices[pos + 3] > 0xaf)
				break;
			if (!first && pos >= target)
			{
				split = pos;
				break;
			}
			first = false;
			pos += 3;
		}
		if (split && (test_split & 1))
			split += 1;     // (a test: not a slice's start, so the parts can't be right and the picture is decoded again)
	}
#endif
	if (!split)
	{
		const char *const error = decode(r, slices, size);
		format(r, out);
		if (store)
			store(out);
		return error;
	}

#ifdef M2MPEGD_NO_SPLIT
	return nullptr;
#else
	const m2_mpeg1_decoder::picture *const forward = (params.type >= 2) ? find(picture_buffer_key(r.fwd_pred)) : nullptr;
	const m2_mpeg1_decoder::picture *const backward = (params.type == 3) ? find(picture_buffer_key(r.rev_pred)) : nullptr;
	const m2_mpeg1_decoder::picture *const display = early ? find(in_key) : nullptr;
	m_decoded.allocate(params.mb_width * 16, params.mb_height * 16);
	m_decoder.prepare(slices, size, params, forward, backward);
	m_decoder2.prepare(slices, size, params, forward, backward);

	const char *error1 = nullptr, *error2 = nullptr;
	m2_mpeg1_decoder::range_stop stop1, stop2;
	int32_t lo1, hi1, lo2, hi2;
	if (!m_worker)
		m_worker = std::make_unique<worker>();
	m_worker->start([&] {
		if (early)
		{
			format_picture(display, r, out);
			if (store)
				store(out);
		}
		error2 = m_decoder2.decode_range(m_decoded, split, ~size_t(0), stop2, lo2, hi2);
	});
	error1 = m_decoder.decode_range(m_decoded, 0, split, stop1, lo1, hi1);
	m_worker->wait();
	++m_split;

	// the two parts are what one decode does only if the first ended at the second's start, neither failed, and they wrote
	// separate macroblocks, the first's all before the second's
	const char *error = nullptr;
	if (error1 || error2 || stop1 != m2_mpeg1_decoder::RANGE_AT_UNTIL || (hi1 >= 0 && lo2 <= hi2 && hi1 >= lo2))
	{
		++m_fallback;
		error = m_decoder.decode(slices, size, params, m_decoded, forward, backward);
	}
	keep(r);
	if (!early)
	{
		format(r, out);
		if (store)
			store(out);
	}
	return error;
#endif
}

void m2mpeg_unit::format(const m2mpeg_regs &r, m2mpeg_output &out) const
{
	format_picture(find(picture_buffer_key(r.format_input)), r, out);
}

void m2mpeg_unit::format_picture(const m2_mpeg1_decoder::picture *display, const m2mpeg_regs &r, m2mpeg_output &out) const
{
	// The formatter outputs the picture in its input buffer: the decoded
	// picture for B pictures, the previous reference for I and P pictures
	out.written.clear();
	out.bytes.clear();
	out.present = display != nullptr;
	if (!display)
		return;
	const m2_mpeg1_decoder::picture &pic = *display;

	const uint32_t width = pic.width;
	const uint32_t height = pic.height;
	const bool is16bpp = r.format_config & MPG_FORMAT_16BPP;
	const bool csc = r.format_config & MPG_FORMAT_CSC;
	const uint32_t stride = (r.format_config & MPG_FORMAT_ROWCHUNKS) * 32;
	const uint32_t alpha = r.alpha_fill & 0xff; // DSB and 7-bit alpha

	const uint32_t x0 = ((r.format_crop >> 24) & 0x7f) * 16;
	const uint32_t y0 = ((r.format_crop >> 16) & 0x7f) * 16;
	const uint32_t x1 = std::min(((r.format_crop >> 8) & 0x7f) * 16 + 16, width);
	const uint32_t y1 = std::min((r.format_crop & 0x7f) * 16 + 16, height);
	out.x0 = x0; out.y0 = y0; out.x1 = x1; out.y1 = y1; out.stride = stride; out.bpp = is16bpp ? 2 : 4;
	if (y1 > y0 && x1 > x0)
		out.bytes.resize(size_t(y1 - y0) * (x1 - x0) * out.bpp);
	uint8_t *dst = out.bytes.data();

	for (uint32_t y = y0; y < y1; ++y)
	{
		const uint32_t row = r.format_output + (y - y0) * stride;
		if (row < m_ram_start || row + (x1 - x0) * 4 > m_ram_end)
		{
			out.written.push_back(0);
			continue;
		}
		out.written.push_back(1);

		const uint8_t *const ly = &pic.y[y * width];
		const uint8_t *const lcb = &pic.cb[(y >> 1) * (width / 2)];
		const uint8_t *const lcr = &pic.cr[(y >> 1) * (width / 2)];
		uint32_t x = x0;
#if defined(M2MPEGD_FAST) && defined(__ARM_NEON)
		// 32-bit color-converted pixels 8 at a time (Battle Tryst's format), the same integer arithmetic as
		// below: 32-bit lanes (no product or sum leaves int32: |l| < 2^25, each chroma term < 2^25), an arithmetic shift,
		// and the clamp to 0..255 as two saturating narrowings (signed to unsigned 16, then to 8 bits)
		if (csc && !is16bpp && !(x0 & 1))
		{
			const uint8x8_t va = vdup_n_u8(uint8_t(alpha));
			for ( ; x + 8 <= x1; x += 8)
			{
				uint32_t cb4, cr4;
				memcpy(&cb4, &lcb[x >> 1], 4);
				memcpy(&cr4, &lcr[x >> 1], 4);
				const int16x8_t yy = vsubq_s16(vreinterpretq_s16_u16(vmovl_u8(vld1_u8(&ly[x]))), vdupq_n_s16(16));
				const int32x4_t l0 = vmulq_n_s32(vmovl_s16(vget_low_s16(yy)), 76284);
				const int32x4_t l1 = vmulq_n_s32(vmovl_s16(vget_high_s16(yy)), 76284);
				const int16x8_t cbw = vsubq_s16(vreinterpretq_s16_u16(vmovl_u8(vreinterpret_u8_u32(vdup_n_u32(cb4)))), vdupq_n_s16(128));
				const int16x8_t crw = vsubq_s16(vreinterpretq_s16_u16(vmovl_u8(vreinterpret_u8_u32(vdup_n_u32(cr4)))), vdupq_n_s16(128));
				const int32x4_t cb = vmovl_s16(vget_low_s16(cbw));   // the 4 chroma samples of these 8 pixels
				const int32x4_t cr = vmovl_s16(vget_low_s16(crw));
				const int32x4x2_t tr = vzipq_s32(vmulq_n_s32(cr, 104595), vmulq_n_s32(cr, 104595));
				const int32x4_t gc = vmlaq_n_s32(vmulq_n_s32(cb, -25624), cr, -53280);
				const int32x4x2_t tg = vzipq_s32(gc, gc);
				const int32x4x2_t tb = vzipq_s32(vmulq_n_s32(cb, 132251), vmulq_n_s32(cb, 132251));
				auto pack = [] (int32x4_t a, int32x4_t b) {
					return vqmovn_u16(vcombine_u16(vqmovun_s32(vshrq_n_s32(a, 16)), vqmovun_s32(vshrq_n_s32(b, 16))));
				};
				uint8x8x4_t px;
				px.val[0] = va;
				px.val[1] = pack(vaddq_s32(l0, tr.val[0]), vaddq_s32(l1, tr.val[1]));
				px.val[2] = pack(vaddq_s32(l0, tg.val[0]), vaddq_s32(l1, tg.val[1]));
				px.val[3] = pack(vaddq_s32(l0, tb.val[0]), vaddq_s32(l1, tb.val[1]));
				vst4_u8(dst, px);   // per pixel in memory: alpha, red, green, blue
				dst += 32;
			}
		}
#endif
		for ( ; x < x1; ++x)
		{
			const int32_t luma = ly[x];
			const int32_t cb = lcb[x >> 1] - 128;
			const int32_t cr = lcr[x >> 1] - 128;
			int32_t rr, g, b;

			if (csc)
			{
				// ITU-R BT.601, studio range, 16.16 fixed point
				const int32_t l = (luma - 16) * 76284;
				rr = (l + 104595 * cr) >> 16;
				g = (l - 25624 * cb - 53280 * cr) >> 16;
				b = (l + 132251 * cb) >> 16;
			}
			else
			{
				rr = cr + 128;
				g = luma;
				b = cb + 128;
			}

			if (is16bpp)
			{
				const uint32_t index = (y & 3) * 4 + (x & 3);
				const int32_t dither = (r.dither[index >> 3] >> (28 - (index & 7) * 4)) & 0xf;
				rr = std::clamp(rr + (dither >> 1), 0, 255);
				g = std::clamp(g + (dither >> 1), 0, 255);
				b = std::clamp(b + (dither >> 1), 0, 255);
				const uint16_t pixel = (BIT(alpha, 7) << 15) | ((rr >> 3) << 10) | ((g >> 3) << 5) | (b >> 3);
				*dst++ = pixel >> 8;
				*dst++ = pixel & 0xff;
			}
			else
			{
				rr = std::clamp(rr, 0, 255);
				g = std::clamp(g, 0, 255);
				b = std::clamp(b, 0, 255);
				// Big-endian in memory: alpha, red, green, blue
				const uint32_t pixel = (uint32_t(b) << 24) | (uint32_t(g) << 16) | (uint32_t(rr) << 8) | alpha;
				memcpy(dst, &pixel, 4); // little-endian host
				dst += 4;
			}
		}
	}
	out.bytes.resize(dst - out.bytes.data()); // rows outside RAM took nothing
}
