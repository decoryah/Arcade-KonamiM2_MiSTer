// ppc602.cpp: the PowerPC 602 as MAME 0.289's ppcdrc.cpp runs it (see ppc602.h). Each case names MAME's opcode.
// Build with -ffp-contract=off -frounding-math, so the host's doubles round as MAME's x64 code does.
#include "ppc602.h"
#include <cfenv>
#include <cmath>
#include <cstring>

double rsqrte602(double in);    // (below sp_a: frsqrte as the 602's table)

enum { TR_READ = 0, TR_WRITE = 1, TR_FETCH = 2 };

static constexpr uint32_t DSISR_NOT_FOUND = 0x40000000, DSISR_PROTECTED = 0x08000000, DSISR_STORE = 0x02000000;

static inline uint32_t rol32(uint32_t v, int s) { s &= 31; return s ? (v << s) | (v >> (32 - s)) : v; }
static inline uint32_t rlw_mask(int mb, int me)
{
	uint32_t m = (0xffffffffu >> mb) ^ (me >= 31 ? 0 : 0xffffffffu >> (me + 1));
	return mb > me ? ~m : m;
}
static inline uint32_t crmask(int n) { return 0xf0000000u >> (4 * n); }
static inline uint32_t crf_mask(uint32_t fm)
{
	uint32_t m = 0;
	for (int i = 0; i < 8; i++)
		if (fm & (0x80 >> i)) m |= crmask(i);
	return m;
}
static inline uint32_t compute_spr(uint32_t f) { return ((f >> 5) & 0x1f) | ((f & 0x1f) << 5); }

#define RD   ((op >> 21) & 31)
#define RS   RD
#define RA   ((op >> 16) & 31)
#define RB   ((op >> 11) & 31)
#define RC_  ((op >> 6) & 31)
#define SIMM int32_t(int16_t(op & 0xffff))
#define UIMM (op & 0xffff)
#define CRFD ((op >> 23) & 7)
#define CRFS ((op >> 18) & 7)
#define CRBD ((op >> 21) & 31)
#define CRBA ((op >> 16) & 31)
#define CRBB ((op >> 11) & 31)
#define SH   ((op >> 11) & 31)
#define MB   ((op >> 6) & 31)
#define ME   ((op >> 1) & 31)
#define RCB  (op & 1)
#define OE   (op & 0x400)
#define RAZ  (RA ? r[RA] : 0)

void ppc602::reset()
{
	pc = 0xfff00100;
	msr = MSR_IP;
	spr[SPR_IBR] = 0;
	spr[SPR_ESASRR] = 0;
	spr[SPR_HID0] = 1;
	fpscr = 0;
	reserved = false;
	set_round();
}

uint32_t ppc602::get_cr() const
{
	uint32_t v = 0;
	for (int i = 0; i < 8; i++)
		v |= uint32_t(cr[i] & 0xf) << (28 - 4 * i);
	return v;
}

void ppc602::set_cr(uint32_t v)
{
	for (int i = 0; i < 8; i++)
		cr[i] = (v >> (28 - 4 * i)) & 0xf;
}

void ppc602::swap_tgpr()
{
	for (int i = 0; i < 4; i++)
	{
		uint32_t t = r[i];
		r[i] = tgpr[i];
		tgpr[i] = t;
	}
}

// ppccom_translate_address_internal for the 602: the BATs, then protection-only mode, then a miss (MAME's 603 TLB is
// never loaded on a 602)
bool ppc602::translate(uint32_t &a, int type, uint32_t &dsisr)
{
	if ((type == TR_FETCH && !(msr & MSR_IR)) || (type != TR_FETCH && !(msr & MSR_DR)))
		return true;
	int transpriv = (msr & MSR_PR) ? 0 : 1;
	int base = type == TR_FETCH ? SPR_IBAT0U : SPR_DBAT0U;
	for (int n = 0; n < 4; n++)
	{
		uint32_t upper = spr[base + 2 * n];
		if ((upper >> transpriv) & 1)
		{
			uint32_t mask = (~upper << 15) & 0xfffe0000;
			if ((a & mask) == (upper & mask))
			{
				uint32_t lower = spr[base + 2 * n + 1];
				uint32_t pp = lower & 3;
				bool ok = type == TR_WRITE ? pp == 2 : pp != 0;
				if (!ok)
				{
					dsisr = DSISR_PROTECTED | (type == TR_WRITE ? DSISR_STORE : 0);
					return false;
				}
				a = (lower & mask) | (a & ~mask);
				return true;
			}
		}
	}
	if (spr[SPR_HID0] & 0x80)
		return true;
	uint32_t seg = sr[a >> 28];
	if (type == TR_FETCH && (seg & 0x10000000))
	{
		dsisr = DSISR_PROTECTED;
		return false;
	}
	dsisr = DSISR_NOT_FOUND | (type == TR_WRITE ? DSISR_STORE : 0);
	return false;
}

uint32_t ppc602::ea_phys(uint32_t ea, int type)
{
	uint32_t a = ea, dsisr = 0;
	if (translate(a, type, dsisr))
		return a;
	if (type == TR_FETCH)
	{
		if (dsisr & DSISR_PROTECTED)
			raise(EX_ISI, 0x08000000);
		raise(EX_ITLBMISS);
	}
	if (dsisr & DSISR_PROTECTED)
	{
		spr[SPR_DSISR] = dsisr;
		raise(EX_DSI, ea);
	}
	// the 603's miss registers
	uint32_t seg = sr[ea >> 28];
	uint32_t hashbase = spr[SPR_SDR1] & 0xffff0000;
	uint32_t hashmask = ((spr[SPR_SDR1] & 0x1ff) << 16) | 0xffff;
	uint32_t hash = (seg & 0x7ffff) ^ ((ea >> 12) & 0xffff);
	spr[SPR_DMISS] = ea;
	spr[SPR_DCMP] = 0x80000000 | ((seg & 0xffffff) << 7) | ((ea >> 22) & 0x3f);
	spr[SPR_HASH1] = hashbase | ((hash << 6) & hashmask);
	spr[SPR_HASH2] = hashbase | ((~hash << 6) & hashmask);
	raise(type == TR_WRITE ? EX_DTLBMISSS : EX_DTLBMISSL, ea);
}

uint8_t  ppc602::rd8(uint32_t ea)  { return bus.read8(ea_phys(ea, TR_READ)); }
uint16_t ppc602::rd16(uint32_t ea) { return bus.read16(ea_phys(ea, TR_READ)); }
uint32_t ppc602::rd32(uint32_t ea) { return bus.read32(ea_phys(ea, TR_READ)); }
uint64_t ppc602::rd64(uint32_t ea) { return bus.read64(ea_phys(ea, TR_READ)); }
void ppc602::wr8(uint32_t ea, uint8_t d)   { bus.write8(ea_phys(ea, TR_WRITE), d); }
void ppc602::wr16(uint32_t ea, uint16_t d) { bus.write16(ea_phys(ea, TR_WRITE), d); }
void ppc602::wr32(uint32_t ea, uint32_t d) { bus.write32(ea_phys(ea, TR_WRITE), d); }
void ppc602::wr64(uint32_t ea, uint64_t d) { bus.write64(ea_phys(ea, TR_WRITE), d); }

// static_generate_exception, OEA and 603 MMU parts
void ppc602::take(int ex, uint32_t srr0, uint32_t param)
{
	if (ex == EX_DSI || ex == EX_ALIGN)
		spr[SPR_DAR] = param;
	spr[SPR_SRR0] = srr0;
	uint32_t srr1 = msr & 0x87c0ffff;
	if (ex == EX_ISI || ex == EX_PROGRAM)
		srr1 |= param;
	if (ex == EX_ITLBMISS)
		srr1 |= 0x00040000;
	else if (ex == EX_DTLBMISSL)
		srr1 |= 0x00010000;
	bool tlb = ex == EX_ITLBMISS || ex == EX_DTLBMISSL || ex == EX_DTLBMISSS;
	if (tlb)
		srr1 = (srr1 & 0x0fffffff) | (uint32_t(cr[0]) << 28);
	spr[SPR_SRR1] = srr1;
	uint32_t andmask = MSR_POW | MSR_EE | MSR_PR | MSR_FP | MSR_FE0 | MSR_SE | MSR_BE | MSR_FE1 | MSR_IR | MSR_DR | MSR_RI | MSR_LE;
	uint32_t ormask = 0;
	if (tlb)
		ormask |= MSR_TGPR;
	else
		andmask |= MSR_TGPR;
	uint32_t old = msr;
	uint32_t m = (msr & ~andmask) | ormask;
	m = (m & ~MSR_LE) | ((m >> 16) & MSR_LE);
	msr = m;
	if ((old ^ m) & MSR_TGPR)
		swap_tgpr();
	uint32_t base = (msr & MSR_IP) ? 0xfff00000 : spr[SPR_IBR];
	pc = base | (uint32_t(ex) << 8);
}

void ppc602::interrupt(int ex)
{
	take(ex, pc, 0);
}

int ppc602::step()
{
	last_pc = pc;
	timer_read = false;
	try
	{
		uint32_t pa = ea_phys(pc, TR_FETCH);
		uint32_t op = bus.fetch(pa);
		last_op = op;
		next_pc = pc + 4;
		exec(op);
		pc = next_pc;
		return EX_NONE;
	}
	catch (exc &e)
	{
		take(e.ex, e.ex == EX_SYSCALL ? last_pc + 4 : last_pc, e.param);
		return e.ex;
	}
}

void ppc602::branch(uint32_t target, bool lk)
{
	if (lk)
		spr[SPR_LR] = last_pc + 4;
	next_pc = target;
}

bool ppc602::cond(uint32_t bo, uint32_t bi)
{
	if (!(bo & 0x04))
	{
		spr[SPR_CTR]--;
		if ((spr[SPR_CTR] != 0) != !(bo & 0x02))
			return false;
	}
	if (!(bo & 0x10))
	{
		bool bit = cr[bi / 4] & (8 >> (bi % 4));
		if (bit != bool(bo & 0x08))
			return false;
	}
	return true;
}

// ---- floating point ------------------------------------------------------------------------------------------------

void ppc602::set_round()
{
	static const int modes[4] = { FE_TONEAREST, FE_TOWARDZERO, FE_UPWARD, FE_DOWNWARD };
	fesetround(modes[fpscr & 3]);
}

double ppc602::fd(int n) const
{
	double d;
	memcpy(&d, &f[n], 8);
	return d;
}

void ppc602::setfd(int n, double v)
{
	memcpy(&f[n], &v, 8);
}

static inline double rnds(double v)
{
	volatile float s = float(v);
	return double(s);
}

static inline uint64_t dbits(double v) { uint64_t b; memcpy(&b, &v, 8); return b; }
static inline double bitsd(uint64_t b) { double v; memcpy(&v, &b, 8); return v; }
static inline uint32_t fbits(float v) { uint32_t b; memcpy(&b, &v, 4); return b; }
static inline float bitsf(uint32_t b) { float v; memcpy(&v, &b, 4); return v; }

// x86 SSE NaN rules, as MAME's x64 back end runs them (addsd and the like with the first operand in the destination):
// a NaN operand, the first if both, comes back quieted. Made explicit so the host compiler's operand order doesn't matter.
static inline double quiet(double v) { return bitsd(dbits(v) | 0x0008000000000000ull); }
static inline double x86_add(double a, double b) { return std::isnan(a) ? quiet(a) : std::isnan(b) ? quiet(b) : a + b; }
static inline double x86_sub(double a, double b) { return std::isnan(a) ? quiet(a) : std::isnan(b) ? quiet(b) : a - b; }
static inline double x86_mul(double a, double b) { return std::isnan(a) ? quiet(a) : std::isnan(b) ? quiet(b) : a * b; }
static inline double x86_div(double a, double b) { return std::isnan(a) ? quiet(a) : std::isnan(b) ? quiet(b) : a / b; }

static inline uint32_t fp_to_int(double v, bool trunc)
{
	// x86 cvt(t)sd2si: NaN or out of range gives the integer indefinite
	double t = trunc ? std::trunc(v) : std::nearbyint(v);
	if (std::isnan(t) || t >= 2147483648.0 || t < -2147483648.0)
		return 0x80000000u;
	return uint32_t(int32_t(t));
}

void ppc602::fp_cr1(uint32_t op)
{
	if (RCB)
		cr[1] = fpscr >> 28;
}

// ---- SPRs ----------------------------------------------------------------------------------------------------------

uint32_t ppc602::mfspr(uint32_t n)
{
	switch (n)
	{
		case SPR_XER: return get_xer();
		case SPR_PVR: return PVR;
		case SPR_DEC: timer_read = true; return decrementer;
		case SPR_TBL_R: timer_read = true; return uint32_t(timebase);
		case SPR_TBU_R: timer_read = true; return uint32_t(timebase >> 32) & 0xffffff;
		case 0: return 0;                                                                              // MQ, not on a 602
	}
	return spr[n];
}

void ppc602::mtspr(uint32_t n, uint32_t v)
{
	switch (n)
	{
		case SPR_XER: xer = v & ~0x80000000u; xerso = v >> 31; return;
		case SPR_PVR: return;
		case SPR_DEC: decrementer = v; return;
		case SPR_TBL_W: timebase = (timebase & ~0xffffffff00000000ull) | v; return;   // as MAME
		case SPR_TBU_W: timebase = (timebase & ~0x00000000ffffffffull) | (uint64_t(v) << 32); return;
		case SPR_DMISS: case SPR_DCMP: case SPR_HASH1: case SPR_HASH2: case SPR_IMISS: case SPR_ICMP: return;
	}
	spr[n] = v;
}

// ---- the opcodes ---------------------------------------------------------------------------------------------------

void ppc602::exec(uint32_t op)
{
	if (fpu_exc && !(msr & MSR_FP))
	{
		uint32_t p = op >> 26, x = (op >> 1) & 0x3ff;
		if (p == 0x3b || p == 0x3f || (p >= 0x30 && p <= 0x37) || (p == 0x1f && (x == 0x217 || x == 0x237 || x == 0x257 ||
			x == 0x277 || x == 0x297 || x == 0x2b7 || x == 0x2d7 || x == 0x2f7 || x == 0x3d7)))
			raise(EX_FPU);
	}
	switch (op >> 26)
	{
		case 0x03:                                                                                     // TWI
		{
			int32_t a = r[RA], b = SIMM;
			uint32_t to = RD;
			if (((to & 0x10) && a < b) || ((to & 0x08) && a > b) || ((to & 0x04) && a == b) ||
				((to & 0x02) && r[RA] < uint32_t(b)) || ((to & 0x01) && r[RA] > uint32_t(b)))
				raise(EX_PROGRAM, 0x20000);
			return;
		}
		case 0x07: r[RD] = uint32_t(int32_t(r[RA]) * SIMM); return;                                    // MULLI
		case 0x08: { uint32_t a = r[RA]; r[RD] = uint32_t(SIMM) - a; set_ca(a <= uint32_t(SIMM)); return; } // SUBFIC
		case 0x0a: { uint32_t a = r[RA], b = UIMM; cr[CRFD] = (a < b ? 8 : a > b ? 4 : 2) | xerso; return; } // CMPLI
		case 0x0b: { int32_t a = r[RA], b = SIMM; cr[CRFD] = (a < b ? 8 : a > b ? 4 : 2) | xerso; return; } // CMPI
		case 0x0c: case 0x0d:                                                                          // ADDIC, ADDIC.
		{
			uint32_t a = r[RA], res = a + uint32_t(SIMM);
			set_ca(res < a);
			r[RD] = res;
			if ((op >> 26) == 0x0d) cr0(res);
			return;
		}
		case 0x0e: r[RD] = RAZ + uint32_t(SIMM); return;                                               // ADDI
		case 0x0f: r[RD] = RAZ + (UIMM << 16); return;                                                 // ADDIS
		case 0x10:                                                                                     // BCx
		{
			uint32_t bo = RD, bi = RA;
			uint32_t t = (op & 2) ? uint32_t(int32_t(int16_t(op & 0xfffc))) : last_pc + uint32_t(int32_t(int16_t(op & 0xfffc)));
			if (cond(bo, bi)) branch(t, op & 1);
			else if (op & 1) spr[SPR_LR] = last_pc + 4;
			return;
		}
		case 0x11: raise(EX_SYSCALL);                                                                  // SC
		case 0x12:                                                                                     // Bx
		{
			uint32_t li = op & 0x03fffffc;
			if (li & 0x02000000) li |= 0xfc000000;
			branch((op & 2) ? li : last_pc + li, op & 1);
			return;
		}
		case 0x13: op13(op); return;
		case 0x14: { uint32_t m = rlw_mask(MB, ME); r[RA] = (r[RA] & ~m) | (rol32(r[RS], SH) & m); if (RCB) cr0(r[RA]); return; } // RLWIMI
		case 0x15: r[RA] = rol32(r[RS], SH) & rlw_mask(MB, ME); if (RCB) cr0(r[RA]); return;           // RLWINM
		case 0x17: r[RA] = rol32(r[RS], r[RB] & 31) & rlw_mask(MB, ME); if (RCB) cr0(r[RA]); return;   // RLWNM
		case 0x18: r[RA] = r[RS] | UIMM; return;
		case 0x19: r[RA] = r[RS] | (UIMM << 16); return;
		case 0x1a: r[RA] = r[RS] ^ UIMM; return;
		case 0x1b: r[RA] = r[RS] ^ (UIMM << 16); return;
		case 0x1c: r[RA] = r[RS] & UIMM; cr0(r[RA]); return;
		case 0x1d: r[RA] = r[RS] & (UIMM << 16); cr0(r[RA]); return;
		case 0x1f: op1f(op); return;
		case 0x20: r[RD] = rd32(RAZ + SIMM); return;                                                   // LWZ
		case 0x21: { uint32_t a = r[RA] + SIMM; r[RD] = rd32(a); r[RA] = a; return; }                  // LWZU
		case 0x22: r[RD] = rd8(RAZ + SIMM); return;                                                    // LBZ
		case 0x23: { uint32_t a = r[RA] + SIMM; r[RD] = rd8(a); r[RA] = a; return; }
		case 0x24: wr32(RAZ + SIMM, r[RS]); return;                                                    // STW
		case 0x25: { uint32_t a = r[RA] + SIMM; wr32(a, r[RS]); r[RA] = a; return; }
		case 0x26: wr8(RAZ + SIMM, uint8_t(r[RS])); return;                                            // STB
		case 0x27: { uint32_t a = r[RA] + SIMM; wr8(a, uint8_t(r[RS])); r[RA] = a; return; }
		case 0x28: r[RD] = rd16(RAZ + SIMM); return;                                                   // LHZ
		case 0x29: { uint32_t a = r[RA] + SIMM; r[RD] = rd16(a); r[RA] = a; return; }
		case 0x2a: r[RD] = uint32_t(int32_t(int16_t(rd16(RAZ + SIMM)))); return;                       // LHA
		case 0x2b: { uint32_t a = r[RA] + SIMM; r[RD] = uint32_t(int32_t(int16_t(rd16(a)))); r[RA] = a; return; }
		case 0x2c: wr16(RAZ + SIMM, uint16_t(r[RS])); return;                                          // STH
		case 0x2d: { uint32_t a = r[RA] + SIMM; wr16(a, uint16_t(r[RS])); r[RA] = a; return; }
		case 0x2e:                                                                                     // LMW
		{
			uint32_t base = RAZ;
			for (uint32_t n = RD; n < 32; n++)
			{
				uint32_t v = rd32(base + SIMM + 4 * (n - RD));
				if (n != RA) r[n] = v;
			}
			return;
		}
		case 0x2f:                                                                                     // STMW
		{
			uint32_t base = RAZ;
			for (uint32_t n = RS; n < 32; n++)
				wr32(base + SIMM + 4 * (n - RS), r[n]);
			return;
		}
		case 0x30: ld_fs(RD, rd32(RAZ + SIMM)); return;                                                // LFS
		case 0x31: { uint32_t a = r[RA] + SIMM; ld_fs(RD, rd32(a)); r[RA] = a; return; }
		case 0x32: ld_fd(RD, rd64(RAZ + SIMM)); return;                                                // LFD
		case 0x33: { uint32_t a = r[RA] + SIMM; ld_fd(RD, rd64(a)); r[RA] = a; return; }
		case 0x34: wr32(RAZ + SIMM, st_fs(RS)); return;                                                // STFS
		case 0x35: { uint32_t a = r[RA] + SIMM; wr32(a, st_fs(RS)); r[RA] = a; return; }
		case 0x36: wr64(RAZ + SIMM, f[RS]); return;                                                    // STFD
		case 0x37: { uint32_t a = r[RA] + SIMM; wr64(a, f[RS]); r[RA] = a; return; }
		case 0x3b: op3b(op); return;
		case 0x3f: op3f(op); return;
	}
	raise(EX_PROGRAM, 0x80000);
}

void ppc602::op13(uint32_t op)
{
	auto crb = [&](int b) { return (cr[b / 4] >> (3 - b % 4)) & 1; };
	auto setcrb = [&](int b, int v) { uint8_t m = 8 >> (b % 4); cr[b / 4] = (cr[b / 4] & ~m) | (v ? m : 0); };
	switch ((op >> 1) & 0x3ff)
	{
		case 0x010:                                                                                    // BCLRx
		{
			uint32_t t = spr[SPR_LR] & ~3u;
			if (cond(RD, RA)) branch(t, op & 1);
			else if (op & 1) spr[SPR_LR] = last_pc + 4;
			return;
		}
		case 0x210:                                                                                    // BCCTRx
		{
			uint32_t t = spr[SPR_CTR] & ~3u;
			if (cond(RD, RA)) branch(t, op & 1);
			else if (op & 1) spr[SPR_LR] = last_pc + 4;
			return;
		}
		case 0x000: cr[CRFD] = cr[CRFS]; return;                                                       // MCRF
		case 0x101: setcrb(CRBD, crb(CRBA) & crb(CRBB)); return;
		case 0x081: setcrb(CRBD, crb(CRBA) & !crb(CRBB)); return;
		case 0x0e1: setcrb(CRBD, !(crb(CRBA) & crb(CRBB))); return;
		case 0x1c1: setcrb(CRBD, crb(CRBA) | crb(CRBB)); return;
		case 0x1a1: setcrb(CRBD, crb(CRBA) | !crb(CRBB)); return;
		case 0x021: setcrb(CRBD, !(crb(CRBA) | crb(CRBB))); return;
		case 0x0c1: setcrb(CRBD, crb(CRBA) ^ crb(CRBB)); return;
		case 0x121: setcrb(CRBD, !(crb(CRBA) ^ crb(CRBB))); return;
		case 0x032:                                                                                    // RFI
		{
			uint32_t old = msr;
			msr = (msr & ~0x87c0ffffu) | (spr[SPR_SRR1] & 0x87c0ffff);
			msr &= ~MSR_TGPR;
			if (old & MSR_TGPR) swap_tgpr();
			next_pc = spr[SPR_SRR0];
			return;
		}
		case 0x096: return;                                                                            // ISYNC
	}
	raise(EX_PROGRAM, 0x80000);
}

void ppc602::op1f(uint32_t op)
{
	uint32_t a = r[RA], b = r[RB];
	switch ((op >> 1) & 0x3ff)
	{
		case 0x004:                                                                                    // TW
		{
			uint32_t to = RD;
			if (((to & 0x10) && int32_t(a) < int32_t(b)) || ((to & 0x08) && int32_t(a) > int32_t(b)) || ((to & 0x04) && a == b) ||
				((to & 0x02) && a < b) || ((to & 0x01) && a > b))
				raise(EX_PROGRAM, 0x20000);
			return;
		}
		case 0x10a: case 0x30a:                                                                        // ADDx
		{
			uint32_t res = a + b;
			if (OE) set_ov(((a ^ res) & (b ^ res)) >> 31);
			r[RD] = res;
			if (RCB) cr0(res);
			return;
		}
		case 0x00a: case 0x20a:                                                                        // ADDCx
		{
			uint32_t res = a + b;
			set_ca(res < a);
			if (OE) set_ov(((a ^ res) & (b ^ res)) >> 31);
			r[RD] = res;
			if (RCB) cr0(res);
			return;
		}
		case 0x08a: case 0x28a: case 0x0ca: case 0x2ca: case 0x0ea: case 0x2ea:                        // ADDE, ADDZE, ADDME
		{
			uint32_t sw = (op >> 1) & 0xff;
			uint32_t bb = sw == 0x8a ? b : sw == 0xca ? 0 : 0xffffffff;
			uint64_t s = uint64_t(a) + bb + (ca() ? 1 : 0);
			uint32_t res = uint32_t(s);
			set_ca(s >> 32);
			if (OE) set_ov(((a ^ res) & (bb ^ res)) >> 31);
			r[RD] = res;
			if (RCB) cr0(res);
			return;
		}
		case 0x028: case 0x228:                                                                        // SUBFx
		{
			uint32_t res = b - a;
			if (OE) set_ov(((b ^ a) & (b ^ res)) >> 31);
			r[RD] = res;
			if (RCB) cr0(res);
			return;
		}
		case 0x008: case 0x208:                                                                        // SUBFCx
		{
			uint32_t res = b - a;
			set_ca(a <= b);
			if (OE) set_ov(((b ^ a) & (b ^ res)) >> 31);
			r[RD] = res;
			if (RCB) cr0(res);
			return;
		}
		case 0x088: case 0x288: case 0x0c8: case 0x2c8: case 0x0e8: case 0x2e8:                        // SUBFE, SUBFZE, SUBFME
		{
			uint32_t sw = (op >> 1) & 0xff;
			uint32_t bb = sw == 0x88 ? b : sw == 0xc8 ? 0 : 0xffffffff;
			uint64_t s = uint64_t(~a) + bb + (ca() ? 1 : 0);
			uint32_t res = uint32_t(s);
			set_ca(s >> 32);
			if (OE) set_ov(((~a ^ res) & (bb ^ res)) >> 31);
			r[RD] = res;
			if (RCB) cr0(res);
			return;
		}
		case 0x068: case 0x268:                                                                        // NEGx
		{
			uint32_t res = 0 - a;
			if (OE) set_ov(a == 0x80000000);
			r[RD] = res;
			if (RCB) cr0(res);
			return;
		}
		case 0x000: cr[CRFD] = (int32_t(a) < int32_t(b) ? 8 : int32_t(a) > int32_t(b) ? 4 : 2) | xerso; return; // CMP
		case 0x020: cr[CRFD] = (a < b ? 8 : a > b ? 4 : 2) | xerso; return;                            // CMPL
		case 0x00b: r[RD] = uint32_t((uint64_t(a) * b) >> 32); if (RCB) cr0(r[RD]); return;            // MULHWU
		case 0x04b: r[RD] = uint32_t((int64_t(int32_t(a)) * int32_t(b)) >> 32); if (RCB) cr0(r[RD]); return; // MULHW
		case 0x0eb: case 0x2eb:                                                                        // MULLWx
		{
			int64_t p = int64_t(int32_t(a)) * int32_t(b);
			if (OE) set_ov(p != int64_t(int32_t(p)));
			r[RD] = uint32_t(p);
			if (RCB) cr0(r[RD]);
			return;
		}
		case 0x1cb: case 0x3cb:                                                                        // DIVWUx
			if (b == 0)
			{
				r[RD] = 0;
				if (OE) { xerso = 1; xer |= 0x40000000; }
				if (RCB) cr[0] = 2 | xerso;
				return;
			}
			r[RD] = a / b;
			if (OE) set_ov(false);
			if (RCB) cr0(r[RD]);
			return;
		case 0x1eb: case 0x3eb:                                                                        // DIVWx
			if (b == 0 || (b == 0xffffffff && a == 0x80000000))
			{
				r[RD] = 0;
				if (OE) { xerso = 1; xer |= 0x40000000; }
				if (RCB) cr[0] = 2 | xerso;
				return;
			}
			r[RD] = uint32_t(int32_t(a) / int32_t(b));
			if (OE) set_ov(false);
			if (RCB) cr0(r[RD]);
			return;
		case 0x01c: r[RA] = r[RS] & b; if (RCB) cr0(r[RA]); return;                                    // AND
		case 0x03c: r[RA] = r[RS] & ~b; if (RCB) cr0(r[RA]); return;                                   // ANDC
		case 0x1dc: r[RA] = ~(r[RS] & b); if (RCB) cr0(r[RA]); return;                                 // NAND
		case 0x1bc: r[RA] = r[RS] | b; if (RCB) cr0(r[RA]); return;                                    // OR
		case 0x19c: r[RA] = r[RS] | ~b; if (RCB) cr0(r[RA]); return;                                   // ORC
		case 0x07c: r[RA] = ~(r[RS] | b); if (RCB) cr0(r[RA]); return;                                 // NOR
		case 0x13c: r[RA] = r[RS] ^ b; if (RCB) cr0(r[RA]); return;                                    // XOR
		case 0x11c: r[RA] = ~(r[RS] ^ b); if (RCB) cr0(r[RA]); return;                                 // EQV
		case 0x018: { uint32_t n = b & 0x3f; r[RA] = n > 31 ? 0 : r[RS] << n; if (RCB) cr0(r[RA]); return; } // SLW
		case 0x218: { uint32_t n = b & 0x3f; r[RA] = n > 31 ? 0 : r[RS] >> n; if (RCB) cr0(r[RA]); return; } // SRW
		case 0x318:                                                                                    // SRAW
		{
			uint32_t n = b & 0x3f, s = r[RS];
			if (n >= 32)
			{
				set_ca(s >> 31);
				r[RA] = uint32_t(int32_t(s) >> 31);
			}
			else
			{
				set_ca((s >> 31) && (s & ~(0xffffffffu << n)));
				r[RA] = uint32_t(int32_t(s) >> n);
			}
			if (RCB) cr0(r[RA]);
			return;
		}
		case 0x338:                                                                                    // SRAWI
		{
			uint32_t n = SH, s = r[RS];
			set_ca((s >> 31) && (s & ~(0xffffffffu << n)));
			r[RA] = uint32_t(int32_t(s) >> n);
			if (RCB) cr0(r[RA]);
			return;
		}
		case 0x01a: { uint32_t s = r[RS]; r[RA] = s ? __builtin_clz(s) : 32; if (RCB) cr0(r[RA]); return; } // CNTLZW
		case 0x3ba: r[RA] = uint32_t(int32_t(int8_t(r[RS]))); if (RCB) cr0(r[RA]); return;             // EXTSB
		case 0x39a: r[RA] = uint32_t(int32_t(int16_t(r[RS]))); if (RCB) cr0(r[RA]); return;            // EXTSH

		// loads and stores, indexed
		case 0x057: r[RD] = rd8(RAZ + b); return;                                                      // LBZX
		case 0x117: r[RD] = rd16(RAZ + b); return;                                                     // LHZX
		case 0x157: r[RD] = uint32_t(int32_t(int16_t(rd16(RAZ + b)))); return;                         // LHAX
		case 0x017: r[RD] = rd32(RAZ + b); return;                                                     // LWZX
		case 0x217: ld_fs(RD, rd32(RAZ + b)); return;                                                  // LFSX
		case 0x257: ld_fd(RD, rd64(RAZ + b)); return;                                                  // LFDX
		case 0x316: r[RD] = __builtin_bswap16(rd16(RAZ + b)); return;                                  // LHBRX
		case 0x216: r[RD] = __builtin_bswap32(rd32(RAZ + b)); return;                                  // LWBRX
		case 0x077: { uint32_t e = a + b; r[RD] = rd8(e); r[RA] = e; return; }                         // LBZUX
		case 0x137: { uint32_t e = a + b; r[RD] = rd16(e); r[RA] = e; return; }                        // LHZUX
		case 0x177: { uint32_t e = a + b; r[RD] = uint32_t(int32_t(int16_t(rd16(e)))); r[RA] = e; return; } // LHAUX
		case 0x037: { uint32_t e = a + b; r[RD] = rd32(e); r[RA] = e; return; }                        // LWZUX
		case 0x237: { uint32_t e = a + b; ld_fs(RD, rd32(e)); r[RA] = e; return; }                     // LFSUX
		case 0x277: { uint32_t e = a + b; ld_fd(RD, rd64(e)); r[RA] = e; return; }                     // LFDUX
		case 0x014:                                                                                    // LWARX
		{
			uint32_t e = RAZ + b;
			r[RD] = rd32(e);
			reserved = true;
			reserved_addr = e;
			return;
		}
		case 0x255: case 0x215:                                                                        // LSWI, LSWX
		{
			uint32_t e, n;
			if (((op >> 1) & 0x3ff) == 0x255) { e = RAZ; n = ((RB - 1) & 0x1f) + 1; }
			else { e = RAZ + b; n = xer & 0x7f; }
			uint32_t reg = RD;
			for (uint32_t i = 0; i < n; i++)
			{
				if ((i & 3) == 0) r[reg] = 0;
				r[reg] |= uint32_t(rd8(e + i)) << (24 - 8 * (i & 3));
				if ((i & 3) == 3) reg = (reg + 1) & 31;
			}
			return;
		}
		case 0x0d7: wr8(RAZ + b, uint8_t(r[RS])); return;                                              // STBX
		case 0x197: wr16(RAZ + b, uint16_t(r[RS])); return;                                            // STHX
		case 0x097: wr32(RAZ + b, r[RS]); return;                                                      // STWX
		case 0x297: wr32(RAZ + b, st_fs(RS)); return;                                                  // STFSX
		case 0x3d7: wr32(RAZ + b, st_fiw(RS)); return;                                                 // STFIWX
		case 0x2d7: wr64(RAZ + b, f[RS]); return;                                                      // STFDX
		case 0x396: wr16(RAZ + b, __builtin_bswap16(uint16_t(r[RS]))); return;                         // STHBRX
		case 0x296: wr32(RAZ + b, __builtin_bswap32(r[RS])); return;                                   // STWBRX
		case 0x0f7: { uint32_t e = a + b; wr8(e, uint8_t(r[RS])); r[RA] = e; return; }                 // STBUX
		case 0x1b7: { uint32_t e = a + b; wr16(e, uint16_t(r[RS])); r[RA] = e; return; }               // STHUX
		case 0x0b7: { uint32_t e = a + b; wr32(e, r[RS]); r[RA] = e; return; }                         // STWUX
		case 0x2b7: { uint32_t e = a + b; wr32(e, st_fs(RS)); r[RA] = e; return; }                     // STFSUX
		case 0x2f7: { uint32_t e = a + b; wr64(e, f[RS]); r[RA] = e; return; }                         // STFDUX
		case 0x096:                                                                                    // STWCX.
		{
			uint32_t e = RAZ + b;
			if (reserved)
			{
				wr32(e, r[RS]);
				cr[0] = 2 | xerso;
			}
			else
				cr[0] = xerso;
			reserved = false;
			return;
		}
		case 0x2d5: case 0x295:                                                                        // STSWI, STSWX
		{
			uint32_t e, n;
			if (((op >> 1) & 0x3ff) == 0x2d5) { e = RAZ; n = ((RB - 1) & 0x1f) + 1; }
			else { e = RAZ + b; n = xer & 0x7f; }
			uint32_t reg = RS;
			for (uint32_t i = 0; i < n; i++)
			{
				wr8(e + i, uint8_t(r[reg] >> (24 - 8 * (i & 3))));
				if ((i & 3) == 3) reg = (reg + 1) & 31;
			}
			return;
		}

		// cache, TLB, sync: no effect in MAME (dcbz aside)
		case 0x036: case 0x056: case 0x0f6: case 0x116: case 0x256: case 0x356: case 0x1d6: case 0x236: case 0x3d6:
		case 0x132: case 0x172: case 0x3d2: case 0x3f2:
			return;
		case 0x3f6:                                                                                    // DCBZ
		{
			uint32_t e = (RAZ + b) & ~31u;
			for (int i = 0; i < 4; i++)
				wr64(e + 8 * i, 0);
			return;
		}

		// moves
		case 0x013: r[RD] = get_cr(); return;                                                          // MFCR
		case 0x053: r[RD] = msr; return;                                                               // MFMSR
		case 0x153: r[RD] = mfspr(compute_spr((op >> 11) & 0x3ff)); return;                            // MFSPR
		case 0x253: r[RD] = sr[(op >> 16) & 15]; return;                                               // MFSR
		case 0x293: r[RD] = sr[b >> 28]; return;                                                       // MFSRIN
		case 0x173:                                                                                    // MFTB
		{
			uint32_t tbr = compute_spr((op >> 11) & 0x3ff);
			if (tbr != SPR_TBL_R && tbr != SPR_TBU_R) break;
			r[RD] = mfspr(tbr);
			return;
		}
		case 0x090:                                                                                    // MTCRF
		{
			uint32_t crm = (op >> 12) & 0xff, s = r[RS];
			for (int i = 0; i < 8; i++)
				if (crm & (0x80 >> i)) cr[i] = (s >> (28 - 4 * i)) & 0xf;
			return;
		}
		case 0x092:                                                                                    // MTMSR
		{
			uint32_t old = msr;
			msr = r[RS];
			if ((old ^ msr) & MSR_TGPR) swap_tgpr();
			return;
		}
		case 0x1d3: mtspr(compute_spr((op >> 11) & 0x3ff), r[RS]); return;                             // MTSPR
		case 0x0d2: sr[(op >> 16) & 15] = r[RS]; return;                                               // MTSR
		case 0x0f2: sr[b >> 28] = r[RS]; return;                                                       // MTSRIN
		case 0x200:                                                                                    // MCRXR
			cr[CRFD] = ((xer >> 28) & 0xf) | (xerso << 3);
			xer &= ~0xf0000000u;
			xerso = 0;
			return;
		case 0x254:                                                                                    // ESA
		{
			if (msr & MSR_SA) raise(EX_PROGRAM, 0x20000);
			uint32_t e = spr[SPR_ESASRR];
			e = (e & ~1u) | (rol32(msr, 17) & 1);
			e = (e & ~2u) | (rol32(msr, 11) & 2);
			e = (e & ~4u) | (rol32(msr, 11) & 4);
			e = (e & ~8u) | (rol32(msr, 21) & 8);
			spr[SPR_ESASRR] = e;
			msr = (msr & ~(MSR_AP | MSR_EE | MSR_PR)) | MSR_SA;
			return;
		}
		case 0x274:                                                                                    // DSA
		{
			if (!(msr & MSR_SA)) raise(EX_PROGRAM, 0x20000);
			uint32_t e = spr[SPR_ESASRR];
			msr = (msr & ~MSR_EE) | (rol32(e, 15) & MSR_EE);
			msr = (msr & ~MSR_SA) | (rol32(e, 21) & MSR_SA);
			msr = (msr & ~MSR_AP) | (rol32(e, 21) & MSR_AP);
			msr = (msr & ~MSR_PR) | (rol32(e, 11) & MSR_PR);
			return;
		}
	}
	raise(EX_PROGRAM, 0x80000);
}

void ppc602::op3b(uint32_t op)
{
	if (sp) { sp_a(op); return; }
	double a = fd(RA), b = fd(RB), c = fd(RC_);
	double v;
	// the pipeline's single ops (single_ftz): a double under the single normals is a zero
	auto rnds = [this](double d) { return single_ftz && std::fabs(d) < 0x1p-126 ? std::copysign(0.0, d) : ::rnds(d); };
	switch ((op >> 1) & 0x1f)
	{
		case 0x15: v = rnds(x86_add(a, b)); break;                                                        // FADDS
		case 0x14: v = rnds(x86_sub(a, b)); break;                                                        // FSUBS
		case 0x19: v = rnds(x86_mul(a, c)); break;                                                        // FMULS
		case 0x12: v = ::rnds(x86_div(a, b)); break;                                                      // FDIVS
		case 0x16: raise(EX_PROGRAM, 0x80000);                                                          // FSQRTS: illegal on the 602
		case 0x18: { volatile float s = float(b); volatile float q = 1.0f / s; v = double(q); break; } // FRES
		case 0x1d: { double p = x86_mul(a, c); v = rnds(x86_add(p, b)); break; }                             // FMADDS
		case 0x1c: { double p = x86_mul(a, c); v = rnds(x86_sub(p, b)); break; }                             // FMSUBS
		case 0x1f: { double p = x86_mul(a, c); volatile double s = x86_add(p, b); v = rnds(-s); break; }     // FNMADDS
		case 0x1e: { double p = x86_mul(a, c); v = rnds(x86_sub(b, p)); break; }                             // FNMSUBS
		default: raise(EX_PROGRAM, 0x80000);
	}
	setfd(RD, v);
	fp_cr1(op);
}

void ppc602::op3f(uint32_t op)
{
	if (sp) { if ((op >> 1) & 0x10) sp_a(op); else sp_x(op); return; }
	double a = fd(RA), b = fd(RB), c = fd(RC_);
	uint32_t sw = (op >> 1) & 0x3ff;
	if (sw & 0x10)
	{
		volatile double p;
		switch (sw & 0x1f)
		{
			case 0x15: setfd(RD, x86_add(a, b)); break;                                                   // FADD
			case 0x14: setfd(RD, x86_sub(a, b)); break;                                                   // FSUB
			case 0x19: setfd(RD, x86_mul(a, c)); break;                                                   // FMUL
			case 0x12: setfd(RD, x86_div(a, b)); break;                                                   // FDIV
			case 0x16: raise(EX_PROGRAM, 0x80000);                                                      // FSQRT: illegal on the 602
			case 0x1a: setfd(RD, rsqrte602(b)); break;                                                  // FRSQRTE: the 602's table
			case 0x17: f[RD] = a >= 0.0 ? f[RC_] : f[RB]; return;                                      // FSEL
			case 0x1d: p = x86_mul(a, c); setfd(RD, x86_add(p, b)); break;                                   // FMADD
			case 0x1c: p = x86_mul(a, c); setfd(RD, x86_sub(p, b)); break;                                   // FMSUB
			case 0x1f: { p = x86_mul(a, c); volatile double s = x86_add(p, b); setfd(RD, -s); break; }       // FNMADD
			case 0x1e: p = x86_mul(a, c); setfd(RD, x86_sub(b, p)); break;                                   // FNMSUB
			default: raise(EX_PROGRAM, 0x80000);
		}
		fp_cr1(op);
		return;
	}
	switch (sw)
	{
		case 0x000: case 0x020:                                                                        // FCMPU, FCMPO
		{
			uint32_t c4 = std::isnan(a) || std::isnan(b) ? 1 : a < b ? 8 : a > b ? 4 : 2;
			cr[CRFD] = c4;
			fpscr = (fpscr & ~0x0000f000u) | (c4 << 12);
			return;
		}
		case 0x00c: setfd(RD, rnds(b)); fp_cr1(op); return;                                            // FRSP
		case 0x00e: f[RD] = fp_to_int(b, false); return;                                               // FCTIW
		case 0x00f: f[RD] = fp_to_int(b, true); return;                                                // FCTIWZ
		case 0x028: f[RD] = f[RB] ^ 0x8000000000000000ull; return;                                     // FNEG
		case 0x048: f[RD] = f[RB]; return;                                                             // FMR
		case 0x088: f[RD] = f[RB] | 0x8000000000000000ull; return;                                     // FNABS
		case 0x108: f[RD] = f[RB] & ~0x8000000000000000ull; return;                                    // FABS
		case 0x046: fpscr &= ~(0x80000000u >> CRBD); if (CRBD >= 30) set_round(); return;              // MTFSB0
		case 0x026: fpscr |= 0x80000000u >> CRBD; if (CRBD >= 30) set_round(); return;                 // MTFSB1
		case 0x040:                                                                                    // MCRFS
			cr[CRFD] = (fpscr >> ((7 - CRFS) * 4)) & 0xf;
			fpscr &= ~crmask(CRFS);
			return;
		case 0x247: f[RD] = (f[RD] & 0xffffffff00000000ull) | fpscr; return;                           // MFFS (MAME's fsmov: the low word)
		case 0x2c7:                                                                                    // MTFSF
		{
			uint32_t m = crf_mask((op >> 17) & 0xff);
			fpscr = (fpscr & ~m) | (uint32_t(f[RB]) & m);
			set_round();
			return;
		}
		case 0x086:                                                                                    // MTFSFI
		{
			uint32_t imm = (op >> 12) & 0xf;
			fpscr = (fpscr & ~crmask(CRFD)) | (rol32(imm, 28 - 4 * CRFD) & crmask(CRFD));
			if (CRFD == 7) set_round();
			return;
		}
	}
	raise(EX_PROGRAM, 0x80000);
}

// ---- the 602's single-precision FPRs (sp), as rtl/ppc_fps.sv and rtl/ppc_pipe.sv have them ------------------------------

static inline bool snanb(uint32_t x) { return (x & 0x7f800000) == 0x7f800000 && (x & 0x007fffff); }
static inline uint32_t squiet(uint32_t x) { return x | 0x00400000; }
static const uint32_t SDNAN = 0x7fc00000;

// stfd's double of a single (exact; a NaN's payload kept)
static uint64_t s2d(uint32_t x)
{
	uint64_t s = uint64_t(x >> 31) << 63;
	if ((x & 0x7f800000) == 0x7f800000) return s | 0x7ff0000000000000ull | (uint64_t(x & 0x7fffff) << 29);
	if (!(x & 0x7fffffff)) return s;
	return dbits(double(bitsf(x)));
}
// back: f holds only what s2d gives
static uint32_t d2s(uint64_t d)
{
	uint32_t s = uint32_t(d >> 63) << 31;
	if (((d >> 52) & 0x7ff) == 0x7ff) return s | 0x7f800000 | uint32_t((d >> 29) & 0x7fffff);
	if (!(d << 1)) return s;
	return fbits(float(bitsd(d)));
}
// lfd's (rtl/ppc_fpu_pkg.sv's d2f): a word under 2^32 an integer (bit 32), else the nearest single (ties to even, whatever
// the mode), under the single normals a zero
static uint64_t d2f33(uint64_t d)
{
	uint32_t e = (d >> 52) & 0x7ff, s = uint32_t(d >> 63) << 31;
	if (!(d >> 32)) return 0x100000000ull | uint32_t(d);
	if (e == 0x7ff)
	{
		uint32_t f = (d >> 29) & 0x7fffff;
		if ((d & 0xfffffffffffffull) && !f) f = 0x400000;
		return s | 0x7f800000 | f;
	}
	if (e <= 896) return s;
	if (e >= 1151) return s | 0x7f800000;
	uint32_t v = ((e - 896) << 23 | uint32_t((d >> 29) & 0x7fffff)) + uint32_t((d >> 28 & 1) && ((d >> 29 & 1) || (d & 0xfffffff)));
	return s | v;
}

uint32_t ppc602::fs(int n) const { return (fint >> n & 1) ? uint32_t(f[n]) : d2s(f[n]); }
void ppc602::setfs(int n, uint32_t v) { f[n] = s2d(v); fint &= ~(1u << n); }
void ppc602::setfi(int n, uint32_t v) { f[n] = v; fint |= 1u << n; }
void ppc602::setf33(int n, uint64_t v) { if (v >> 32 & 1) setfi(n, uint32_t(v)); else setfs(n, uint32_t(v)); }
// (twice: a +0 from a flushed value would load as the integer 0)
void ppc602::sp_canon() { for (int k = 0; k < 2; k++) for (int n = 0; n < 32; n++) setf33(n, d2f33(f[n])); }
void ppc602::ld_fs(int n, uint32_t v) { if (sp) setfs(n, v); else setfd(n, double(bitsf(v))); }
void ppc602::ld_fd(int n, uint64_t v) { if (sp) setf33(n, d2f33(v)); else f[n] = v; }
uint32_t ppc602::st_fs(int n) { return sp ? fs(n) : fbits(float(fd(n))); }
uint32_t ppc602::st_fiw(int n) { return sp ? fs(n) : uint32_t(f[n]); }

// frsqrte as the 602 does it (measured on a Panasonic FZ-35S; the M2 emulator's ppccom_frsqrte_602 and rtl/ppc_fps.sv's rsqrte602):
// a table of 32 estimates, chosen by the exponent's parity and the top 4 mantissa bits, each a 7-bit mantissa; not 1 / sqrt
double rsqrte602(double in)
{
	static const uint8_t table[2][16] = {
		{ 0x7c, 0x75, 0x6e, 0x68, 0x62, 0x5d, 0x58, 0x53, 0x4f, 0x4b, 0x47, 0x43, 0x40, 0x3d, 0x39, 0x36 },
		{ 0x32, 0x2d, 0x28, 0x24, 0x20, 0x1c, 0x19, 0x15, 0x12, 0x0f, 0x0d, 0x0a, 0x08, 0x05, 0x03, 0x01 } };
	uint64_t b, r;
	std::memcpy(&b, &in, sizeof(b));
	const bool neg = b >> 63;
	int exp = int((b >> 52) & 0x7ff);
	uint64_t man = b & 0x000fffffffffffffULL;
	if (exp == 0x7ff)
		r = man ? (b | 0x0008000000000000ULL) : neg ? 0x7ff8000000000000ULL : 0;
	else if (exp == 0 && man == 0)
		r = neg ? 0xfff0000000000000ULL : 0x7ff0000000000000ULL;
	else if (neg)
		r = 0x7ff8000000000000ULL;
	else
	{
		if (exp == 0)
		{
			exp = 1;
			while (!(man & 0x0010000000000000ULL)) { man <<= 1; exp--; }
			man &= 0x000fffffffffffffULL;
		}
		const int e = exp - 1023, p = e & 1;
		r = (uint64_t(-1 - (e - p) / 2 + 1023) << 52) | (uint64_t(table[p][(man >> 48) & 0xf]) << 45);
	}
	double out;
	std::memcpy(&out, &r, sizeof(out));
	return out;
}

// the A-form ops, double forms as the single ones: the host's floats, in the mode, fused; a NaN the unit's (the first NaN
// operand quieted: a then c (the product) before b, b first for fnmsub (b - the product); with none, the default NaN
// 0x7fc00000), fnmadd's negated, its exact zero too (the unit negates the sum before its round: its zero is the sum's negated)
void ppc602::sp_a(uint32_t op)
{
	uint32_t a = fs(RA), b = fs(RB), c = fs(RC_);
	volatile float fa = bitsf(a), fb = bitsf(b), fc = bitsf(c);
	uint32_t v, nan = SDNAN;
	bool neg = false;
	switch ((op >> 1) & 0x1f)
	{
		case 0x15: v = fbits(fa + fb); nan = snanb(a) ? squiet(a) : snanb(b) ? squiet(b) : SDNAN; break;           // FADD(S)
		case 0x14: v = fbits(fa - fb); nan = snanb(a) ? squiet(a) : snanb(b) ? squiet(b) : SDNAN; break;           // FSUB(S)
		case 0x19: v = fbits(fa * fc); nan = snanb(a) ? squiet(a) : snanb(c) ? squiet(c) : SDNAN; break;           // FMUL(S)
		case 0x12: v = fbits(fa / fb); nan = snanb(a) ? squiet(a) : snanb(b) ? squiet(b) : SDNAN; break;           // FDIV(S)
		case 0x16: raise(EX_PROGRAM, 0x80000);                                                                      // FSQRT(S): illegal on the 602
		case 0x18:                                                                                                  // FRES
			if ((op >> 26) != 0x3b) raise(EX_PROGRAM, 0x80000);
			v = fbits(1.0f / fb); nan = snanb(b) ? squiet(b) : SDNAN; break;
		case 0x1a:                                                                                                  // FRSQRTE
		{
			if ((op >> 26) != 0x3f) raise(EX_PROGRAM, 0x80000);
			v = fbits(float(rsqrte602(double(fb)))); nan = snanb(b) ? squiet(b) : SDNAN; break;   // the 602's table (exact as a single)
		}
		case 0x17:                                                                                                  // FSEL
			if ((op >> 26) != 0x3f) raise(EX_PROGRAM, 0x80000);
			if (!std::isnan(fa) && fa >= 0.0f) { f[RD] = f[RC_]; fint = (fint & ~(1u << RD)) | ((fint >> RC_ & 1) << RD); }
			else { f[RD] = f[RB]; fint = (fint & ~(1u << RD)) | ((fint >> RB & 1) << RD); }
			return;
		case 0x1d: case 0x1c: case 0x1f: case 0x1e:                                                                 // the multiply-adds
		{
			uint32_t x = (op >> 1) & 0x1f;
			// (the product: a NaN operand, or infinity times zero the default NaN)
			bool az = !(a & 0x7fffffff), cz = !(c & 0x7fffffff), ai = (a & 0x7fffffff) == 0x7f800000, ci = (c & 0x7fffffff) == 0x7f800000;
			uint32_t pn = snanb(a) ? squiet(a) : snanb(c) ? squiet(c) : (ai && cz) || (az && ci) ? SDNAN : 0, bn = snanb(b) ? squiet(b) : 0;
			nan = x == 0x1e ? (bn ? bn : pn ? pn : SDNAN) : (pn ? pn : bn ? bn : SDNAN);
			if (x == 0x1d) v = fbits(fmaf(fa, fc, fb));
			else if (x == 0x1c) v = fbits(fmaf(fa, fc, -fb));
			else if (x == 0x1e) v = fbits(fmaf(-fa, fc, fb));
			else
			{
				neg = true;
				if (double(fa) * double(fc) + double(fb) == 0.0) v = fbits(fmaf(fa, fc, fb)) ^ 0x80000000u;
				else v = fbits(fmaf(-fa, fc, -fb));
			}
			break;
		}
		default: raise(EX_PROGRAM, 0x80000);
	}
	if (std::isnan(bitsf(v))) v = neg ? nan ^ 0x80000000u : nan;
	setfs(RD, v);
	fp_cr1(op);
}

// the X-form ops: the moves keep an integer's bit; fcmpu / fcmpo, fsel, mtfsf, fctiw[z] read the 32 bits as a single
void ppc602::sp_x(uint32_t op)
{
	uint32_t sw = (op >> 1) & 0x3ff;
	uint32_t b = fs(RB);
	auto mov = [&](uint32_t v) { if (fint >> RB & 1) setfi(RD, v); else setfs(RD, v); };
	switch (sw)
	{
		case 0x000: case 0x020:                                                                        // FCMPU, FCMPO
		{
			float a = bitsf(fs(RA)), fb = bitsf(b);
			uint32_t c4 = std::isnan(a) || std::isnan(fb) ? 1 : a < fb ? 8 : a > fb ? 4 : 2;
			cr[CRFD] = c4;
			fpscr = (fpscr & ~0x0000f000u) | (c4 << 12);
			return;
		}
		case 0x00c: setfs(RD, snanb(b) ? squiet(b) : b); fp_cr1(op); return;                          // FRSP
		case 0x00e: case 0x00f:                                                                        // FCTIW, FCTIWZ
		{
			float v = bitsf(b);
			uint32_t w = 0x80000000u;
			if (!std::isnan(v) && !std::isinf(v))
			{
				double t = sw == 0x00f ? std::trunc(double(v)) : std::nearbyint(double(v));
				if (t < 2147483648.0 && t >= -2147483648.0) w = uint32_t(int32_t(t));
			}
			setfi(RD, w);
			return;
		}
		case 0x028: mov(b ^ 0x80000000u); return;                                                      // FNEG
		case 0x048: mov(b); return;                                                                    // FMR
		case 0x088: mov(b | 0x80000000u); return;                                                      // FNABS
		case 0x108: mov(b & ~0x80000000u); return;                                                     // FABS
		case 0x046: fpscr &= ~(0x80000000u >> CRBD); if (CRBD >= 30) set_round(); return;              // MTFSB0
		case 0x026: fpscr |= 0x80000000u >> CRBD; if (CRBD >= 30) set_round(); return;                 // MTFSB1
		case 0x040:                                                                                    // MCRFS
			cr[CRFD] = (fpscr >> ((7 - CRFS) * 4)) & 0xf;
			fpscr &= ~crmask(CRFS);
			return;
		case 0x247: setfi(RD, fpscr); return;                                                          // MFFS: an integer
		case 0x2c7:                                                                                    // MTFSF
		{
			uint32_t m = crf_mask((op >> 17) & 0xff);
			fpscr = (fpscr & ~m) | (b & m);
			set_round();
			return;
		}
		case 0x086:                                                                                    // MTFSFI
		{
			uint32_t imm = (op >> 12) & 0xf;
			fpscr = (fpscr & ~crmask(CRFD)) | (rol32(imm, 28 - 4 * CRFD) & crmask(CRFD));
			if (CRFD == 7) set_round();
			return;
		}
	}
	raise(EX_PROGRAM, 0x80000);
}
