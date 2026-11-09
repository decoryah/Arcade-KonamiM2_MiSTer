// tb_dspp.cpp: the DSP against MAME's logic (dspp.cpp, its interpreter copied here). Random programs, compared after each instruction, then
// their data read back through the host's port; the host writes to the data space meanwhile, somewhere harmless, which stops the program a clock.
// Then DMA: samples popped by a small program, against what's in memory, with chains and random memory latency.
//
//   tb_dspp [programs] [instructions each]
#include "Vm2_dspp.h"
#include "Vm2_dspp___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <deque>
#include <vector>
using std::vector;

static Vm2_dspp *t;
static uint64_t clocks;
static uint32_t rnd = 12345;
static uint32_t rn() { rnd = rnd * 1103515245 + 12345; return rnd >> 8; }
#define R t->rootp

// ---- memory for DMA
static vector<uint8_t> ram;
static std::deque<std::pair<uint32_t, int>> mq;
static int lat_max = 1;
static void tick()
{
	t->m_busy = lat_max > 1 && rn() % 3 == 0;
	t->m_ready = 0;
	if (!mq.empty() && --mq.front().second <= 0)
	{
		uint32_t o = (mq.front().first << 3) & (uint32_t(ram.size()) - 1);
		uint64_t v = 0;
		for (int i = 0; i < 8; i++) v |= uint64_t(ram[o + i]) << (8 * i);
		t->m_dout = v; t->m_ready = 1;
		mq.pop_front();
	}
	t->eval();
	bool took = t->m_rd && !t->m_busy;
	uint32_t a = t->m_a;
	t->clk = 1; t->eval(); t->clk = 0; t->eval();
	if (took) mq.push_back({a, 1 + int(rn() % lat_max)});
	clocks++;
}
static void hw(uint32_t off, uint32_t v)
{
	t->pre_a = off >> 2; t->a = off >> 2; t->we = 1; t->wd = v; tick(); t->we = 0; tick();
}
static uint32_t hr(uint32_t off)
{
	t->pre_a = off >> 2; tick(); t->a = off >> 2; t->eval(); uint32_t v = t->rd; tick(); return v;
}
static void reset()
{
	t->rst = 1; for (int i = 0; i < 8; i++) tick(); t->rst = 0; tick();
}

static int tr_a = -1, tr_p = -1; static bool tr_on;
// ---- MAME's
struct M {
	uint16_t code[1024], data[1024];
	uint32_t pc, stack[4], sp, rbase[4]; int32_t acc; uint32_t tclock;
	bool c, z, n, v, x; bool audlock; int32_t wb;
	uint16_t outs[8], ofifo[8]; uint32_t ostart, ocount;
	struct { uint16_t fifo[8]; uint32_t dspi, depth; uint16_t prev; } ch[16];
	uint32_t phase, freq, last; uint32_t partial; uint32_t time; uint16_t dur;
	struct { int32_t value; int32_t addr; } o[8]; uint32_t opi; uint16_t op;
	uint32_t underover, lA, lB, lM;
	void dev_reset() { pc = 0; sp = 0; ostart = 0; ocount = 0; audlock = 0; wb = -2; rbase[0] = 0; rbase[1] = 4; rbase[2] = 8; rbase[3] = 12; partial = 0; }
	uint16_t pop(int c_) { auto &d = ch[c_]; if (d.depth) { uint16_t q = d.fifo[d.dspi]; d.dspi = (d.dspi + 1) & 7; d.depth--; d.prev = q; return q; } underover |= 1u << c_; return d.prev; }
	uint16_t rd(uint32_t a)
	{
		a &= 0x3ff;
		if (a < 0x2e0) return data[a];
		if (a >= 0x300 && a < 0x380)
		{
			auto &d = ch[(a - 0x300) / 8];
			switch (a & 7) {
				case 0: return d.depth ? d.fifo[d.dspi] : d.prev;
				case 1: return !d.depth ? d.prev : d.depth == 1 ? d.fifo[d.dspi] : d.fifo[(d.dspi + 1) & 7];
				case 2: return last;
				case 3: return phase;
				case 4: return pop((a - 0x300) / 8);
				case 5: return d.depth;
			}
			return 0;
		}
		switch (a) { case 0x3de: return 1; case 0x3df: return ocount; case 0x3ee: return pc; case 0x3f6: return audlock; case 0x3f7: return tclock; default: return 0; }
	}
	void wr(uint32_t a, uint16_t q)
	{
		a &= 0x3ff;
		if (a < 0x2e0) { if (int(a) == tr_a && tr_on) printf("MAME write %03X = %04X, op %04X\n", a, q, op); data[a] = q; return; }
		if (a <= 0x2e7) { outs[a - 0x2e0] = q; return; }
		if (a >= 0x300 && a < 0x380)
		{
			int c_ = (a - 0x300) / 8; auto &d = ch[c_];
			switch (a & 7) {
				case 2: { freq = q; phase += freq; uint32_t k = (phase >> 15) & 3; phase &= 0x7fff; if (k > d.depth) k = d.depth; for (uint32_t i = 0; i < k; i++) pop(c_); last = k; break; }
				case 3: phase = q; break;
				case 4: d.fifo[d.dspi] = q; if (d.depth < 8) { d.dspi = (d.dspi + 1) & 7; d.depth++; } break;
			}
			return;
		}
		switch (a) {
			case 0x3d7:
				if (q & 1)
				{
					uint32_t e = (ostart + ocount) & 7;
					if (ocount == 8) ostart = (ostart + 2) & 7; else ocount += 2;
					ofifo[e] = outs[0]; ofifo[(e + 1) & 7] = outs[1];
					time++; if (--dur == 0xffff) partial |= 0x100;
					if (audlock) dev_reset();
				}
				break;
			case 0x3e6: partial |= uint32_t(q) << 16; break;
			case 0x3ee: pc = q & 0x3ff; break;
			case 0x3f6: audlock = q & 1; break;
			case 0x3f7: tclock = q; break;
		}
	}
	uint16_t fetch() { uint16_t w = code[pc]; pc = (pc + 1) & 0x3ff; return w; }
	uint32_t treg(uint32_t r) { return (rbase[(r >> 2) & 3] + (r & 3)) & 0x3ff; }
	void parse(uint32_t numops)
	{
		uint32_t opidx = 0, numregs = 0;
		for (auto &e : o) { e.value = -1; e.addr = -1; }
		opi = 0;
		while (opidx < numops)
		{
			uint16_t w = fetch();
			if (w & 0x8000)
			{
				if ((w & 0xc000) == 0xc000) { uint32_t val = (w & 0x2000) ? (w & 0x1fff) << 3 : uint16_t(int16_t(w << 3) >> 3); o[opidx++].value = val; }
				else if ((w & 0xe000) == 0x8000)
				{
					uint32_t a = w & 0x3ff;
					if (w & 0x400) a = rd(a) & 0x3ff;
					o[opidx].addr = a;
					if (w & 0x800) wb = a;
					opidx++;
				}
				else if ((w & 0xe000) == 0xa000) numregs = (w & 0x400) ? 2 : 1;
			}
			else numregs = 3;
			if (numregs)
			{
				for (uint32_t i = 0; i < numregs; i++)
				{
					uint32_t r = (w >> ((numregs - i - 1) * 5)) & 0x1f;
					uint32_t a = treg(r & 0xf);
					if (r & 0x10) a = rd(a) & 0x3ff;
					if (numregs == 2) { if (i == 0 && (w & 0x1000)) wb = a; else if (i == 1 && (w & 0x800)) wb = a; }
					else if (numregs == 1) { if (w & 0x800) wb = a; }
					o[opidx++].addr = a;
				}
				numregs = 0;
			}
		}
	}
	uint16_t rnext() { int32_t q = o[opi].value; if (q < 0) q = rd(o[opi].addr); opi++; return q; }
	void wnext(uint16_t q) { int32_t a = o[opi].addr; if (a >= 0) wr(a, q); opi++; }
	void setrb(uint32_t base, uint32_t a)
	{
		switch (base) {
			case 4: rbase[1] = a + 4 - base; break;
			case 0: rbase[0] = a; rbase[1] = a + 4 - base; [[fallthrough]];
			case 8: rbase[2] = a + 8 - base; [[fallthrough]];
			case 12: rbase[3] = a + 12 - base; break;
		}
		for (auto &b : rbase) b &= 0x3ff;
	}
	void step()
	{
		op = fetch();
		if (op & 0x8000) control(); else arith();
	}
	void control()
	{
		uint32_t mode = (op >> 13) & 3;
		bool br = false;
		if (mode == 0)
		{
			switch ((op >> 10) & 7) {
				case 0:
					switch ((op >> 7) & 7) {
						case 1: pc = (acc >> 4) & 0x3ff; break;
						case 4: if (sp) sp--; pc = stack[sp]; break;
						case 7: pc = (pc - 1) & 0x3ff; break;
					}
					break;
				case 1: pc = op & 0x3ff; break;
				case 2: if (sp < 4) stack[sp++] = pc; pc = op & 0x3ff; break;
				case 4: { uint32_t r = op & 0x3f; uint32_t a = treg(r & 0xf); if (r & 0x10) a = rd(a); parse(1); uint16_t q = rnext(); wr(a, q); break; }
				case 5: setrb((op & 3) << 2, op & 0x3fc); break;
				case 6: { parse(1); uint16_t q = rnext(); wr(op & 0x3ff, q); break; }
				case 7: { parse(1); uint32_t a = rd(op & 0x3ff); uint16_t q = rnext(); wr(a, q); break; }
			}
			return;
		}
		if (mode != 3)
		{
			bool f0 = (op & 0x1000) ? c : n, f1 = (op & 0x1000) ? z : v;
			br = (f0 || !(op & 0x800)) && (f1 || !(op & 0x400));
			if (mode == 2) br = !br;
		}
		else
			switch ((op >> 10) & 7) {
				case 0: br = n != v; break;
				case 1: br = n != v || z; break;
				case 2: br = n == v; break;
				case 3: br = n == v && !z; break;
				case 4: br = c && !z; break;
				case 5: br = !c || z; break;
				case 6: br = x; break;
				case 7: br = !x; break;
			}
		if (br) pc = op & 0x3ff;
	}
	void arith()
	{
		uint32_t numops = (op >> 13) & 3, muxa = (op >> 10) & 3, muxb = (op >> 8) & 3, alu = (op >> 4) & 15, bc = op & 15;
		int32_t mul = 0; uint32_t r = 0;
		if (numops == 0 && (muxa == 1 || muxa == 2 || muxb == 1 || muxb == 2)) numops = 4;
		if (bc == 8) numops++;
		parse(numops);
		if (muxa == 3 || muxb == 3)
		{
			int32_t a = int16_t(rnext());
			int32_t b = int16_t((op & 0x1000) ? rnext() : uint16_t(acc >> 4));
			mul = (a * b) >> 11;
		}
		int32_t A = 0, B = 0;
		switch (muxa) { case 0: A = acc; break; case 1: case 2: A = rnext() << 4; break; case 3: A = mul; break; }
		switch (muxb) { case 0: B = acc; break; case 1: case 2: B = rnext() << 4; break; case 3: B = mul; break; }
		A &= 0xfffff; B &= 0xfffff;
		lA = A; lB = B; lM = mul & 0xfffff;
		switch (alu) {
			case 0: case 8: r = A; v = 0; c = 0; break;
			case 1: r = -B; v = 0; c = 0; break;
			case 2: r = A + B; v = ((A & 0x80000) == (B & 0x80000)) && (uint32_t(A & 0x80000) != (r & 0x80000)); c = (r & 0x100000) != 0; break;
			case 3: r = A + (uint32_t(c) << 4); v = 0; c = (r & 0x100000) != 0; break;
			case 4: r = A - B; v = ((A & 0x80000) == (~B & 0x80000)) && (uint32_t(A & 0x80000) != (r & 0x80000)); c = (r & 0x100000) != 0; break;
			case 5: r = A - (uint32_t(c) << 4); v = 0; c = (r & 0x100000) != 0; break;
			case 6: r = A + 1; v = !(A & 0x80000) && (r & 0x80000); c = 0; break;
			case 7: r = A - 1; v = (A & 0x80000) && !(r & 0x80000); c = 0; break;
			case 9: r = ~A; v = 0; c = 0; break;
			case 10: r = A & B; v = 0; c = 0; break;
			case 11: r = ~(A & B); v = 0; c = 0; break;
			case 12: r = A | B; v = 0; c = 0; break;
			case 13: r = ~(A | B); v = 0; c = 0; break;
			case 14: r = A ^ B; v = 0; c = 0; break;
			case 15: r = ~(A ^ B); v = 0; c = 0; break;
		}
		n = (r & 0x80000) != 0; z = (r & 0xffff0) == 0; x = (r & 15) == 0;
		static const int shifts[8] = { 0, 1, 2, 3, 4, 5, 8, 16 };
		if (bc == 8) bc = rnext() & 15;
		auto sx = [](uint32_t q) { return int32_t(q << 12) >> 12; };
		if (bc & 8)
		{
			int s = shifts[(~bc + 1) & 7];
			acc = alu < 8 ? sx(r) >> s : int32_t((r & 0xfffff) >> s);
		}
		else
		{
			int s = shifts[bc];
			if (s == 16) acc = v ? (n ? 0x7ffff : int32_t(0xfff80000)) : sx(r);
			else acc = sx(r << s);
		}
		if (wb >= 0) { wr(wb, acc >> 4); wb = -1; }
		else if (opi < numops) wnext(acc >> 4);
	}
};
static M m;

static int errs;
static long c_ins, c_arith, c_mul, c_ctl, c_move, c_taken, c_pop, c_osc, c_push, c_frame, c_wb, c_shift[16], c_alu[16], c_sleepstop;
static void fail(const char *w, uint32_t a, uint32_t b, int prog, long ins)
{
	printf("FAIL %s: RTL %X MAME %X, program %d instruction %ld, op %04X pc %03X (clock %llu)\n", w, a, b, prog, ins, m.op, m.pc, (unsigned long long)clocks);
	if (errs == 0)
	{
		printf("  RTL A %05X B %05X mul %05X res %05X barrel %X; MAME A %05X B %05X mul %05X; operands", R->m2_dspp__DOT__alu_a, R->m2_dspp__DOT__alu_b, R->m2_dspp__DOT__mul_res, R->m2_dspp__DOT__res, R->m2_dspp__DOT__barrel, m.lA, m.lB, m.lM);
		for (int i = 0; i < 5; i++) printf(" %X/%X%s", R->m2_dspp__DOT__o_v[i], uint32_t(m.o[i].value < 0 ? m.o[i].addr : m.o[i].value), (R->m2_dspp__DOT__o_imm >> i) & 1 ? "i" : "");
		printf(" n %d\n", R->m2_dspp__DOT__o_n);
	}
	if (++errs > 10) { printf("too many\n"); exit(1); }
}

static void run_random(int prog, long n)
{
	lat_max = 1;
	reset();
	memset(&m, 0, sizeof m);
	m.dev_reset();
	for (int i = 0; i < 4; i++) m.stack[i] = R->m2_dspp__DOT__stack[i];     // (an RTS on nothing: a fatal error in MAME, its stack's top here)
	m.outs[0] = R->m2_dspp__DOT__out0; m.outs[1] = R->m2_dspp__DOT__out1;
	for (int i = 0; i < 16; i++)    // (a reset doesn't touch the FIFOs' words: nor MAME's)
	{
		for (int j = 0; j < 8; j++) m.ch[i].fifo[j] = R->m2_dspp__DOT__fifo__DOT__mem[i * 16 + j];
		m.ch[i].prev = R->m2_dspp__DOT__fifo__DOT__mem[i * 16 + 8];
	}
	for (int i = 0; i < 1024; i++)
	{
		uint16_t w = rn();
		switch (rn() % 8) {
			case 0: w = 0x8000 | (rn() & 0x3ff); break;                 // an address operand
			case 1: w = 0xc000 | (rn() & 0x3fff); break;                // a value
			case 2: w = rn() & 0x7fff; break;                           // arithmetic, or three registers
			case 3: w = 0xa000 | (rn() & 0x1fff); break;                // one or two registers
			case 4:
			{
				static const uint16_t a[] = {0x300, 0x301, 0x302, 0x303, 0x304, 0x305, 0x31a, 0x31c, 0x3df, 0x3de, 0x2e0, 0x2e1, 0x3d7, 0x3f6, 0x3e6};
				w = 0x8000 | a[rn() % 15];
				break;
			}
			case 5: w = 0x9800 | (rn() & 0x3ff); break;                 // MOVED
			default: break;
		}
		if ((w & 0xfc00) == 0x8000 && ((w >> 7) & 7) == 7) w ^= 0x80;   // no SLEEP: it would end the test
		if (i > 0 && rn() % 16 == 0) { m.code[i - 1] = 0x9bd7; hw((i - 1) * 4, 0x9bd7); w = 0xc001; }       // a frame
		if (i > 0 && rn() % 16 == 0) { uint16_t q = 0x9800 | (0x300 + (rn() % 3) * 8 + 4); m.code[i - 1] = q; hw((i - 1) * 4, q); w = 0xc000 | (rn() & 0x3fff); }   // a push
		if (i > 0 && rn() % 32 == 0) { uint16_t q = 0x9800 | (0x300 + (rn() % 3) * 8 + 2); m.code[i - 1] = q; hw((i - 1) * 4, q); w = 0xc000 | (rn() & 0x3fff); }   // the oscillator
		m.code[i] = w;
		hw(i * 4, w);
	}
	for (int i = 0; i < 0x2e0; i++)
	{
		uint16_t w = (rn() & 1) ? (rn() & 0xffff) : (rn() & 0x3ff);
		m.data[i] = w;
		hw(0x1000 + i * 4, w);
	}
	hw(0x6040, 3); m.dur = 3;
	t->pre_a = t->a = 0x6070 >> 2; t->we = 1; t->wd = 1; tick(); t->we = 0;     // (it starts the clock after)
	long ins = 0;
	bool frame_last = true;
	uint64_t frame_clock = 0;
	uint32_t last_t = 0;
	while (ins < n)
	{
		tr_on = prog == tr_p;
		if (tr_on) { t->eval(); if (R->m2_dspp__DOT__d_we && int(R->m2_dspp__DOT__d_wa) == tr_a) printf("RTL write %03X = %04X, op %04X s %d wv %04X\n", tr_a, R->m2_dspp__DOT__d_wd, R->m2_dspp__DOT__op, R->m2_dspp__DOT__s, R->m2_dspp__DOT__wv); }
		// the host, somewhere harmless
		bool poke = rn() % 7 == 0;
		t->a = 0x400 + 0x3ef; t->pre_a = 0x400 + 0x3ef; t->wd = 0; t->we = poke;
		t->dac_tick = 0;
		t->eval();
		if ((R->m2_dspp__DOT__s == 0 || R->m2_dspp__DOT__w_then_op) && !poke)
		{
			// (an instruction starting on the clock of the last one's write: what that write sets shows a clock later, checked below)
			const bool wthen = R->m2_dspp__DOT__w_then_op;
			uint32_t pc = R->m2_dspp__DOT__pc, acc = R->m2_dspp__DOT__acc & 0xfffff;
			if (pc != m.pc) fail("pc", pc, m.pc, prog, ins);
			if (acc != (uint32_t(m.acc) & 0xfffff)) fail("acc", acc, uint32_t(m.acc) & 0xfffff, prog, ins);
			uint32_t fl = R->m2_dspp__DOT__f_c << 4 | R->m2_dspp__DOT__f_z << 3 | R->m2_dspp__DOT__f_n << 2 | R->m2_dspp__DOT__f_v << 1 | R->m2_dspp__DOT__f_x;
			uint32_t fm = m.c << 4 | m.z << 3 | m.n << 2 | m.v << 1 | m.x;
			if (fl != fm) fail("flags", fl, fm, prog, ins);
			if (R->m2_dspp__DOT__sp != m.sp) fail("sp", R->m2_dspp__DOT__sp, m.sp, prog, ins);
			if (!wthen && uint32_t(R->m2_dspp__DOT__o_count) * 2 != m.ocount) fail("out count", R->m2_dspp__DOT__o_count * 2, m.ocount, prog, ins);
			if (!wthen && R->m2_dspp__DOT__partial_int != m.partial) fail("int", R->m2_dspp__DOT__partial_int, m.partial, prog, ins);
			if (!wthen && R->m2_dspp__DOT__up_time != m.time) fail("time", R->m2_dspp__DOT__up_time, m.time, prog, ins);
			if (bool(R->m2_dspp__DOT__wb_v) != (m.wb >= 0)) fail("wb", R->m2_dspp__DOT__wb_v, m.wb, prog, ins);
			if (m.wb >= 0 && R->m2_dspp__DOT__wb_a != uint32_t(m.wb)) fail("wb a", R->m2_dspp__DOT__wb_a, m.wb, prog, ins);
			if (R->m2_dspp__DOT__osc_phase != (m.phase & 0xffff)) fail("phase", R->m2_dspp__DOT__osc_phase, m.phase, prog, ins);
			for (int i = 0; i < 16; i++)
			{
				if (R->m2_dspp__DOT__depth[i] != m.ch[i].depth) fail("depth", R->m2_dspp__DOT__depth[i], m.ch[i].depth, prog, ins);
				if (R->m2_dspp__DOT__dspi[i] != m.ch[i].dspi) fail("dspi", R->m2_dspp__DOT__dspi[i], m.ch[i].dspi, prog, ins);
			}
			for (int i = 0; i < 4; i++) if (R->m2_dspp__DOT__rbase[i] != m.rbase[i]) fail("rbase", R->m2_dspp__DOT__rbase[i], m.rbase[i], prog, ins);
			// the DACs, in step with the instructions
			bool want_dac = false; uint16_t l = 0, r = 0;
			if (ins % 16 == 0 && !frame_last && clocks > frame_clock + 1 && m.ocount)
			{
				t->dac_tick = 1; want_dac = true;
				l = m.ofifo[m.ostart]; r = m.ofifo[(m.ostart + 1) & 7];
				m.ostart = (m.ostart + 2) & 7; m.ocount -= 2;
			}
			const uint32_t x_oc = m.ocount, x_pi = m.partial, x_tm = m.time;
			uint32_t t0 = m.time, pc0 = m.pc, wb0 = m.wb >= 0;
			uint16_t w0 = m.code[m.pc];
			uint32_t d0[16]; for (int i = 0; i < 16; i++) d0[i] = m.ch[i].depth;
			m.step();
			frame_last = m.time != t0;
			if (wthen && t0 != last_t) frame_clock = clocks;
			last_t = t0;
			ins++;
			c_ins++;
			if (!(w0 & 0x8000))
			{
				c_arith++; c_alu[(w0 >> 4) & 15]++; c_shift[w0 & 15]++;
				if (((w0 >> 10) & 3) == 3 || ((w0 >> 8) & 3) == 3) c_mul++;
				if (wb0 || m.wb >= 0) c_wb++;
			}
			else if (((w0 >> 13) & 3) == 0 && ((w0 >> 10) & 7) >= 4 && ((w0 >> 10) & 7) != 5) c_move++;
			else { c_ctl++; if (m.pc != ((pc0 + 1) & 0x3ff)) c_taken++; }
			for (int i = 0; i < 16; i++) { if (m.ch[i].depth < d0[i]) c_pop++; if (m.ch[i].depth > d0[i]) c_push++; }
			if (frame_last) c_frame++;
			if (m.pc == pc0 && w0 == m.code[pc0] && (w0 & 0xfc00) == 0x8000 && ((w0 >> 7) & 7) == 7) { c_sleepstop++; ins = n; }
			if (ins >= n) { t->pre_a = t->a = 0x6070 >> 2; t->we = 1; t->wd = 0; }     // (stopped now: this is the last it starts)
			tick();
			if (wthen)
			{
				if (uint32_t(R->m2_dspp__DOT__o_count) * 2 != x_oc) fail("out count", R->m2_dspp__DOT__o_count * 2, x_oc, prog, ins);
				if (R->m2_dspp__DOT__partial_int != x_pi) fail("int", R->m2_dspp__DOT__partial_int, x_pi, prog, ins);
				if (R->m2_dspp__DOT__up_time != x_tm) fail("time", R->m2_dspp__DOT__up_time, x_tm, prog, ins);
			}
			t->dac_tick = 0;
			if (want_dac)
			{
				if (t->dac_l != l) fail("dac l", t->dac_l, l, prog, ins);
				if (t->dac_r != r) fail("dac r", t->dac_r, r, prog, ins);
			}
			if (frame_last) { /* the FIFO's RAM takes a clock more than the bench gives it */ }
			continue;
		}
		tick();
	}
	t->we = 0;
	for (int i = 0; i < 40; i++) tick();
	for (int i = 0; i < 0x2e0; i++)
	{
		uint32_t q = hr(0x1000 + i * 4);
		if (q != m.data[i]) fail("data", q, m.data[i], prog, i);
	}
}

// ---- DMA: a program that pops a channel when there's something to pop, each to data 0x010; the bench collects them
static void asm_pop(int ch)
{
	uint16_t p[6] = { 0x2400, uint16_t(0x8000 | (0x300 + ch * 8 + 5)),      // load the depth
		0xb400,                                                             // zero: again
		0x9810, uint16_t(0x8000 | (0x300 + ch * 8 + 4)),                    // MOVED to 0x010 from the data
		0x8400 };                                                           // JUMP 0
	for (int i = 0; i < 6; i++) hw(i * 4, p[i]);
}
static uint16_t smp(uint32_t a, bool b8)
{
	uint32_t k = uint32_t(ram.size()) - 1;
	return b8 ? ram[a & k] << 8 : ram[a & k] << 8 | ram[(a + 1) & k];
}
static void dma_case(int cs, int ch, bool b8, uint32_t a1, uint32_t n1, uint32_t a2, uint32_t n2, bool forever)
{
	reset();
	lat_max = 1 + rn() % 40;
	mq.clear();
	asm_pop(ch);
	hw(b8 ? 0x6010 : 0x6014, 1u << ch);
	hw(0x5000 + ch * 16 + 0, a1); hw(0x5000 + ch * 16 + 4, n1);
	hw(0x5200 + ch * 16, 0x80000000);
	if (n2)
	{
		hw(0x5000 + ch * 16 + 8, a2); hw(0x5000 + ch * 16 + 12, n2);
		hw(0x5208 + ch * 16, 0x80000000 | 0x00010000 | 1 | (forever ? 0x00020002 : 0) | 0x00040000 | 4);
	}
	hw(0x4008, 1);
	hw(0x6000, 1u << ch);
	hw(0x6070, 1);
	vector<uint16_t> want;
	int sz = b8 ? 1 : 2;
	for (uint32_t i = 0; i < n1; i++) want.push_back(smp(a1 + i * sz, b8));
	for (int k = 0; k < (forever ? 3 : 1); k++)
		for (uint32_t i = 0; i < n2; i++) want.push_back(smp(a2 + i * sz, b8));
	size_t got = 0;
	bool saw_int = false;
	long c;
	for (c = 0; c < 2000000 && got < want.size(); c++)
	{
		t->eval();
		if (R->m2_dspp__DOT__d_we && R->m2_dspp__DOT__d_wa == 0x10)
		{
			uint32_t q = R->m2_dspp__DOT__d_wd;
			if (q != want[got]) { printf("FAIL dma case %d: sample %zu is %04X, wanted %04X\n", cs, got, q, want[got]); if (++errs > 10) exit(1); }
			got++;
		}
		tick();
		if (t->intr) saw_int = true;
	}
	if (got != want.size()) { printf("FAIL dma case %d: %zu samples of %zu\n", cs, got, want.size()); errs++; }
	if (n2 && !saw_int) { printf("FAIL dma case %d: no interrupt\n", cs); errs++; }
	for (int i = 0; i < 2000; i++) tick();
	if (!forever)
	{
		uint32_t en = hr(0x6000);
		if (en & (1u << ch)) { printf("FAIL dma case %d: still enabled\n", cs); errs++; }
		if (hr(0x1000 + 0x305 * 4) != 0) {}
		uint32_t a = hr(0x5000 + ch * 16), want_a = n2 ? a2 + n2 * sz : a1 + n1 * sz;
		if (a != want_a) { printf("FAIL dma case %d: address %08X, wanted %08X\n", cs, a, want_a); errs++; }
	}
	printf("dma case %d: %zu samples in %ld clocks, latency up to %d\n", cs, got, c, lat_max);
	lat_max = 1;
}

// a host's read and write of everything it can see, against the code just written
static void host_case()
{
	reset();
	for (int i = 0; i < 1024; i += 37) hw(i * 4, 0xa000 + i);
	for (int i = 0; i < 1024; i += 37) if (hr(i * 4) != uint32_t(0xa000 + i)) { printf("FAIL host code %d\n", i); errs++; }
	hw(0x6044, 0x12345678);
	if (hr(0x6044) != 0x12345678) { printf("FAIL host time\n"); errs++; }
	hw(0x4008, 0x130); hw(0x400c, 0x10);
	if (hr(0x4008) != 0x120) { printf("FAIL host int enable\n"); errs++; }
	hw(0x4000, 0x20);
	if (!(t->eval(), t->intr)) { tick(); }
	if (!t->intr) { printf("FAIL host int\n"); errs++; }
	if (hr(0x4000) != 0x20) { printf("FAIL host int state\n"); errs++; }
	hw(0x4004, 0x20);
	tick();
	if (t->intr) { printf("FAIL host int clear\n"); errs++; }
}

int main(int argc, char **argv)
{
	Verilated::commandArgs(argc, argv);
	t = new Vm2_dspp;
	int progs = argc > 1 ? atoi(argv[1]) : 200;
	long n = argc > 2 ? atol(argv[2]) : 3000;
	if (getenv("TR")) sscanf(getenv("TR"), "%d,%x", &tr_p, &tr_a);
	ram.resize(1 << 20);
	for (auto &b : ram) b = rn();
	host_case();
	for (int p = 0; p < progs; p++) run_random(p, n);
	printf("%d programs, %ld instructions, %d errors: %ld arithmetic (%ld multiplying, %ld writing back), %ld moves, %ld control (%ld going), %ld pops, %ld pushes, %ld frames, %ld ended in SLEEP\n",
		progs, c_ins, errs, c_arith, c_mul, c_wb, c_move, c_ctl, c_taken, c_pop, c_push, c_frame, c_sleepstop);
	printf("ALU"); for (long v : c_alu) printf(" %ld", v);
	printf("\nbarrel"); for (long v : c_shift) printf(" %ld", v);
	printf("\n");
	dma_case(0, 0, false, 0x1000, 40, 0, 0, false);
	dma_case(1, 3, false, 0x2002, 13, 0x3006, 9, false);
	dma_case(2, 15, true, 0x4003, 41, 0x5005, 11, false);
	dma_case(3, 7, false, 0x6004, 3, 0x7000, 16, true);
	dma_case(4, 1, true, 0x8000, 1, 0x9007, 1, false);
	printf(errs ? "FAIL %d errors\n" : "PASS\n", errs);
	return errs != 0;
}
