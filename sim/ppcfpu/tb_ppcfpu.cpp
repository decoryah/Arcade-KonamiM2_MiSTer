// tb_ppcfpu [count] [seed]: the RTL float unit (rtl/ppc_fpu.sv) against the reference model (tools/ref/ppc602) on random
// operands, every operation in every rounding mode. The model runs each as its instruction (fadd f4,f1,f2 and the like;
// stfs for the round to single, lfs for single to double), so this checks the unit against the same code the core
// bench and the MAME replay check. Built with FPP, the float pipeline (rtl/ppc_fpp.sv) instead: its operations issued
// back to back (as ok lets them), each result checked by its destination.
#ifdef FPP
#include "Vppc_fpp.h"
#else
#include "Vppc_fpu.h"
#endif
#include "verilated.h"
#include "../../tools/ref/ppc602/ppc602.h"
#include <cfenv>
#include <cstdio>
#include <cstring>
#include <random>

struct onebus : ppc602_bus
{
	uint32_t op = 0, rd32 = 0, wr32 = 0;
	uint8_t  read8(uint32_t) override { return 0; }
	uint16_t read16(uint32_t) override { return 0; }
	uint32_t read32(uint32_t) override { return rd32; }
	uint64_t read64(uint32_t) override { return 0; }
	void write8(uint32_t, uint8_t) override {}
	void write16(uint32_t, uint16_t) override {}
	void write32(uint32_t, uint32_t d) override { wr32 = d; }
	void write64(uint32_t, uint64_t) override {}
	uint32_t fetch(uint32_t) override { return op; }
};

// the unit's operations (rtl/ppc_fpu_pkg.sv) and the instruction that runs each on the model: f4 = f1 op f2 / f1 * f3 ...
enum { F_ADD, F_SUB, F_MUL, F_DIV, F_SQRT, F_RSQRTE, F_MADD, F_MSUB, F_NMADD, F_NMSUB, F_ADDS, F_SUBS, F_MULS, F_DIVS,
	F_SQRTS, F_RES, F_MADDS, F_MSUBS, F_NMADDS, F_NMSUBS, F_RSP, F_CTIW, F_CTIWZ, F_CMP, F_D2S, F_S2D, F_N };
static const char *NAME[F_N] = { "fadd", "fsub", "fmul", "fdiv", "fsqrt", "frsqrte", "fmadd", "fmsub", "fnmadd", "fnmsub",
	"fadds", "fsubs", "fmuls", "fdivs", "fsqrts", "fres", "fmadds", "fmsubs", "fnmadds", "fnmsubs", "frsp", "fctiw",
	"fctiwz", "fcmpu", "stfs", "lfs" };
static uint32_t aform(uint32_t p, uint32_t xo) { return (p << 26) | (4 << 21) | (1 << 16) | (2 << 11) | (3 << 6) | (xo << 1); }
static uint32_t xform(uint32_t xo) { return (0x3fu << 26) | (4 << 21) | (1 << 16) | (2 << 11) | (xo << 1); }
static uint32_t insn(int f)
{
	static const uint8_t A[] = { 0x15, 0x14, 0x19, 0x12, 0x16, 0x1a, 0x1d, 0x1c, 0x1f, 0x1e };
	static const uint8_t S[] = { 0x15, 0x14, 0x19, 0x12, 0x16, 0x18, 0x1d, 0x1c, 0x1f, 0x1e };
	if (f <= F_NMSUB) return aform(0x3f, A[f]);
	if (f <= F_NMSUBS) return aform(0x3b, S[f - F_ADDS]);
	switch (f)
	{
		case F_RSP: return xform(0x00c);
		case F_CTIW: return xform(0x00e);
		case F_CTIWZ: return xform(0x00f);
		case F_CMP: return xform(0x000);                                 // fcmpu cr1,f1,f2
		case F_D2S: return (0x34u << 26) | (1 << 21);                    // stfs f1,0(0)
		default: return (0x30u << 26) | (4 << 21);                       // lfs f4,0(0)
	}
}

static uint64_t gen(std::mt19937_64 &rng, uint64_t other)
{
	uint64_t s = uint64_t(rng() % 2) << 63, m = rng() & 0x000fffffffffffffull;
	auto ex = [&](int e) { return s | (uint64_t(e & 0x7ff) << 52) | m; };
	switch (rng() % 20)
	{
		case 0: return rng();
		case 1: return ex(0);
		case 2: return ex(1 + rng() % 60);
		case 3: return ex(2046 - rng() % 60);
		case 4: return ex(1023 - 126 - 30 + rng() % 40);
		case 5: return ex(1023 + 120 + rng() % 16);
		case 6: return s | (rng() % 2 ? 0x7ff0000000000000ull : 0);
		case 7: return s | 0x7ff0000000000000ull | (m ? m : 1);
		case 8: return ex(1023 + 28 + rng() % 6) & ~((1ull << (rng() % 40)) - 1);
		case 9: return ex(1023 - 2 + rng() % 8) & ~((1ull << (40 + rng() % 12)) - 1);
		case 10: return other ^ (rng() % 2 ? 1ull << (rng() % 52) : uint64_t(rng() % 4));      // near the other operand
		case 11: case 12: return ex(1023 + int(rng() % 16) - 8) & ~0x1fffffffull;           // a single
		case 13: return ex(1023 + int(rng() % 16) - 8) & ~((1ull << (rng() % 52)) - 1);       // few mantissa bits
		case 14: return (other ^ (s & ~0ull)) & ~uint64_t(rng() % 8);                          // -other, near
		default: return ex(1023 + int(rng() % 64) - 32);
	}
}

// the model's result: the instruction at 0, the operands in f1-f3, the mode in FPSCR and on the host
static void model(ppc602 &m, onebus &bus, int f, uint32_t rn, uint64_t a, uint64_t b, uint64_t c, uint64_t &want, uint32_t &wcr)
{
	static const int modes[4] = { FE_TONEAREST, FE_TOWARDZERO, FE_UPWARD, FE_DOWNWARD };
	m.pc = 0; m.msr = 0; m.fpscr = rn; fesetround(modes[rn]);
	m.f[1] = a; m.f[2] = b; m.f[3] = c; m.f[4] = 0; m.cr[1] = 0;
	bus.op = insn(f); bus.rd32 = uint32_t(a);
	m.step();
	want = f == F_D2S ? bus.wr32 : m.f[4];
	wcr = m.cr[1];                                   // fcmpu: crfD 1 (the 4 in rD)
}

// a single's value as a double: any single (denormals, NaNs and infinities too), or one near 1
static uint64_t gen_s(std::mt19937_64 &rng)
{
	uint32_t u = uint32_t(rng());
	if (rng() % 2) u = (u & 0x807fffffu) | (uint32_t(127 + int(rng() % 40) - 20) << 23);
	float fv;
	memcpy(&fv, &u, 4);
	double d = fv;
	uint64_t r;
	memcpy(&r, &d, 8);
	return r;
}

// what the fast multiply takes (rtl/ppc_fpu_pkg.sv sgl): a zero, NaN or infinity, or 24 significand bits, exponent >= -511
static bool sgl(uint64_t v)
{
	return (v << 1) == 0 || ((v >> 52) & 0x7ff) == 0x7ff || ((v & 0x1fffffffull) == 0 && ((v >> 61) & 3) != 0);
}

static void operands(std::mt19937_64 &rng, int f, uint64_t &a, uint64_t &b, uint64_t &c)
{
	a = gen(rng, 0); b = gen(rng, a); c = gen(rng, rng() % 2 ? a : b);
	if (rng() % 3 == 0) { a = gen_s(rng); c = gen_s(rng); if (rng() % 2) b = gen_s(rng); }
	if (f == F_S2D) a = uint32_t(rng() % 4 ? rng() : gen(rng, 0) >> 32);
}

int main(int argc, char **argv)
{
	long count = argc > 1 ? atol(argv[1]) : 2000000;
	uint64_t seed = argc > 2 ? strtoull(argv[2], 0, 0) : 1;
	std::mt19937_64 rng(seed);
	onebus bus;
	ppc602 m(bus);
	m.reset();
#ifndef FPP
	m.single_ftz = false;   // the iterative unit's single ops keep MAME's single denormals (the pipeline's don't)
#endif
	long bad = 0, n[F_N] = {};
#ifdef FPP
	// the pipeline's operations
	static const int OPS[] = { F_ADD, F_SUB, F_MUL, F_MADD, F_MSUB, F_NMADD, F_NMSUB, F_ADDS, F_SUBS, F_MULS, F_MADDS,
		F_MSUBS, F_NMADDS, F_NMSUBS, F_RSP, F_CTIW, F_CTIWZ };
	const int NOPS = sizeof OPS / sizeof OPS[0];
	struct slot { bool busy; int f; uint32_t rn; uint64_t a, b, c, want; long at; } sl[32] = {};
	Vppc_fpp u;
	u.rst = 1; u.issue = 0;
	u.clk = 0; u.eval(); u.clk = 1; u.eval();
	u.rst = 0;
	long issued = 0, clk = 0, done = 0, fast = 0;
	int next = 0, f = OPS[rng() % NOPS];
	uint32_t rn = rng() % 4;
	uint64_t a, b, c;
	operands(rng, f, a, b, c);
	while ((issued < count || done < issued) && bad < 10 && clk < 40 * count + 1000)
	{
		// offer the next op on most clocks (and always once all are issued, none)
		bool offer = issued < count && !sl[next].busy && rng() % 8 != 0;
		u.op = f; u.rn = rn; u.a = a; u.b = b; u.c = c; u.rd = next; u.rb = 31;   // (no op writes f31: no addend comes late)
		u.fast = sgl(a) && sgl(c);
		u.issue = 0;
		u.clk = 0; u.eval();
		bool go = offer && u.ok;
		u.issue = go;
		u.eval();
		// the result this clock
		if (u.wv)
		{
			slot &q = sl[u.wrd];
			if (!q.busy) { printf("a result for f%d, which nothing is writing\n", int(u.wrd)); bad++; }
			else
			{
				if (u.wval != q.want)
				{
					printf("%-8s rn %d  a %016llX b %016llX c %016llX: model %016llX, RTL %016llX (%ld clocks)\n", NAME[q.f], q.rn,
						(unsigned long long)q.a, (unsigned long long)q.b, (unsigned long long)q.c, (unsigned long long)q.want,
						(unsigned long long)u.wval, clk - q.at);
					bad++;
				}
				q.busy = false;
				done++;
			}
		}
		if (go)
		{
			slot &q = sl[next];
			uint32_t wcr;
			model(m, bus, f, rn, a, b, c, q.want, wcr);
			q.busy = true; q.f = f; q.rn = rn; q.a = a; q.b = b; q.c = c; q.at = clk;
			n[f]++;
			if (u.fast && (f == F_MUL || f == F_MULS || (f >= F_MADD && f <= F_NMSUB) || (f >= F_MADDS && f <= F_NMSUBS)))
				fast++;
			issued++;
			next = (next + 1) % 31;
			f = OPS[rng() % NOPS];
			rn = rng() % 4;
			operands(rng, f, a, b, c);
		}
		u.clk = 1; u.eval();
		clk++;
	}
	if (done < issued && bad < 10) { printf("%ld results missing\n", issued - done); bad++; }
	printf("%s: %ld operations (%ld fast multiplies), %d kinds, %.2f clocks each\n", bad ? "FAIL" : "PASS", issued, fast, NOPS,
		double(clk) / (issued ? issued : 1));
#else
	Vppc_fpu u;
	u.rst = 1; u.start = 0;
	u.clk = 0; u.eval(); u.clk = 1; u.eval();
	u.rst = 0;
	for (long i = 0; i < count && bad < 10; i++)
	{
		int f = rng() % F_N;
		uint32_t rn = rng() % 4;
		uint64_t a, b, c, want;
		uint32_t wcr;
		operands(rng, f, a, b, c);
		model(m, bus, f, rn, a, b, c, want, wcr);
		// the unit
		u.op = f; u.rn = rn; u.a = a; u.b = b; u.c = c; u.start = 1;
		u.clk = 0; u.eval(); u.clk = 1; u.eval();
		u.start = 0;
		int cyc = 0;
		while (!u.done && cyc < 400) { u.clk = 0; u.eval(); u.clk = 1; u.eval(); cyc++; }
		uint64_t got = f == F_D2S ? uint64_t(uint32_t(u.res)) : u.res;
		bool ok = u.done && (f == F_CMP ? u.crf == wcr : got == want);
		n[f]++;
		if (!ok)
		{
			printf("%-8s rn %d  a %016llX b %016llX c %016llX: model %016llX (cr %X), RTL %016llX (cr %X)%s\n", NAME[f], rn,
				(unsigned long long)a, (unsigned long long)b, (unsigned long long)c, (unsigned long long)want, wcr,
				(unsigned long long)got, uint32_t(u.crf), u.done ? "" : " (no done)");
			bad++;
		}
	}
	long total = 0;
	for (int f = 0; f < F_N; f++) total += n[f];
	printf("%s: %ld operations, %d kinds\n", bad ? "FAIL" : "PASS", total, int(F_N));
#endif
	return bad ? 1 : 0;
}
