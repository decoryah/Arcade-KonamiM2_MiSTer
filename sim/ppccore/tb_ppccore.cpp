// tb_ppccore [cases] [steps] [seed]: random programs on the RTL PPC602 (rtl/ppc_core.sv) and on the reference model
// (tools/ref/ppc602, checked against MAME by sim/ppcreplay), from the same random state and the same memory: every data
// access (order, address, size, data) and the registers after every instruction (or exception) must agree.
// The program is 2048 words at BASE, which is also IBR, so most exceptions land in it and the run goes on. A case ends
// when the program leaves it, or reaches an instruction the bench doesn't cover (op_ok: SPRs the RTL doesn't keep; little-
// endian mode). The float registers start with the hard cases often (gen_fp), in a random rounding mode.
// Built with PIPE (run.sh with PIPE=1), it runs the pipeline (rtl/ppc_pipe.sv) instead, free-running: its fetch and data
// sides answer in one clock (the data side, in the address clock), or (lat, the fourth argument, 1) after random
// delays, the data side with two accesses out at most, answered in order; the registers are compared at each retire
// (two at once: after the second) but for the ones an older
// load or float op hasn't written yet, and all of them after the last instruction. The model then has the pipeline's
// single-precision FPRs and its FP-unavailable exception (ppc602's sp, fpu_exc).
// Built with CACHE too (run.sh with PIPE=1 CACHE=1), the pipeline with its caches (rtl/ppc_cache.sv) over a memory of the
// bench's own (a second copy, written only by what the store buffer sends), with random wait states and latency if lat is 1:
// each load's value is checked as it comes as well.
// With irq (the fifth argument) 1, the pipeline's external interrupt line goes up at random clocks (and now and then down
// again untaken); where the RTL takes it, the reference takes it too (run again from the start), and it must have had
// MSR[EE] set there; the longest wait with EE set is printed.
#ifdef CACHE
#include "Vppc_cached.h"
typedef Vppc_cached Vtop;
#elif defined(PIPE)
#include "Vppc_pipe.h"
typedef Vppc_pipe Vtop;
#else
#include "Vppc_core.h"
typedef Vppc_core Vtop;
#endif
#include "verilated.h"
#include "../../tools/ref/ppc602/ppc602.h"
#include <cfenv>
#include <cstdio>
#include <cstring>
#include <deque>
#include <random>
#include <string>
#include <unordered_map>
#include <vector>

static const uint32_t BASE = 0x00010000, NPROG = 2048;

// ---- memory: a byte map over a hash (any address reads something) -------------------------------------------------
struct memmodel
{
	std::unordered_map<uint32_t, uint8_t> m;
	uint64_t seed = 0;
	uint8_t rd(uint32_t a) const
	{
		auto it = m.find(a);
		if (it != m.end()) return it->second;
		uint64_t x = (uint64_t(a >> 2) + 1) * 0x9E3779B97F4A7C15ull ^ seed;
		x ^= x >> 29; x *= 0xBF58476D1CE4E5B9ull; x ^= x >> 32;
		return uint8_t(x >> (8 * (a & 3)));
	}
	uint64_t rdn(uint32_t a, int n) const { uint64_t v = 0; for (int i = 0; i < n; i++) v = (v << 8) | rd(a + i); return v; }
	void wr(uint32_t a, uint8_t d) { m[a] = d; }
	void wrn(uint32_t a, int n, uint64_t v) { for (int i = n - 1; i >= 0; i--) { wr(a + i, uint8_t(v)); v >>= 8; } }
};

struct acc
{
	int w, size; uint32_t a; uint64_t d;
	bool operator!=(const acc &o) const { return w != o.w || size != o.size || a != o.a || d != o.d; }
	std::string str() const { char b[64]; snprintf(b, sizeof b, "%s%d %08X %0*llX", w ? "W" : "R", size, a, 2 * size, (unsigned long long)d); return b; }
};

struct mbus : ppc602_bus
{
	memmodel mm;
	std::vector<acc> log;
	uint64_t r(uint32_t a, int n) { uint64_t d = mm.rdn(a, n); log.push_back({ 0, n, a, d }); return d; }
	void w(uint32_t a, int n, uint64_t d) { mm.wrn(a, n, d); log.push_back({ 1, n, a, d }); }
	uint8_t  read8(uint32_t a) override { return uint8_t(r(a, 1)); }
	uint16_t read16(uint32_t a) override { return uint16_t(r(a, 2)); }
	uint32_t read32(uint32_t a) override { return uint32_t(r(a, 4)); }
	uint64_t read64(uint32_t a) override { return r(a, 8); }
	void write8(uint32_t a, uint8_t d) override { w(a, 1, d); }
	void write16(uint32_t a, uint16_t d) override { w(a, 2, d); }
	void write32(uint32_t a, uint32_t d) override { w(a, 4, d); }
	void write64(uint32_t a, uint64_t d) override { w(a, 8, d); }
	uint32_t fetch(uint32_t a) override { return uint32_t(mm.rdn(a, 4)); }
};

// ---- the instructions --------------------------------------------------------------------------------------------
// SPRs the RTL keeps (rtl/ppc_core.sv spr_idx), and the ones it handles itself
static const int KEPT[] = { 8, 9, 18, 19, 25, 26, 27, 272, 273, 274, 275, 282, 528, 529, 530, 531, 532, 533, 534, 535,
	536, 537, 538, 539, 540, 541, 542, 543, 976, 977, 978, 979, 980, 981, 982, 984, 986, 987, 990, 991, 1008, 1009, 1010,
	1013, 1021, 1022, 346, 1011 };
static const int MT_SPECIAL[] = { 1, 22, 284, 285, 287 };
static const int MF_SPECIAL[] = { 0, 1, 22, 268, 269, 287 };
static bool in(const int *l, size_t n, int v) { for (size_t i = 0; i < n; i++) if (l[i] == v) return true; return false; }
#define IN(l, v) in(l, sizeof(l) / sizeof(l[0]), v)

static const int PRIMARY[] = { 0x03, 0x07, 0x08, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x14, 0x15, 0x17,
	0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d,
	0x2e, 0x2f, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37 };
static const int X13[] = { 0x010, 0x210, 0x000, 0x101, 0x081, 0x0e1, 0x1c1, 0x1a1, 0x021, 0x0c1, 0x121, 0x032, 0x096 };
static const int X1F[] = { 0x004, 0x10a, 0x30a, 0x00a, 0x20a, 0x08a, 0x28a, 0x0ca, 0x2ca, 0x0ea, 0x2ea, 0x028, 0x228,
	0x008, 0x208, 0x088, 0x288, 0x0c8, 0x2c8, 0x0e8, 0x2e8, 0x068, 0x268, 0x000, 0x020, 0x00b, 0x04b, 0x0eb, 0x2eb, 0x1cb,
	0x3cb, 0x1eb, 0x3eb, 0x01c, 0x03c, 0x1dc, 0x1bc, 0x19c, 0x07c, 0x13c, 0x11c, 0x018, 0x218, 0x318, 0x338, 0x01a, 0x3ba,
	0x39a, 0x057, 0x117, 0x157, 0x017, 0x257, 0x316, 0x216, 0x077, 0x137, 0x177, 0x037, 0x277, 0x014, 0x255, 0x215, 0x0d7,
	0x197, 0x097, 0x3d7, 0x2d7, 0x396, 0x296, 0x0f7, 0x1b7, 0x0b7, 0x2f7, 0x096, 0x2d5, 0x295, 0x036, 0x056, 0x0f6, 0x116,
	0x256, 0x356, 0x1d6, 0x236, 0x3d6, 0x132, 0x172, 0x3d2, 0x3f2, 0x3f6, 0x013, 0x053, 0x153, 0x253, 0x293, 0x173, 0x090,
	0x092, 0x1d3, 0x0d2, 0x0f2, 0x200, 0x254, 0x274, 0x217, 0x237, 0x297, 0x2b7 };
// 0x3f X-form: compares, conversions, moves, FPSCR; 0x3f and 0x3b A-form (the low five bits, frC above them)
static const int X3F[] = { 0x000, 0x020, 0x00c, 0x00e, 0x00f, 0x028, 0x048, 0x088, 0x108, 0x046, 0x026, 0x040, 0x247,
	0x2c7, 0x086 };
static const int A3F[] = { 0x15, 0x14, 0x19, 0x12, 0x16, 0x1a, 0x17, 0x1d, 0x1c, 0x1f, 0x1e };
static const int A3B[] = { 0x15, 0x14, 0x19, 0x12, 0x16, 0x18, 0x1d, 0x1c, 0x1f, 0x1e };

static uint32_t spr_of(uint32_t op) { uint32_t f = (op >> 11) & 0x3ff; return ((f >> 5) & 0x1f) | ((f & 0x1f) << 5); }
static uint32_t with_spr(uint32_t op, uint32_t n) { return (op & ~(0x3ffu << 11)) | (((n & 0x1f) << 5 | (n >> 5)) << 11); }

static bool op_ok(uint32_t op)
{
	uint32_t p = op >> 26, x = (op >> 1) & 0x3ff;
	if (p == 0x13) return IN(X13, int(x));
	if (p == 0x3f) return (x & 0x10) ? IN(A3F, int(x & 0x1f)) : IN(X3F, int(x));
	if (p == 0x3b) return IN(A3B, int(x & 0x1f));
	if (p != 0x1f) return IN(PRIMARY, int(p));
	if (!IN(X1F, int(x))) return false;
	if (x == 0x1d3) { int n = spr_of(op); return IN(KEPT, n) || IN(MT_SPECIAL, n); }
	if (x == 0x153) { int n = spr_of(op); return IN(KEPT, n) || IN(MF_SPECIAL, n); }
	if (x == 0x173) { int n = spr_of(op); return n == 268 || n == 269; }
	return true;
}

// an instruction's kind: primary << 10 | extended opcode
static uint32_t key(uint32_t op)
{
	uint32_t p = op >> 26, x = (op >> 1) & 0x3ff;
	if (p == 0x13 || p == 0x1f) return p << 10 | x;
	if (p == 0x3f) return p << 10 | ((x & 0x10) ? (x & 0x1f) : x);
	if (p == 0x3b) return p << 10 | (x & 0x1f);
	return p << 10;
}

static uint32_t pick_spr(std::mt19937_64 &rng, bool mt)
{
	size_t nk = sizeof(KEPT) / sizeof(KEPT[0]);
	if (rng() % 4) return KEPT[rng() % nk];
	return mt ? MT_SPECIAL[rng() % 5] : MF_SPECIAL[rng() % 6];
}

static uint32_t gen_op(std::mt19937_64 &rng, uint32_t pc)
{
	uint32_t op = uint32_t(rng());
#ifdef CACHE
	// often a store just ahead of itself (r28-r31 start in the middle of the program), the line being fetched by then: some
	// across 8 bytes
	if (rng() % 6 == 0)
	{
		static const uint32_t ST[] = { 0x24, 0x26, 0x2c, 0x34, 0x36 };   // stw stb sth stfs stfd
		uint32_t t = pc + 4 * (rng() % 24) + (rng() % 3 == 0 ? rng() % 8 : 0);
		return ST[rng() % 5] << 26 | (uint32_t(rng()) % 32) << 21 | (28 + uint32_t(rng()) % 4) << 16 | ((t - (BASE + 4 * NPROG / 2)) & 0xffff);
	}
#endif
	uint32_t k = rng() % 100;
	auto rel = [&](int bits) {
		// a branch inside the program, word-aligned
		int32_t t = int32_t(BASE + 4 * (rng() % NPROG)) - int32_t(pc);
		return uint32_t(t) & ((1u << bits) - 4);
	};
	if (k < 30)
	{
		uint32_t p = PRIMARY[rng() % (sizeof(PRIMARY) / sizeof(PRIMARY[0]))];
		op = (p << 26) | (op & 0x03ffffff);
		if (p == 0x10) op = (op & ~0xffffu) | rel(16) | (op & 1);
		if (p == 0x12) op = (op & 0xfc000000) | rel(26) | (op & 1);
		if (p == 0x11) op = 0x44000002;
		// small displacements often
		if (p >= 0x20 && rng() % 2) op = (op & ~0xffffu) | (uint16_t(int(rng() % 64) - 32) & 0xffff);
	}
	else if (k < 38)
	{
		op = (0x13u << 26) | (op & 0x03fff801) | (uint32_t(X13[rng() % (sizeof(X13) / sizeof(X13[0]))]) << 1);
	}
	else if (k < 70)
	{
		uint32_t x = X1F[rng() % (sizeof(X1F) / sizeof(X1F[0]))];
		op = (0x1fu << 26) | (op & 0x03fff801) | (x << 1);
		if (x == 0x1d3) op = with_spr(op, pick_spr(rng, true));
		if (x == 0x153) op = with_spr(op, pick_spr(rng, false));
		if (x == 0x173) op = with_spr(op, 268 + rng() % 2);
	}
	else if (k < 80)
		op = (0x3fu << 26) | (op & 0x03fff801) | (uint32_t(X3F[rng() % (sizeof(X3F) / sizeof(X3F[0]))]) << 1);
	else if (k < 90)
		op = (0x3fu << 26) | (op & 0x03ffffc1) | (uint32_t(A3F[rng() % (sizeof(A3F) / sizeof(A3F[0]))]) << 1);
	else
		op = (0x3bu << 26) | (op & 0x03ffffc1) | (uint32_t(A3B[rng() % (sizeof(A3B) / sizeof(A3B[0]))]) << 1);
	return op;
}

// a float register's starting value: mostly ordinary numbers, with the edges the float unit has to get right (denormals,
// the single range's ends, NaNs, infinities, zeros, integers near the 32-bit limits, near-equal pairs)
static uint64_t gen_fp(std::mt19937_64 &rng, const uint64_t *prev, int n)
{
	uint64_t s = uint64_t(rng() % 2) << 63, m = rng() & 0x000fffffffffffffull;
	auto ex = [&](int e) { return s | (uint64_t(e & 0x7ff) << 52) | m; };
	switch (rng() % 16)
	{
		case 0: return rng();
		case 1: return ex(0);                                                            // denormal
		case 2: return ex(1 + rng() % 60);                                               // tiny
		case 3: return ex(2046 - rng() % 60);                                            // huge
		case 4: return ex(1023 - 126 - 30 + rng() % 40);                                 // the single denormals
		case 5: return ex(1023 + 120 + rng() % 16);                                      // the single's top
		case 6: return s | (rng() % 2 ? 0x7ff0000000000000ull : 0);                      // infinity, zero
		case 7: return s | 0x7ff0000000000000ull | (m ? m : 1);                          // NaN
		case 8: return ex(1023 + 28 + rng() % 6) & ~((1ull << (rng() % 40)) - 1);        // near 2^31
		case 9: return ex(1023 - 2 + rng() % 8) & ~((1ull << (40 + rng() % 12)) - 1);    // halves, quarters
		case 10: if (n) return prev[rng() % n] ^ (rng() % 2 ? 1ull << (rng() % 52) : uint64_t(rng() % 4)); return rng(); // near another
		case 11: return ex(1023 + int(rng() % 16) - 8) & ~0x1fffffffull;                // a single
		default: return ex(1023 + int(rng() % 64) - 32);                                 // ordinary
	}
}

// ---- state ---------------------------------------------------------------------------------------------------------
struct state
{
	uint32_t pc, r[32], cr, lr, ctr, xer, msr, srr0, srr1, fpscr;
	uint64_t f[32];
	int ex;
};

static state ref_state(const ppc602 &m, int ex)
{
	state s;
	s.pc = m.pc;
	memcpy(s.r, m.r, sizeof s.r);
	memcpy(s.f, m.f, sizeof s.f);
	s.cr = m.get_cr(); s.lr = m.spr[8]; s.ctr = m.spr[9]; s.xer = m.get_xer(); s.msr = m.msr;
	s.srr0 = m.spr[26]; s.srr1 = m.spr[27]; s.fpscr = m.fpscr; s.ex = ex;
	return s;
}

static state rtl_state(Vtop &t)
{
	state s;
	s.pc = t.pc_o;
	for (int i = 0; i < 32; i++) { s.r[i] = t.gpr_o[i]; s.f[i] = uint64_t(t.fpr_o[2 * i]) | (uint64_t(t.fpr_o[2 * i + 1]) << 32); }
	s.cr = t.cr_o; s.lr = t.lr_o; s.ctr = t.ctr_o; s.xer = t.xer_o; s.msr = t.msr_o; s.srr0 = t.srr0_o; s.srr1 = t.srr1_o;
	s.fpscr = t.fpscr_o; s.ex = t.exc_o;
	return s;
}

static std::string diff(const state &a, const state &b)
{
	std::string o;
	char buf[96];
	auto d32 = [&](const char *n, uint32_t x, uint32_t y) { if (x != y) { snprintf(buf, sizeof buf, "  %-5s ref %08X rtl %08X\n", n, x, y); o += buf; } };
	d32("pc", a.pc, b.pc);
	for (int i = 0; i < 32; i++) { char n[8]; snprintf(n, sizeof n, "r%d", i); d32(n, a.r[i], b.r[i]); }
	for (int i = 0; i < 32; i++)
		if (a.f[i] != b.f[i]) { snprintf(buf, sizeof buf, "  f%-4d ref %016llX rtl %016llX\n", i, (unsigned long long)a.f[i], (unsigned long long)b.f[i]); o += buf; }
	d32("cr", a.cr, b.cr); d32("lr", a.lr, b.lr); d32("ctr", a.ctr, b.ctr); d32("xer", a.xer, b.xer); d32("msr", a.msr, b.msr);
	d32("srr0", a.srr0, b.srr0); d32("srr1", a.srr1, b.srr1); d32("fpscr", a.fpscr, b.fpscr); d32("exc", a.ex, b.ex);
	return o;
}

static void clk(Vtop &t) { t.clk = 0; t.eval(); t.clk = 1; t.eval(); }

#ifdef PIPE
// a request out to a side of the pipeline's memory, answered after a delay (1: the next clock)
struct port
{
	bool out = false;
	int wait = 0;
	uint64_t data = 0;
};
#endif

int main(int argc, char **argv)
{
	long cases = argc > 1 ? atol(argv[1]) : 2000;
	int steps = argc > 2 ? atoi(argv[2]) : 300;
	uint64_t seed = argc > 3 ? strtoull(argv[3], 0, 0) : 1;
	int lat = argc > 4 ? atoi(argv[4]) : 0;
	int irq = argc > 5 ? atoi(argv[5]) : 0;
	(void)lat; (void)irq;
	std::mt19937_64 rng(seed);
	Vtop top;
	long bad = 0, total_insn = 0, total_acc = 0, total_exc = 0, total_cyc = 0;
	long irq_n = 0, irq_wmax = 0;
	std::unordered_map<uint32_t, long> hits;

	for (long c = 0; c < cases && bad < 5; c++)
	{
		// ---- the case: memory, program, state ----
		mbus mb;
		mb.mm.seed = rng();
		for (uint32_t k = 0; k < NPROG; k++) mb.mm.wrn(BASE + 4 * k, 4, gen_op(rng, BASE + 4 * k));
		ppc602 ref(mb);
		ref.reset();
		for (int i = 0; i < 32; i++)
		{
			ref.r[i] = uint32_t(rng());
			switch (rng() % 4)
			{
				case 0: ref.r[i] = rng() % 64; break;                                        // small: counts, shifts, offsets
				case 1: ref.r[i] = 0x00100000 + (rng() % 0x1000) * 4 + (rng() % 8 == 0 ? rng() % 4 : 0); break; // data
				default: break;
			}
			ref.f[i] = gen_fp(rng, ref.f, i);
		}
#ifdef PIPE
		// the pipeline's FPRs are the 602's singles (rtl/ppc_fps.sv), and it takes the FP-unavailable exception
		ref.sp = true; ref.fpu_exc = true; ref.sp_canon();
#endif
		for (int i = 0; i < 4; i++) ref.tgpr[i] = uint32_t(rng());
		ref.set_cr(uint32_t(rng()));
		ref.set_xer(uint32_t(rng()) & 0xe000007f);
		if (rng() % 2) ref.set_xer(ref.get_xer() & ~0x7fu & 0xffffff00 | (rng() % 24));
		for (int i = 0; i < 16; i++) ref.sr[i] = uint32_t(rng()) & (rng() % 2 ? 0x00ffffff : 0xffffffff);
		for (int n : KEPT) ref.spr[n] = uint32_t(rng());
		ref.spr[8] = BASE + 4 * (rng() % NPROG);                                                 // LR, CTR, SRR0: in the program
		ref.spr[9] = rng() % 2 ? BASE + 4 * (rng() % NPROG) : rng() % 16;
		ref.spr[26] = BASE + 4 * (rng() % NPROG);
		ref.spr[986] = BASE;                                                                      // IBR
		ref.spr[1008] = (uint32_t(rng()) & ~0x80u) | (rng() % 2 ? 0x80 : 0);                     // HID0: protection-only?
		// BATs: often one mapping the program (and the data) to itself, the rest random
		for (int b = 0; b < 2; b++)
		{
			int base = b ? 536 : 528;
			if (rng() % 4)
			{
				int n = rng() % 4;
				ref.spr[base + 2 * n] = 0x00000000 | (0x7ff << 2) | 3;                            // 256 MB at 0, Vs Vp
				ref.spr[base + 2 * n + 1] = 0x00000000 | (rng() % 4 ? 2 : rng() % 4);
			}
		}
		ref.decrementer = uint32_t(rng());
		ref.timebase = rng();
		// MSR: big-endian (the bench doesn't model LE), IP mostly clear so the vectors are at IBR
		uint32_t msr = uint32_t(rng()) & (0x00c0ffff & ~0x00010001u);
		msr &= ~0x00020000u;
		if (rng() % 8) msr &= ~0x40u;
		if (rng() % 2) msr &= ~0x30u;
#ifdef PIPE
		if (rng() % 4) msr |= 0x2000u;  // FP mostly on, so the float ops run (off, they take the FP-unavailable exception)
#endif
		ref.msr = msr;
		// the rounding mode: the model runs on the host's
		ref.fpscr = uint32_t(rng() % 4);
		{ static const int modes[4] = { FE_TONEAREST, FE_TOWARDZERO, FE_UPWARD, FE_DOWNWARD }; fesetround(modes[ref.fpscr]); }
		ref.pc = BASE + 4 * (rng() % NPROG);
		// sometimes registers just past the start, so stores (small displacements) change instructions already fetched
		if (rng() % 4 == 0) for (int j = 0; j < 2; j++) ref.r[rng() % 32] = ref.pc + 4 * (rng() % 8);
#ifdef CACHE
		if (rng() % 8) for (int j = 28; j < 32; j++) ref.r[j] = BASE + 4 * NPROG / 2;
#endif
		state init = ref_state(ref, 0);
		ppc602 m0(ref);   // the start, for the RTL

		// ---- the reference ----
		mbus rb = mb;     // the RTL's copy of the memory
		mbus mb0 = mb;    // (and the reference's start, for a run again)
		std::vector<state> cp;
		std::vector<size_t> nacc;
		std::vector<uint32_t> pcs, ops;
		std::vector<size_t> irq_at;     // the steps the RTL took an external interrupt before
		auto run_ref = [&](ppc602 &r) {
			cp.clear(); nacc.clear(); pcs.clear(); ops.clear();
			{ static const int modes[4] = { FE_TONEAREST, FE_TOWARDZERO, FE_UPWARD, FE_DOWNWARD }; fesetround(modes[r.fpscr & 3]); }
			size_t ii = 0;
			for (int s = 0; s < steps; s++)
			{
				uint32_t pc = r.pc;
				if (ii < irq_at.size() && irq_at[ii] == cp.size())
				{
					ii++;
					r.interrupt(ppc602::EX_EI);
					pcs.push_back(pc); ops.push_back(0);
					cp.push_back(ref_state(r, ppc602::EX_EI));
					nacc.push_back(mb.log.size());
					continue;
				}
				if (pc < BASE || pc >= BASE + 4 * NPROG || (r.msr & 0x00010001)) break;
				// the instruction (through the IBATs) must be one the bench covers: the step is dropped if not
				size_t nlog = mb.log.size();
				int ex = r.step();
				if (ex != ppc602::EX_ISI && ex != ppc602::EX_ITLBMISS && !op_ok(r.last_op)) { mb.log.resize(nlog); break; }
				pcs.push_back(pc);
				ops.push_back(ex == ppc602::EX_ISI || ex == ppc602::EX_ITLBMISS ? 0 : r.last_op);
				cp.push_back(ref_state(r, ex));
				nacc.push_back(mb.log.size());
			}
		};
		run_ref(ref);
		if (cp.empty()) continue;

		// ---- the RTL ----
		top.int_ext = 0; top.dec_tick = 0; top.tb_tick = 0; top.dbg_hold = 0; top.dbg_int = 0; top.dbg_we = 0;
		long irq_wait = irq ? 1 + rng() % 64 : 0, irq_w = 0;   // clocks until the line goes up; clocks up with EE set
#ifdef PIPE
#ifdef CACHE
		top.rst = 1; top.mem_busy = 0; top.mem_ready = 0;
		struct rbeat { uint64_t d; int wait; };
		std::deque<rbeat> rq;
		memmodel bm = rb.mm;            // what's behind the caches
		int busy = !lat ? 0 : rng() % 3 ? 25 : 90;    // (very busy: the store buffer fills)
		struct due { bool ld; uint64_t v; };
		std::deque<due> dq;             // the accesses out, answered in order (a load's value to check)
		auto answer = [&]() {
			if (dq.empty()) { printf("case %ld: an answer with no access out\n", c); return false; }
			due e = dq.front();
			dq.pop_front();
			if (e.ld && top.d_rdata != e.v)
			{
				printf("case %ld: a load read %016llX, not %016llX\n", c, (unsigned long long)top.d_rdata, (unsigned long long)e.v);
				return false;
			}
			return true;
		};
		// a clock of the memory: the answer, then after eval what's asked at the edge
		auto mem_in = [&]() {
			top.mem_busy = int(rng() % 100) < busy;
			// the others' writes: lines the core is using, at random (the value behind them doesn't change, or the model would
			// differ; tb_coh has what happens when it does)
			top.sn_v = lat && rng() % 8 == 0;
			top.sn_a = (rng() % 2 ? top.if_pa : top.d_pa) >> 5;
			top.mem_ready = !rq.empty() && rq.front().wait <= 0;
			if (top.mem_ready) top.mem_dout = rq.front().d;
		};
		auto mem_out = [&]() {
			if (top.mem_ready) rq.pop_front();
			for (auto &r : rq) r.wait--;
			if (top.mem_busy || !(top.mem_rd || top.mem_we)) return;
			uint32_t a = uint32_t(top.mem_a) << 3;
			if (top.mem_we)
			{
				for (int k = 0; k < 8; k++)
					if (top.mem_be >> k & 1) bm.wr(a + k, uint8_t(top.mem_wd >> 8 * k));
				return;
			}
			int wait = lat ? 2 + int(rng() % 12) : 1;
			for (int b = 0; b < int(top.mem_burst); b++)
			{
				uint64_t v = 0;
				for (int k = 7; k >= 0; k--) v = v << 8 | bm.rd(a + 8 * b + k);
				rq.push_back({ v, wait + b });
			}
		};
#else
		top.rst = 1; top.if_rdy = 1; top.if_valid = 0; top.d_rdy = 1; top.d_valid = 0;
		port ip;
		std::deque<port> dq;            // the accesses out (two at most), answered in order
#endif
		bool aph = false;               // the access taken last clock: its address clock now
		// a delay: mostly the next clock
		auto delay = [&]() { if (!lat) return 1; int k = rng() % 16; return k < 9 ? 1 : k < 14 ? 2 + int(rng() % 3) : 5 + int(rng() % 8); };
#else
		top.rst = 1; top.bus_ack = 0;
#endif
		clk(top);
		auto load = [&](int idx, uint64_t v) { top.dbg_we = 1; top.dbg_idx = idx; top.dbg_val = v; clk(top); };
		for (int i = 0; i < 32; i++) load(i, m0.r[i]);
		for (int i = 0; i < 32; i++) load(32 + i, m0.f[i]);
		load(64, m0.pc); load(65, m0.get_cr()); load(66, m0.get_xer()); load(67, m0.msr); load(68, m0.fpscr);
		load(69, m0.decrementer); load(70, uint32_t(m0.timebase)); load(71, uint32_t(m0.timebase >> 32));
		for (int i = 0; i < 4; i++) load(72 + i, m0.tgpr[i]);
		for (int i = 0; i < 16; i++) load(80 + i, m0.sr[i]);
		for (int n : KEPT) load(1024 + n, m0.spr[n]);
		top.dbg_we = 0;
		top.rst = 0;

		memmodel &rm = rb.mm;
		std::vector<acc> rlog;
		size_t ci = 0;
		bool fail = false;
		long cyc;
		for (cyc = 0; cyc < 2000000 && ci < cp.size() && !fail; cyc++)
		{
			top.clk = 0; top.eval();
#ifdef PIPE
			// the external interrupt line: up after a while, now and then down again untaken
			if (irq)
			{
				if (!top.int_ext) { if (--irq_wait <= 0) { top.int_ext = 1; irq_w = 0; } }
				else if (rng() % 1024 == 0) { top.int_ext = 0; irq_wait = 1 + rng() % 64; }
				else if (top.msr_o & 0x8000) irq_w++;
			}
			// the access in its address clock; the answers this clock (the data side's from that clock on); the requests
			// taken at its edge
#ifdef CACHE
			mem_in();
			top.eval();
			if (aph && !top.d_kill)
			{
				int n = top.d_size;
				uint32_t a = top.d_pa;
				if (top.d_we)
				{
					uint64_t d = top.d_wdata & (n == 8 ? ~0ull : (1ull << (8 * n)) - 1);
					rm.wrn(a, n, d);
					rlog.push_back({ 1, n, a, d });
					dq.push_back({ false, 0 });
				}
				else
				{
					uint64_t v = rm.rdn(a, n);
					rlog.push_back({ 0, n, a, v });
					dq.push_back({ true, v });
				}
				if (rlog.size() == nacc.back() && nacc.back() > (cp.size() > 1 ? nacc[cp.size() - 2] : 0)) top.dbg_hold = 1;
				top.eval();
			}
			aph = false;
			if (top.d_valid && !answer()) { fail = true; break; }
			mem_out();
			if (top.d_req && top.d_rdy)
			{
				if (dq.size() >= 2) { printf("case %ld: a third access out\n", c); fail = true; break; }
				aph = true;
			}
#else
			top.if_valid = ip.out && ip.wait == 0;
			if (top.if_valid) top.if_data = uint32_t(rm.rdn(top.if_pa, 4));
			top.d_valid = 0;
			top.eval();
			if (aph && !top.d_kill)
			{
				int n = top.d_size;
				uint32_t a = top.d_pa;
				port p;
				if (top.d_we)
				{
					uint64_t d = top.d_wdata & (n == 8 ? ~0ull : (1ull << (8 * n)) - 1);
					rm.wrn(a, n, d);
					rlog.push_back({ 1, n, a, d });
				}
				else
				{
					p.data = rm.rdn(a, n);
					rlog.push_back({ 0, n, a, p.data });
				}
				p.out = true; p.wait = delay() - 1;
				dq.push_back(p);
				// the last instruction's access (it retires at this edge): X takes nothing more
				if (rlog.size() == nacc.back() && nacc.back() > (cp.size() > 1 ? nacc[cp.size() - 2] : 0)) top.dbg_hold = 1;
			}
			aph = false;
			top.d_valid = !dq.empty() && dq.front().wait <= 0;
			if (top.d_valid) top.d_rdata = dq.front().data;
			top.eval();
			top.if_rdy = !lat || rng() % 8;
			top.d_rdy = !lat || rng() % 8;
			top.eval();
			if (ip.out && (top.if_valid || top.if_kill)) ip.out = false;
			else if (ip.out) ip.wait--;
			if (top.d_valid) dq.pop_front();
			for (port &p : dq) p.wait--;
			if (top.if_req && top.if_rdy)
			{
				if (ip.out) { printf("case %ld: a fetch while one is out\n", c); fail = true; break; }
				ip.out = true; ip.wait = delay() - 1;
			}
			if (top.d_req && top.d_rdy)
			{
				if (dq.size() >= 2) { printf("case %ld: a third access out\n", c); fail = true; break; }
				aph = true;
			}
#endif
#else
			top.bus_ack = top.bus_req;
			if (top.bus_req)
			{
				int n = top.bus_size;
				uint32_t a = top.bus_addr;
				if (top.bus_we)
				{
					uint64_t d = top.bus_wdata & (n == 8 ? ~0ull : (1ull << (8 * n)) - 1);
					rm.wrn(a, n, d);
					rlog.push_back({ 1, n, a, d });
				}
				else
				{
					top.bus_rdata = rm.rdn(a, n);
					if (!top.bus_fetch) rlog.push_back({ 0, n, a, top.bus_rdata });
				}
			}
#endif
			top.eval();
			top.clk = 1; top.eval();
			if (!top.retire) continue;
			size_t ci0 = ci;                // the first retired this clock
#ifdef PIPE
			if (top.retire2)
			{
				if (ci + 1 >= cp.size() || top.ipc0_o != pcs[ci])
				{
					printf("case %ld step %zu: %08X %08X retired with %s (RTL ran %08X %08X)\n", c, ci, pcs[ci], ops[ci],
						ci + 1 >= cp.size() ? "an instruction after the last" : "the next", uint32_t(top.ipc0_o), uint32_t(top.iop0_o));
					fail = true;
					break;
				}
				if (cp[ci].ex) total_exc++;
				if (ops[ci]) hits[key(ops[ci])]++;
				ci++;
			}
			// the RTL took the external interrupt before this step: so does the reference (run again), with EE set
			if (top.exc_o == ppc602::EX_EI && ci < cp.size() && cp[ci].ex != ppc602::EX_EI)
			{
				if (!((ci ? cp[ci - 1] : init).msr & 0x8000))
				{
					printf("case %ld step %zu: an external interrupt with MSR[EE] clear, before %08X %08X\n", c, ci, pcs[ci], ops[ci]);
					fail = true;
					break;
				}
				irq_at.push_back(ci);
				mb = mb0;
				ppc602 r2(m0);
				run_ref(r2);
				irq_n++;
				irq_wmax = std::max(irq_wmax, irq_w);
				top.int_ext = 0;
				irq_wait = 1 + rng() % 64;
			}
#endif
			state rs = rtl_state(top), &es = cp[ci];
#ifdef PIPE
			// what an older load or float op hasn't written yet is checked later
			for (int i = 0; i < 32; i++)
			{
				if ((top.gpr_pend_o >> i) & 1) rs.r[i] = es.r[i];
				if ((top.fpr_pend_o >> i) & 1) rs.f[i] = es.f[i];
			}
			// after the last, stop and let them land
			if (ci + 1 == cp.size()) top.dbg_hold = 1;
#endif
			std::string d = diff(es, rs);
			size_t na = nacc[ci], k0 = ci0 ? nacc[ci0 - 1] : 0;
			bool acc_ok = rlog.size() == na;
			for (size_t k = k0; k < na && k < rlog.size() && acc_ok; k++) if (rlog[k] != mb.log[k]) acc_ok = false;
			if (!d.empty() || !acc_ok || top.ipc_o != pcs[ci])
			{
				printf("case %ld step %zu: %08X %08X differs (RTL ran %08X %08X)\n", c, ci, pcs[ci], ops[ci], uint32_t(top.ipc_o),
					uint32_t(top.iop_o));
				for (size_t k = ci > 6 ? ci - 6 : 0; k < ci; k++) printf("    before: %08X %08X\n", pcs[k], ops[k]);
				for (size_t k = ci + 1; k < ci + 4 && k < cp.size(); k++) printf("    after:  %08X %08X\n", pcs[k], ops[k]);
				const state &pv = ci ? cp[ci - 1] : init;
				printf("  before: cr %08X xer %08X msr %08X lr %08X ctr %08X fpscr %08X\n", pv.cr, pv.xer, pv.msr, pv.lr, pv.ctr,
					pv.fpscr);
				uint32_t o = ops[ci];
				if ((o >> 26) == 0x3b || (o >> 26) == 0x3f)
					printf("  before: fA %016llX fB %016llX fC %016llX\n", (unsigned long long)pv.f[(o >> 16) & 31],
						(unsigned long long)pv.f[(o >> 11) & 31], (unsigned long long)pv.f[(o >> 6) & 31]);
				printf("%s", d.c_str());
				// (FHIST set: how the model came to each FPR that differs; FHIST=2: every FPR at the start too)
				if (const char *fh = getenv("FHIST"))
					for (int i = 0; i < 32; i++)
					{
						if (fh[0] == '2')
							printf("  f%d at the start %016llX%s\n", i, (unsigned long long)init.f[i], m0.fint >> i & 1 ? " (an integer)" : "");
						if (es.f[i] == rs.f[i]) continue;
						uint64_t v = init.f[i];
						printf("  f%d from %016llX:", i, (unsigned long long)v);
						for (size_t k = 0; k <= ci; k++)
							if (cp[k].f[i] != v) { v = cp[k].f[i]; printf(" %08X %08X -> %016llX;", pcs[k], ops[k], (unsigned long long)v); }
						printf("\n");
					}
				printf("  accesses ref:");
				for (size_t k = k0; k < na; k++) printf(" %s", mb.log[k].str().c_str());
				printf("\n  accesses rtl:");
				for (size_t k = k0; k < rlog.size(); k++) printf(" %s", rlog[k].str().c_str());
				printf("\n");
				fail = true;
				break;
			}
			if (es.ex) total_exc++;
			if (ops[ci]) hits[key(ops[ci])]++;
			ci++;
		}
		if (!fail && ci < cp.size())
		{
			printf("case %ld: RTL stopped after %zu of %zu instructions; next %08X %08X\n", c, ci, cp.size(), pcs[ci], ops[ci]);
			printf("  after %ld clocks: pc %08X msr %08X xer %08X; int_ext %d hold %d; if_req %d d_req %d\n", cyc, uint32_t(top.pc_o),
				uint32_t(top.msr_o), uint32_t(top.xer_o), int(top.int_ext), int(top.dbg_hold), int(top.if_req), int(top.d_req));
			for (size_t k = ci > 6 ? ci - 6 : 0; k < ci; k++) printf("    before: %08X %08X%s\n", pcs[k], ops[k], cp[k].ex ? " (exception)" : "");
			fail = true;
		}
		total_cyc += cyc;
#ifdef PIPE
		// drained: everything (an access the cache holds waits out a sweep of its tags, a clock a line)
		top.int_ext = 0;
		if (!fail)
		{
			const int DRAIN = 4000;
			int k;
			for (k = 0; k < DRAIN && !top.dbg_idle; k++)
			{
				top.clk = 0; top.eval();
#ifdef CACHE
				mem_in();
				top.eval();
				if (top.d_valid && !answer()) { fail = true; break; }
				mem_out();
				if (top.d_req) { printf("case %ld: ran on after the last instruction\n", c); fail = true; break; }
#else
				top.if_valid = ip.out && ip.wait == 0;
				if (top.if_valid) top.if_data = uint32_t(rm.rdn(top.if_pa, 4));
				top.d_valid = !dq.empty() && dq.front().wait <= 0;
				if (top.d_valid) top.d_rdata = dq.front().data;
				top.if_rdy = 1; top.d_rdy = 1;
				top.eval();
				if (ip.out && (top.if_valid || top.if_kill)) ip.out = false; else if (ip.out) ip.wait--;
				if (top.d_valid) dq.pop_front();
				for (port &p : dq) p.wait--;
				if (top.if_req) { ip.out = true; ip.wait = 0; }
				if (top.d_req) { printf("case %ld: ran on after the last instruction\n", c); fail = true; break; }
#endif
				top.clk = 1; top.eval();
				if (top.retire) { printf("case %ld: ran on after the last instruction\n", c); fail = true; break; }
			}
			state rs = rtl_state(top), es = cp.back();
			rs.ex = es.ex;
			std::string d = diff(es, rs);
			if (!fail && (k == DRAIN || !d.empty()))
			{
				printf("case %ld: after the last instruction (%08X %08X)%s\n%s", c, pcs.back(), ops.back(),
					k == DRAIN ? ", not idle" : "", d.c_str());
				fail = true;
			}
		}
#endif
		if (fail) bad++;
		total_insn += ci;
		total_acc += mb.log.size();
	}
	// every instruction the generator makes must have run
	std::vector<uint32_t> keys;
	for (int p : PRIMARY) keys.push_back(p << 10);
	for (int x : X13) keys.push_back(0x13 << 10 | x);
	for (int x : X1F) keys.push_back(0x1f << 10 | x);
	for (int x : X3F) keys.push_back(0x3f << 10 | x);
	for (int x : A3F) keys.push_back(0x3f << 10 | x);
	for (int x : A3B) keys.push_back(0x3b << 10 | x);
	int unrun = 0;
	for (uint32_t k : keys) if (!hits[k]) { printf("never ran: %02X %03X\n", k >> 10, k & 0x3ff); unrun++; }
	if (cases < 1000) unrun = 0;   // too few cases to expect them all
	if (irq) printf("%ld external interrupts taken, the longest wait with EE set %ld clocks\n", irq_n, irq_wmax);
	printf("%s: %ld cases, %ld instructions, %ld accesses, %ld exceptions; %.2f clocks an instruction\n", bad || unrun ? "FAIL" : "PASS",
		cases, total_insn, total_acc, total_exc, total_insn ? double(total_cyc) / total_insn : 0.0);
	return bad || unrun ? 1 : 0;
}
