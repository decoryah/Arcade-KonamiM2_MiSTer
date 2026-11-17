// tb_mpeg_hps.cpp: the MPEG unit built with MPEG_HPS (rtl/m2_mpeg.sv) and the ARM's decoder (hps/m2mpegd: m2mpegd_core, the
// daemon's own code, in a thread of this program) on one block of memory and one game RAM, fed from the M2 emulator's MPEG dumps
// (made outside this repo). The bench plays the driver: the dump's register writes go to the unit (but the
// bitstream's own: CONFIG, the interrupt registers, the DMA's, which the bench writes itself as the M2 OS's MPEG driver would), and each picture's
// slice data is put in memory and given to the unit in pieces. Checked:
// - the reset's clear (the log and the line at +0x40 zero, then the header);
// - every log entry as it's written: its number, its kind, its contents, in the order of the writes and the pictures' ends;
// - at each picture's end entry: the picture's bytes are in the ring already, at the place the entry says;
// - when the end-of-picture interrupt comes: at once with no daemon; with one, not before the daemon's done word names the picture
//   (or after about 50 ms when the daemon's died, once; or after about 120 ms when it's late);
// - the pixels the daemon wrote into game RAM against the dump's (byte for byte for a full dump, the rows hashed for a slim one).
// The daemon runs in real time and the unit in simulated clocks: the unit's waits are in its own clocks (printed in ms of 66.67 MHz).
//
//   tb_mpeg_hps FILE... [--no-daemon] [--kill-after N] [--slow N:MS] [--pictures N] [--seed N] [-v]
#include "Vm2_mpeg.h"
#include "verilated.h"
#include "m2mpeg_protocol.h"
#include "m2mpegd_core.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <thread>
#include <vector>

using namespace m2p;

static Vm2_mpeg *t;
static uint64_t clocks;
static uint32_t rnd = 1;
static uint32_t rn() { rnd = rnd * 1103515245 + 12345; return rnd >> 8; }
static int bad;
#define FAIL(...) do { if (bad++ < 30) { printf("FAIL (clock %llu): ", (unsigned long long)clocks); printf(__VA_ARGS__); printf("\n"); } } while (0)

static uint32_t get32(const uint8_t *p) { return p[0] | (p[1] << 8) | (p[2] << 16) | (uint32_t(p[3]) << 24); }
static uint64_t get64(const uint8_t *p) { return get32(p) | (uint64_t(get32(p + 4)) << 32); }
static void put32(std::vector<uint8_t> &v, uint32_t x) { for (int i = 0; i < 4; ++i) v.push_back(uint8_t(x >> (i * 8))); }
static uint64_t fnv1a(const uint8_t *p, size_t n, uint64_t h = 0xcbf29ce484222325ULL)
{
	for (size_t i = 0; i < n; ++i) h = (h ^ p[i]) * 0x100000001b3ULL;
	return h;
}

// ---- memory: the block (at the unit's 0x58000000 +), the bitstream's (0x40000000 +: the bench's own, not the game RAM the daemon
// writes), game RAM (the daemon's only) -------------------------------------------------------------------------------------------
static volatile uint8_t *block, *ram;
static std::vector<uint8_t> smem(1 << 22);
static const uint32_t SBASE = 0x40000000;

struct Entry { uint32_t kind; uint64_t payload; };
static std::deque<Entry> expect;       // the entries the unit must write, in order
static uint32_t n_entries;             // written so far (since the reset)
static std::vector<uint8_t> cur_slices;
static uint64_t end_clock;             // the last picture's end entry: when, its number
static uint32_t end_seq;
static bool end_seen;
static uint64_t n_ring_writes, n_log_writes, n_beats, n_line_reads, n_headers, n_hold;

static void block_write(uint32_t off, uint64_t d, uint8_t be)
{
	if (off + 8 > BLOCK_SIZE) { FAIL("write outside the block: +%x", off); return; }
	if (be == 0xff) { st32(block, off, uint32_t(d)); st32(block, off + 4, uint32_t(d >> 32)); }
	else for (int i = 0; i < 8; i++) if ((be >> i) & 1) block[off + i] = uint8_t(d >> (8 * i));
	if (off >= OFF_RING) { n_ring_writes++; return; }
	if (be != 0xff) { FAIL("a part write outside the ring: +%x be %02x", off, be); return; }
	if (off >= OFF_LOG && off < OFF_LOG + 8 * LOG_ENTRIES)
	{
		if (d == 0) return;             // (the clear)
		n_log_writes++;
		if (off != OFF_LOG + 8 * (n_entries & (LOG_ENTRIES - 1))) FAIL("entry %u written at +%x", n_entries, off);
		const uint32_t kind = uint32_t(d >> 61) & 3, seq = uint32_t(d >> 48) & SEQ_MASK;
		const uint64_t payload = d & 0xffffffffffffULL;
		if (!(d >> 63) || seq != (n_entries & SEQ_MASK)) FAIL("entry %u: valid %d, number %u", n_entries, int(d >> 63), seq);
		if (expect.empty()) FAIL("entry %u (kind %u, %012llx) not expected", n_entries, kind, (unsigned long long)payload);
		else
		{
			if (expect.front().kind != kind || expect.front().payload != payload)
				FAIL("entry %u: kind %u %012llx, expected kind %u %012llx", n_entries, kind, (unsigned long long)payload, expect.front().kind,
					(unsigned long long)expect.front().payload);
			expect.pop_front();
		}
		if (kind == KIND_PICTURE_END)
		{
			// the picture's bytes are in the ring
			const uint32_t len = uint32_t(payload >> 24), pos = uint32_t(payload) & POS_MASK;
			if (len != cur_slices.size()) FAIL("picture end: length %u, the picture's %zu", len, cur_slices.size());
			else
				for (uint32_t i = 0; i < len; i++)
					if (block[OFF_RING + ((pos - len + i) & (RING_BYTES - 1))] != cur_slices[i]) { FAIL("picture end entry %u: ring byte %u of %u isn't the picture's", n_entries, i, len); break; }
			end_clock = clocks; end_seq = seq; end_seen = true;
		}
		n_entries++;
		return;
	}
	if (off == OFF_BEAT) { n_beats++; return; }
	if (off == OFF_HEADER) { n_headers++; if (d != ((uint64_t(MAGIC_HEADER) << 32) | (VERSION << 16) | (LOG_BITS << 8) | RING_BITS)) FAIL("header %016llx", (unsigned long long)d); return; }
	if (off >= 0x40 && off < 0x60 && d == 0) return;        // (the clear)
	FAIL("write of %016llx at +%x", (unsigned long long)d, off);
}

// the port: a read of 4 words answered after a while, a write taken when it isn't busy
static int m_wait = -1, m_beat;
static uint32_t m_addr;
static void clock1()
{
	t->m_busy = (rn() & 3) == 0;
	t->m_ready = 0;
	if (m_wait > 0) m_wait--;
	else if (m_wait == 0)
	{
		uint64_t v = 0;
		const uint32_t a = m_addr + m_beat * 8;
		if ((a >> 27) == 0x0b) v = uint64_t(ld32(block, a & 0x7fff8)) | (uint64_t(ld32(block, (a & 0x7fff8) + 4)) << 32);
		else for (int i = 0; i < 8; i++) v |= uint64_t(smem[(a - SBASE + i) & (smem.size() - 1)]) << (8 * i);
		t->m_dout = v;
		t->m_ready = 1;
		if (++m_beat == 4) m_wait = -1;
	}
	t->clk = 0; t->eval();
	if (t->m_rd && t->m_we) FAIL("a read and a write at once");
	if (!t->m_busy)
	{
		if (t->m_rd)
		{
			if (m_wait >= 0) FAIL("a second read while one is out");
			m_addr = uint32_t(t->m_a) << 3; m_beat = 0; m_wait = 8 + (rn() & 7);
			if ((m_addr >> 27) == 0x0b) { n_line_reads++; if ((m_addr & 0x7ffff) != OFF_PRESENT) FAIL("read of the block at +%x", m_addr & 0x7ffff); }
		}
		else if (t->m_we)
		{
			const uint32_t a = uint32_t(t->m_a) << 3;
			if ((a >> 27) != 0x0b) FAIL("write at %08x", a);
			else block_write(a & 0x7ffff, t->m_wd, t->m_be);
		}
	}
	t->clk = 1; t->eval();
	t->we = 0;
	clocks++;
}
static void wr(uint32_t off, uint32_t d)
{
	for (int g = 0; t->hold; g++) { n_hold++; clock1(); if (g > 1000000) { FAIL("hold never ends"); break; } }      // (as m2_boot: no register access starts)
	t->a = off >> 2; t->wd = d; t->we = 1;
	expect.push_back({ KIND_WRITE, (uint64_t((off >> 2) & 0xff) << 32) | d });
	clock1();
}
static uint32_t rd(uint32_t off) { t->a = off >> 2; t->we = 0; t->eval(); return t->rd; }
static double ms_of(uint64_t c) { return c / 66666.667; }

// ---- the dumps ----------------------------------------------------------------------------------------------------------------------
struct picture_rec
{
	uint32_t seq_dump, image_size, format_config, format_crop, format_output, ram_start, ram_end;
	const uint8_t *slices; uint32_t slice_len;
	bool present, slim;
	const uint8_t *out; uint32_t out_len; uint64_t out_hash;
};
static bool parse_picture(const std::vector<uint8_t> &p, bool slim, picture_rec &r)
{
	if (p.size() < 12 + 17 * 4 + 128 + 4) return false;
	r.seq_dump = get32(&p[8]);
	const uint8_t *v = &p[12];
	r.image_size = get32(v + 3 * 4); r.format_config = get32(v + 7 * 4); r.format_crop = get32(v + 9 * 4); r.format_output = get32(v + 10 * 4);
	r.ram_start = get32(v + 15 * 4); r.ram_end = get32(v + 16 * 4);
	size_t o = 12 + 17 * 4 + 128;
	r.slice_len = get32(&p[o]); o += 4;
	if (o + r.slice_len + 4 > p.size()) return false;
	r.slices = &p[o]; o += r.slice_len;
	const uint32_t errlen = get32(&p[o]); o += 4 + errlen;
	if (o + 4 > p.size()) return false;
	r.present = get32(&p[o]) != 0; o += 4;
	r.slim = slim;
	if (slim)
	{
		if (o + 12 > p.size()) return false;
		r.out_len = get32(&p[o]); r.out_hash = get64(&p[o + 4]); r.out = nullptr;
	}
	else { r.out = &p[o]; r.out_len = uint32_t(p.size() - o); r.out_hash = 0; }
	return true;
}
static bool check_output(const picture_rec &r, uint64_t &bytes)
{
	if (!r.present) return true;
	auto ram_at = [&] (uint32_t addr) { return ram + ((addr - RAM_M2_BASE) & (RAM_BYTES - 1)); };
	if (!r.slim)
	{
		const uint32_t x0 = get32(r.out), y0 = get32(r.out + 4), x1 = get32(r.out + 8), y1 = get32(r.out + 12);
		const uint32_t stride = get32(r.out + 16), bpp = get32(r.out + 20);
		const uint32_t rb = x1 > x0 ? (x1 - x0) * bpp : 0;
		const uint8_t *q = r.out + 24;
		std::vector<uint8_t> row(rb);
		for (uint32_t y = y0; y < y1; ++y)
		{
			if (!*q++) continue;
			copy_from_device(row.data(), ram_at(r.format_output + (y - y0) * stride), rb);
			if (memcmp(row.data(), q, rb)) return false;
			q += rb; bytes += rb;
		}
		return q == r.out + r.out_len;
	}
	const uint32_t width = (r.image_size & 0xff) * 16, height = ((r.image_size >> 8) & 0xff) * 16;
	const uint32_t stride = (r.format_config & 0x1ff) * 32, bpp = (r.format_config & 0x00100000) ? 2 : 4;
	const uint32_t x0 = ((r.format_crop >> 24) & 0x7f) * 16, y0 = ((r.format_crop >> 16) & 0x7f) * 16;
	const uint32_t x1 = std::min(((r.format_crop >> 8) & 0x7f) * 16 + 16, width);
	const uint32_t y1 = std::min((r.format_crop & 0x7f) * 16 + 16, height);
	std::vector<uint8_t> s;
	for (uint32_t v : { x0, y0, x1, y1, stride, bpp }) put32(s, v);
	const uint32_t rb = x1 > x0 ? (x1 - x0) * bpp : 0;
	for (uint32_t y = y0; y < y1; ++y)
	{
		const uint32_t row = r.format_output + (y - y0) * stride;
		if (row < r.ram_start || row + (x1 - x0) * 4 > r.ram_end) { s.push_back(0); continue; }
		s.push_back(1);
		const size_t at = s.size();
		s.resize(at + rb);
		copy_from_device(s.data() + at, ram_at(row), rb);
		bytes += rb;
	}
	return s.size() == r.out_len && fnv1a(s.data(), s.size()) == r.out_hash;
}
struct pending { uint32_t seq; std::vector<uint8_t> record; bool slim; };

int main(int argc, char **argv)
{
	std::vector<const char *> files;
	bool daemon = true, verbose = false;
	int kill_after = -1, slow_picture = -1, slow_ms = 0;
	long max_pictures = -1;
	for (int i = 1; i < argc; ++i)
	{
		if (!strcmp(argv[i], "--no-daemon")) daemon = false;
		else if (!strcmp(argv[i], "--kill-after") && i + 1 < argc) kill_after = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--slow") && i + 1 < argc) { slow_picture = atoi(argv[++i]); const char *c = strchr(argv[i], ':'); slow_ms = c ? atoi(c + 1) : 0; }
		else if (!strcmp(argv[i], "--pictures") && i + 1 < argc) max_pictures = atol(argv[++i]);
		else if (!strcmp(argv[i], "--seed") && i + 1 < argc) rnd = uint32_t(atoi(argv[++i]));
		else if (!strcmp(argv[i], "-v")) verbose = true;
		else files.push_back(argv[i]);
	}
	if (files.empty()) { fprintf(stderr, "usage: tb_mpeg_hps FILE... [--no-daemon] [--kill-after N] [--slow N:MS] [--pictures N] [--seed N] [-v]\n"); return 2; }

	std::vector<uint8_t> block_mem(BLOCK_SIZE + 64, 0x5a), ram_mem(RAM_BYTES + 64, 0);     // (the block starts as a session before left it: not clear)
	block = reinterpret_cast<volatile uint8_t *>((reinterpret_cast<uintptr_t>(block_mem.data()) + 63) & ~uintptr_t(63));
	ram = reinterpret_cast<volatile uint8_t *>((reinterpret_cast<uintptr_t>(ram_mem.data()) + 63) & ~uintptr_t(63));
	// (as a daemon of the session before left its line: present, a done word)
	st32(block, OFF_PRESENT + 4, MAGIC_PRESENT); st32(block, OFF_PRESENT, 77); st32(block, OFF_DONE, DONE_VALID | 5);

	t = new Vm2_mpeg;
	// a reset: the unit clears the log and the line, then writes the header
	auto reset = [&] (bool first) {
		expect.clear(); n_entries = 0;
		t->rst = 1; for (int i = 0; i < 4; i++) clock1(); t->rst = 0;
		const uint64_t h0 = n_headers;
		for (int g = 0; n_headers == h0; g++) { clock1(); if (g > 200000) { FAIL("no header after the reset"); break; } }
		for (uint32_t o = OFF_LOG; o < OFF_LOG + 8 * LOG_ENTRIES; o += 4) if (ld32(block, o)) { FAIL("the log isn't clear at +%x after the reset", o); break; }
		if (first) for (uint32_t o = 0x40; o < 0x60; o += 4) if (ld32(block, o)) { FAIL("the line at +0x40 isn't clear after the reset (+%x)", o); break; }
		if (ld32(block, OFF_HEADER) != ((VERSION << 16) | (LOG_BITS << 8) | RING_BITS)) FAIL("the header's low half");
	};
	reset(true);
	const uint64_t reset_clocks = clocks;

	std::atomic<bool> stop{false}, die{false};
	mpegd_stats dst;
	mpegd_end dend = mpegd_end::stopped;
	std::thread dthread;
	if (daemon)
		dthread = std::thread([&] {
			mpegd_options o;
			o.stop = &stop; o.die = &die; o.slow_picture = slow_picture; o.slow_ms = slow_ms; o.log = verbose ? stderr : nullptr;
			dend = mpegd_session(block, ram, o, dst);
		});
	// (the unit's clocks go on while the bench waits for the daemon in real time)
	auto wait_present = [&] {
		if (!daemon || die) return;
		for (int k = 0; k < 4000 && ld32(block, OFF_PRESENT + 4) != MAGIC_PRESENT; ++k) { for (int i = 0; i < 20000; i++) clock1(); std::this_thread::sleep_for(std::chrono::milliseconds(1)); }
		if (ld32(block, OFF_PRESENT + 4) != MAGIC_PRESENT) FAIL("the daemon never attached");
	};
	wait_present();

	uint64_t pictures = 0, verified = 0, failed = 0, unverified = 0, no_output = 0, bytes = 0, rel[4] = {}, ring_total = 0;
	uint64_t held_sum = 0, held_max = 0, dead_held = 0, timeout_held = 0, once_max = 0;
	uint32_t pos_total = 0;
	long first_timeout = -1;
	std::deque<pending> waiting;
	auto verify = [&] (const pending &w) {
		picture_rec r;
		parse_picture(w.record, w.slim, r);
		if (!r.present) ++no_output;
		else if (check_output(r, bytes)) ++verified;
		else { ++failed; FAIL("OUTPUT DIFFERS: dump picture %u (entry %u)", r.seq_dump, w.seq); }
	};
	auto settle = [&] {
		const uint32_t d = ld32(block, OFF_DONE);
		if (!(d & DONE_VALID)) return;
		const uint32_t ds = d & SEQ_MASK;
		while (!waiting.empty() && ((ds - waiting.front().seq) & SEQ_MASK) < LOG_ENTRIES) { verify(waiting.front()); waiting.pop_front(); }
	};
	const auto t_start = std::chrono::steady_clock::now();
	auto quit = [&] { stop = true; if (dthread.joinable()) dthread.join(); };

	for (size_t fi = 0; fi < files.size() && bad == 0; ++fi)
	{
		FILE *f = fopen(files[fi], "rb");
		char head[12];
		if (!f || fread(head, 1, 12, f) != 12 || memcmp(head, "M2MPGDMP", 8)) { fprintf(stderr, "%s: not a dump\n", files[fi]); quit(); return 2; }
		if (fi > 0) { reset(false); pos_total = 0; waiting.clear(); wait_present(); }
		uint64_t file_pictures = 0;
		std::vector<uint8_t> payload;
		uint8_t h[8];
		while (fread(h, 1, 8, f) == 8 && bad == 0 && (max_pictures < 0 || long(pictures) < max_pictures))
		{
			payload.resize(get32(h + 4));
			if (fread(payload.data(), 1, payload.size(), f) != payload.size()) break;
			if (!memcmp(h, "WREG", 4))
			{
				const uint32_t off = get32(&payload[8]);
				if (off < 0x04 || off > 0x1c) wr(off, get32(&payload[12]));      // (not CONFIG, the interrupts', the DMA's: the bench's own below)
			}
			else if (!memcmp(h, "RSET", 4) && file_pictures > 0) { reset(false); pos_total = 0; waiting.clear(); wait_present(); }
			else if (!memcmp(h, "PICT", 4) || !memcmp(h, "PICS", 4))
			{
				const bool slim = h[3] == 'S';
				picture_rec r;
				if (!parse_picture(payload, slim, r) || r.ram_start != RAM_M2_BASE || r.ram_end != RAM_M2_BASE + RAM_BYTES - 1) { fprintf(stderr, "%s: a picture record the bench can't take\n", files[fi]); quit(); return 2; }
				// the picture's data in memory, two bytes of read-ahead and some more after it; given in pieces
				cur_slices.assign(r.slices, r.slices + r.slice_len);
				std::vector<uint8_t> s(cur_slices);
				for (int i = 0; i < 10; i++) s.push_back(uint8_t(rn()));
				const uint32_t at = SBASE + 0x1000 + (rn() % 0x100000);
				for (size_t i = 0; i < s.size(); i++) smem[(at - SBASE + i) & (smem.size() - 1)] = s[i];
				pos_total = (pos_total + r.slice_len) & POS_MASK;
				ring_total += r.slice_len;
				bool told = false;
				size_t pos = 0;
				auto give = [&] () {
					size_t n = 1 + rn() % 16384;
					if (pos + n + 16 > s.size()) n = s.size() - pos;        // (the picture's end and what's after it in one piece)
					wr(0x18, at + uint32_t(pos)); wr(0x1c, uint32_t(n));
					pos += n;
				};
				// (the picture's end entry comes after the last write before the data's all given)
				auto tell = [&] () { if (!told && pos >= s.size()) { told = true; expect.push_back({ KIND_PICTURE_END, (uint64_t(r.slice_len) << 24) | pos_total }); } };
				wr(0x08, 0x33); wr(0x0c, 0xff); wr(0x14, 0);
				give();
				end_seen = false;
				wr(0x04, 0x02);
				tell();
				bool got = false;
				for (int guard = 0; guard < 100000 && !got && bad == 0; guard++)
				{
					uint64_t c0 = clocks;
					while (!t->intr && clocks - c0 < 12000000) clock1();
					if (!t->intr) { FAIL("no interrupt (picture %llu, status %02x)", (unsigned long long)pictures, rd(0x0c)); break; }
					const uint32_t st = rd(0x0c);
					if (st & 0x02)
					{
						// the picture's done: how it was let go
						if (!end_seen) FAIL("the end-of-picture interrupt before the picture's end entry");
						const uint64_t held = clocks - end_clock;
						const bool done = ld32(block, OFF_DONE) == (DONE_VALID | end_seq) && daemon;
						int how = done ? 1 : held < 40000 ? 0 : ms_of(held) < 100 ? 2 : 3;
						if (how == 0) once_max = std::max(once_max, held);
						if (how == 1) { held_sum += held; held_max = std::max(held_max, held); }
						if (how == 2) dead_held = held;
						if (how == 3 && first_timeout < 0) { timeout_held = held; first_timeout = long(pictures); }
						++rel[how];
						if (verbose) printf("picture %llu (entry %u): %s after %.2f ms\n", (unsigned long long)pictures, end_seq, how == 0 ? "at once" : how == 1 ? "done" : how == 2 ? "dead" : "time-out", ms_of(held));
						got = true;
					}
					wr(0x0c, st);
					if ((st & 0x01) && !got)
					{
						if (pos >= s.size()) { FAIL("the unit wants more data than the picture has"); break; }
						give();
						tell();
					}
				}
				for (int i = 0; i < 3; i++) wr(0x04, 0x12);     // (the driver steps the parser through the read-ahead)
				wr(0x04, 0x00);
				++pictures; ++file_pictures;
				if (daemon && !die) waiting.push_back({ end_seq, payload, slim });
				else ++unverified;
				settle();
				if (kill_after >= 0 && long(pictures) == kill_after && daemon)
				{
					// (the pictures before it done first, so that what's counted is the picture after the kill)
					for (int k = 0; k < 2000 && !waiting.empty(); ++k) { settle(); for (int i = 0; i < 2000; i++) clock1(); std::this_thread::sleep_for(std::chrono::milliseconds(1)); }
					die = true;
					unverified += waiting.size(); waiting.clear();
					std::this_thread::sleep_for(std::chrono::milliseconds(20));
				}
			}
		}
		fclose(f);
		for (int k = 0; k < 8000 && !waiting.empty(); ++k) { settle(); for (int i = 0; i < 2000; i++) clock1(); if (!waiting.empty()) std::this_thread::sleep_for(std::chrono::milliseconds(1)); }
		unverified += waiting.size(); waiting.clear();
		for (int i = 0; i < 2000; i++) clock1();
		if (!expect.empty()) FAIL("%zu entries never written", expect.size());
		printf("%s: %llu pictures\n", files[fi], (unsigned long long)file_pictures);
	}
	stop = true;
	if (dthread.joinable()) dthread.join();
	const double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t_start).count();

	// what each way of running must show
	if (!daemon && rel[0] != pictures) FAIL("no daemon: %llu of %llu pictures let go at once", (unsigned long long)rel[0], (unsigned long long)pictures);
	if (daemon && kill_after < 0 && slow_picture < 0 && rel[1] != pictures) FAIL("%llu of %llu pictures waited for the daemon's done", (unsigned long long)rel[1], (unsigned long long)pictures);
	if (daemon && kill_after >= 0 && long(pictures) > kill_after && (rel[2] != 1 || rel[0] != pictures - kill_after - 1 || ms_of(dead_held) < 45 || ms_of(dead_held) > 60))
		FAIL("killed after %d: dead %llu (held %.1f ms), at once %llu", kill_after, (unsigned long long)rel[2], ms_of(dead_held), (unsigned long long)rel[0]);
	// (the daemon sleeps in real time: the pictures after the late one may time out too, until it has caught up)
	if (daemon && slow_picture >= 0 && long(pictures) > slow_picture && (rel[3] < 1 || first_timeout != slow_picture || ms_of(timeout_held) < 115 || ms_of(timeout_held) > 125 || dst.late < 1))
		FAIL("slow picture %d: time-outs %llu (held %.1f ms)", slow_picture, (unsigned long long)rel[3], ms_of(timeout_held));
	if (daemon && kill_after < 0 && (unverified || verified + no_output != pictures)) FAIL("%llu pictures' output not checked", (unsigned long long)unverified);

	printf("the reset's clear and header: %llu clocks (%.2f ms)\n", (unsigned long long)reset_clocks, ms_of(reset_clocks));
	printf("pictures %llu: output equal %llu (%llu bytes compared), differ %llu, not checked %llu, nothing to format %llu\n", (unsigned long long)pictures,
		(unsigned long long)verified, (unsigned long long)bytes, (unsigned long long)failed, (unsigned long long)unverified, (unsigned long long)no_output);
	printf("let go: at once %llu (within %llu clocks), done %llu, dead daemon %llu, time-out %llu\n", (unsigned long long)rel[0], (unsigned long long)once_max,
		(unsigned long long)rel[1], (unsigned long long)rel[2], (unsigned long long)rel[3]);
	if (rel[1]) printf("held for done: mean %.2f ms, max %.2f ms of the unit's clocks\n", ms_of(held_sum / rel[1]), ms_of(held_max));
	if (rel[2]) printf("the dead daemon's picture was held %.1f ms\n", ms_of(dead_held));
	if (rel[3]) printf("the late picture was held %.1f ms\n", ms_of(timeout_held));
	printf("writes: %llu log entries, %llu ring words for %llu bytes (%.2f bytes a write), %llu counts; %llu reads of the line\n", (unsigned long long)n_log_writes,
		(unsigned long long)n_ring_writes, (unsigned long long)ring_total, n_ring_writes ? double(ring_total) / n_ring_writes : 0.0, (unsigned long long)n_beats, (unsigned long long)n_line_reads);
	printf("register writes waited %llu clocks for room in the log's queue\n", (unsigned long long)n_hold);
	if (daemon)
		printf("daemon: %llu pictures, %llu late, %llu resyncs, %llu decoder errors, %llu entries; ended %s\n", (unsigned long long)dst.pictures, (unsigned long long)dst.late,
			(unsigned long long)dst.resyncs, (unsigned long long)dst.errors, (unsigned long long)dst.entries,
			dend == mpegd_end::stopped ? "stopped" : dend == mpegd_end::died ? "killed" : dend == mpegd_end::beat_stopped ? "beat stopped" : "header gone");
	printf("%llu clocks (%.1f s of the unit's), %.1f s: %s\n", (unsigned long long)clocks, clocks / 66666667.0, secs, bad ? "FAIL" : "PASS");
	return bad ? 1 : 0;
}
