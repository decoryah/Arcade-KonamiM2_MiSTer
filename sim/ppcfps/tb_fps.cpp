// The single-precision float units (rtl/ppc_fps.sv) against the host's floats: each op with random operands (any bits, close
// exponents, near-cancelling values, denormals) in the four rounding modes. A NaN result only has to be a NaN. fmadds is fused,
// so the host's is fmaf; fnmadds is its negation done before the round, as the unit does, its exact zero's sign aside.
#include <cfenv>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include "verilated.h"
#ifdef IT
#include "Vppc_fps_it.h"
typedef Vppc_fps_it T;
#else
#include "Vppc_fps_dp.h"
typedef Vppc_fps_dp T;
#endif

enum { F_ADD, F_SUB, F_MUL, F_DIV, F_SQRT, F_RSQRTE, F_MADD, F_MSUB, F_NMADD, F_NMSUB,
	F_ADDS, F_SUBS, F_MULS, F_DIVS, F_SQRTS, F_RES, F_MADDS, F_MSUBS, F_NMADDS, F_NMSUBS, F_RSP, F_CTIW, F_CTIWZ };

static float fl(uint32_t x) { float f; memcpy(&f, &x, 4); return f; }
static uint32_t ui(float f) { uint32_t x; memcpy(&x, &f, 4); return x; }
static const int MODES[4] = { FE_TONEAREST, FE_TOWARDZERO, FE_UPWARD, FE_DOWNWARD };

static std::mt19937 rng(12345);
static uint32_t rnd() { return rng(); }
static uint32_t operand(uint32_t near) {
	uint32_t r = rnd();
	switch (rnd() % 8) {
		case 0: return r;                                                       // any bits
		case 1: return (r & 0x807fffff) | ((100 + rnd() % 60) << 23);           // ordinary
		case 2: return (r & 0x807fffff) | ((120 + rnd() % 16) << 23);
		case 3: return r & 0x807fffff;                                          // denormal
		case 4: return (r & 0x807fffff) | ((rnd() % 30) << 23);                 // small
		case 5: return (r & 0x807fffff) | ((225 + rnd() % 30) << 23);           // large
		case 6: return near ^ (rnd() % 8) ^ (rnd() & 0x80000000);               // near another, either sign
		default: {
			static const uint32_t sp[] = { 0, 0x80000000, 0x7f800000, 0xff800000, 0x7fc00000, 0x3f800000, 1, 0x00800000, 0x7f7fffff };
			return sp[rnd() % 9];
		}
	}
}

static T *t;
static void tick() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); }

static uint32_t ctiw(uint32_t b, int mode) {
	float f = fl(b);
	if (std::isnan(f) || std::isinf(f)) return 0x80000000u;
	double d = f;
	double r;
	switch (mode) {
		case 0: r = std::nearbyint(d); break;    // (the host's mode is nearest here)
		case 1: r = std::trunc(d); break;
		case 2: r = std::ceil(d); break;
		default: r = std::floor(d); break;
	}
	if (r >= 2147483648.0 || r < -2147483648.0) return 0x80000000u;
	return (uint32_t)(int32_t)r;
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	int n = argc > 1 ? atoi(argv[1]) : 1000000;
	t = new T;
	t->rst = 1;
	tick(); tick();
	t->rst = 0;
	long errs = 0;
#ifdef IT
	static const int ops[] = { F_DIVS, F_DIV, F_SQRTS, F_RES, F_RSQRTE };
#else
	static const int ops[] = { F_ADDS, F_SUBS, F_MULS, F_MADDS, F_MSUBS, F_NMADDS, F_NMSUBS, F_ADD, F_MADD, F_RSP, F_CTIW, F_CTIWZ };
#endif
	const int nops = sizeof(ops) / sizeof(ops[0]);
	long perop[32] = {0};
	for (int i = 0; i < n; i++) {
		int op = ops[rnd() % nops];
		int rn = rnd() % 4;
		uint32_t a = operand(0x3f800000), c = operand(a), b = operand(a);
		// (a product near b, for the cancelling case)
		if ((op == F_MADDS || op == F_MSUBS || op == F_NMADDS || op == F_NMSUBS || op == F_MADD) && rnd() % 3 == 0) {
			fesetround(FE_TONEAREST);
			b = ui(fl(a) * fl(c)) ^ (rnd() & 0x80000000) ^ (rnd() % 4);
		}
		t->op = op; t->rn = rn; t->a = a; t->b = b;
#ifdef IT
		t->start = 1;
		tick();
		t->start = 0;
		int w = 0;
		while (!t->done && w < 100) { tick(); w++; }
		uint32_t got = t->res;
		if (w >= 100) { printf("TIMEOUT op %d\n", op); return 1; }
#else
		t->c = c; t->cpu = 0; t->rd = 1; t->i_bw = 0;
		t->issue = 1;
		tick();
		t->issue = 0;
		int w = 0;
		t->eval();
		while (!t->ev && w < 20) { tick(); w++; }
		if (w >= 20) { printf("TIMEOUT op %d\n", op); return 1; }
		uint32_t got = (uint32_t)t->evl;
		int gotint = (int)((t->evl >> 32) & 1);
		tick();
#endif
		volatile float fa = fl(a), fb = fl(b), fc = fl(c);
		uint32_t want = 0;
		bool isint = false;
		fesetround(MODES[rn]);
		switch (op) {
			case F_ADD: case F_ADDS: want = ui(fa + fb); break;
			case F_SUB: case F_SUBS: want = ui(fa - fb); break;
			case F_MUL: case F_MULS: want = ui(fa * fc); break;
			case F_DIV: case F_DIVS: want = ui(fa / fb); break;
			case F_SQRT: case F_SQRTS: want = ui(sqrtf(fb)); break;
			case F_RES: want = ui(1.0f / fb); break;
			case F_RSQRTE: { volatile float s = sqrtf(fb); want = ui(1.0f / s); break; }
			case F_MADD: case F_MADDS: want = ui(fmaf(fa, fc, fb)); break;
			case F_MSUB: case F_MSUBS: want = ui(fmaf(fa, fc, -fb)); break;
			case F_NMADD: case F_NMADDS: want = ui(fmaf(-fa, fc, -fb)); break;
			case F_NMSUB: case F_NMSUBS: want = ui(fmaf(-fa, fc, fb)); break;
			case F_RSP: want = b; break;
			case F_CTIW: fesetround(FE_TONEAREST); want = ctiw(b, rn); isint = true; break;
			case F_CTIWZ: fesetround(FE_TONEAREST); want = ctiw(b, 1); isint = true; break;
		}
		fesetround(FE_TONEAREST);
		bool ok = got == want;
		if (!isint && std::isnan(fl(want)) && std::isnan(fl(got))) ok = true;
		if ((op == F_NMADD || op == F_NMADDS) && (want & 0x7fffffff) == 0 && (got & 0x7fffffff) == 0) ok = true;
#ifndef IT
		if (gotint != (isint ? 1 : 0)) ok = false;
#endif
		if (!ok) {
			perop[op]++;
			if (errs < 25) printf("op %2d rn %d a %08x c %08x b %08x: got %08x want %08x\n", op, rn, a, c, b, got, want);
			errs++;
		}
	}
	printf("per op:");
	for (int i = 0; i < 32; i++) if (perop[i]) printf(" %d:%ld", i, perop[i]);
	printf("\n%s: %d ops, %ld wrong\n", errs ? "FAIL" : "PASS", n, errs);
	return errs != 0;
}
