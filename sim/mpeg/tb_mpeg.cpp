// tb_mpeg.cpp: the MPEG unit's control (rtl/m2_mpeg.sv) against the M2 emulator's (3dom2.cpp m2_mpeg_device, its bitstream and registers, no
// decoding), on random bitstreams given in random pieces as the driver would: after every interrupt, the registers the driver reads (the DMA's
// address and length, the parser's status as it steps through the read-ahead) must be the emulator's.
//
//   tb_mpeg [tests] [seed]
#include "Vm2_mpeg.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>

static Vm2_mpeg *t;
static uint64_t clocks;
static std::vector<uint8_t> mem(1 << 20);   // at 0x40000000
static const uint32_t BASE = 0x40000000;
static uint32_t rnd = 1;
static uint32_t rn() { rnd = rnd * 1103515245 + 12345; return rnd >> 8; }

// memory: a read of 4 words, answered after a while
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
		for (int i = 0; i < 8; i++) v |= uint64_t(mem[(m_addr - BASE + m_beat * 8 + i) & (mem.size() - 1)]) << (8 * i);
		t->m_dout = v;
		t->m_ready = 1;
		if (++m_beat == 4) m_wait = -1;
	}
	t->clk = 0; t->eval();
	if (t->m_rd && !t->m_busy && m_wait < 0) { m_addr = uint32_t(t->m_a) << 3; m_beat = 0; m_wait = 8 + (rn() & 7); }
	t->clk = 1; t->eval();
	t->we = 0;
	clocks++;
}
static void wr(uint32_t off, uint32_t d) { t->a = off >> 2; t->wd = d; t->we = 1; clock1(); }
static uint32_t rd(uint32_t off) { t->a = off >> 2; t->we = 0; t->eval(); return t->rd; }

// the emulator's, as 3dom2.cpp has it
struct Ref
{
	uint32_t config = 0, int_status = 0, cur_addr = 0, cur_len = 0, next_addr = 0, next_len = 0, parser = 0, isize = 0, crop = 0;
	enum { IDLE, SLICES, READAHEAD, DONE } state = IDLE;
	uint32_t shift = ~0u, ra_count = 0, eval_pos = 0, consumed = 0;
	uint8_t last_sc = 0, ra[2] = { 0, 0 };
	bool pending = false;   // the timer
	void write(uint32_t reg, uint32_t data)
	{
		switch (reg)
		{
		case 0x04:
		{
			uint32_t old = config; config = data;
			if (!(data & 2)) { state = IDLE; pending = false; }
			else if (!(old & 2)) { state = SLICES; shift = ~0u; ra_count = 0; eval_pos = 0; consumed = 0; if (next_len) pending = true; }
			else if ((data & 0x10) && state == DONE) ++eval_pos;
			break;
		}
		case 0x0c: int_status &= ~data; break;
		case 0x10: cur_addr = data; break;
		case 0x14: cur_len = data; break;
		case 0x18: next_addr = data; break;
		case 0x1c: next_len = data; if (data && cur_len == 0 && (state == SLICES || state == READAHEAD)) pending = true; break;
		case 0x24: parser = data; break;
		case 0x2c: isize = data; break;
		case 0x40: crop = data; break;
		}
	}
	uint32_t read(uint32_t reg)
	{
		switch (reg)
		{
		case 0x0c: return int_status;
		case 0x10: return cur_addr;
		case 0x14: return cur_len;
		case 0x18: return next_addr;
		case 0x1c: return next_len;
		case 0x28:
		{
			uint32_t e = 0;
			for (uint32_t i = 0; i < 2; ++i) if (eval_pos + i < ra_count) e |= ra[eval_pos + i] << (8 - i * 8);
			return e;
		}
		case 0x5c: return (3 << 16) | (last_sc << 8);
		}
		return 0;
	}
	void process()
	{
		pending = false;
		if (cur_len == 0 && next_len) { cur_addr = next_addr; cur_len = next_len; next_len = 0; consumed = 0; }
		while (cur_len && (state == SLICES || state == READAHEAD))
		{
			uint8_t data = mem[(cur_addr - BASE) & (mem.size() - 1)];
			++cur_addr; --cur_len; ++consumed;
			if (state == SLICES)
			{
				shift = (shift << 8) | data;
				if ((shift & 0xffffff00) == 0x00000100 && (data < 0x01 || data > 0xaf))
				{
					last_sc = data;
					uint32_t mb_height = (isize >> 8) & 0xff;
					bool cropped_b = (parser & 7) == 3 && (crop & 0x7f) + 1 < mb_height;
					if (cropped_b)
					{
						if (consumed >= 4) { cur_addr -= 4; cur_len += 4; consumed -= 4; }
						state = DONE; eval_pos = 0; ra_count = 0; int_status |= 0x32;
						return;
					}
					state = READAHEAD; ra_count = 0;
				}
			}
			else
			{
				ra[ra_count++] = data;
				if (ra_count == 2) { state = DONE; eval_pos = 0; int_status |= 0x32; return; }
			}
		}
		if (cur_len == 0) int_status |= 0x01;
	}
};

int main(int argc, char **argv)
{
	int tests = argc > 1 ? atoi(argv[1]) : 200;
	rnd = argc > 2 ? uint32_t(atoi(argv[2])) : 1;
	t = new Vm2_mpeg;
	t->rst = 1; for (int i = 0; i < 4; i++) clock1(); t->rst = 0;
	int bad = 0, pictures = 0, refills = 0;
	auto check = [&](Ref &rr, const char *when, int k) {
		for (uint32_t reg : { 0x0cu, 0x10u, 0x14u, 0x1cu, 0x28u, 0x5cu })
		{
			uint32_t a = rd(reg), b = rr.read(reg);
			if (a != b) { if (bad++ < 20) printf("test %d %s: reg %03x core %08x emulator %08x\n", k, when, reg, a, b); }
		}
	};
	Ref r;                  // (one, as the unit's state carries from picture to picture)
	for (int k = 0; k < tests; k++)
	{
		// a stream: slices (start codes 01-af), then a picture's or another start code, and two more bytes; with stray 00 00 01s inside
		std::vector<uint8_t> s;
		int nslice = 1 + rn() % 4;
		for (int i = 0; i < nslice; i++)
		{
			s.insert(s.end(), { 0, 0, 1, uint8_t(1 + rn() % 0xaf) });
			int n = rn() % 300;
			for (int j = 0; j < n; j++) s.push_back(uint8_t(rn() % 7 == 0 ? 0 : rn()));
		}
		uint8_t endc = rn() % 3 == 0 ? uint8_t(0xb0 + rn() % 0x50) : 0x00;
		s.insert(s.end(), { 0, 0, 1, endc, uint8_t(rn()), uint8_t(rn()), uint8_t(rn()), uint8_t(rn()) });
		uint32_t at = BASE + 0x1000 + (rn() % 0x40000);
		for (size_t i = 0; i < s.size(); i++) mem[at - BASE + i] = s[i];
		// the picture's settings: sometimes a B picture cropped
		uint32_t ptype = 1 + rn() % 3, mbh = 1 + rn() % 15, crop = rn() % 16;
		wr(0x24, ptype); r.write(0x24, ptype);
		wr(0x2c, mbh << 8 | 20); r.write(0x2c, mbh << 8 | 20);
		wr(0x40, crop); r.write(0x40, crop);
		wr(0x08, 0x33);
		wr(0x0c, 0xff); r.write(0x0c, 0xff);
		wr(0x14, 0); r.write(0x14, 0);
		// the stream in pieces, the first given before the start
		size_t pos = 0;
		auto give = [&]() {
			size_t n = 1 + rn() % 200;
			if (pos + n > s.size()) n = s.size() - pos;
			wr(0x18, at + uint32_t(pos)); r.write(0x18, at + uint32_t(pos));
			wr(0x1c, uint32_t(n)); r.write(0x1c, uint32_t(n));
			pos += n;
		};
		give();
		wr(0x04, 0x02); r.write(0x04, 0x02);
		for (int guard = 0; guard < 1000; guard++)
		{
			// the core's until an interrupt (or a while); the emulator's at once
			uint64_t c0 = clocks;
			while (!t->intr && clocks - c0 < 20000) clock1();
			if (r.pending) r.process();
			if (!t->intr) { if (bad++ < 20) printf("test %d: no interrupt (emulator's status %02x)\n", k, r.int_status); break; }
			check(r, "interrupt", k);
			uint32_t st = rd(0x0c);
			wr(0x0c, st); r.write(0x0c, st);
			if (st & 0x02)
			{
				pictures++;
				// the driver steps the parser through the read-ahead
				for (int i = 0; i < 3; i++) { wr(0x04, 0x12); r.write(0x04, 0x12); check(r, "step", k); }
				break;
			}
			if (st & 0x01)
			{
				if (pos >= s.size()) break;
				refills++;
				give();
			}
		}
		wr(0x04, 0x00); r.write(0x04, 0x00);
		for (int i = 0; i < 4; i++) clock1();
	}
	printf("%d tests, %d pictures, %d buffers refilled, %llu clocks: %s\n", tests, pictures, refills, (unsigned long long)clocks, bad ? "DIFFERENT" : "ALL SAME");
	return bad ? 1 : 0;
}
