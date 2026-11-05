// ppc602.h: an instruction-at-a-time model of the PowerPC 602 as MAME 0.289 runs it (cpu/powerpc/ppcdrc.cpp with
// PPCDRC_COMPATIBLE_OPTIONS, as konamim2.cpp sets them): the reference the RTL core is checked against.
//
// Where MAME and the real 602 differ, this follows MAME:
//   * single-precision arithmetic is double-precision steps, then a round to single (PPCDRC_ACCURATE_SINGLES): fmadds is
//     a double multiply, a double add, a round to single; nothing is fused;
//   * frsqrte is 1 / sqrt(x) in double, fres is 1 / x in single;
//   * fctiw[z] out of range or NaN gives 0x80000000;
//   * tlbld / tlbli do nothing; with relocation on, an address no BAT maps is a TLB miss unless HID0's protection-only bit
//     (0x80) is set, where it maps to itself;
//   * no FP-unavailable exception; MSR[POW] doesn't stop the core;
//   * divw / divwu by zero (and 0x80000000 / -1) give 0, CR0 = EQ;
//   * floats are x86 SSE's (MAME's x64 back end): denormals kept (no FTZ / DAZ), a NaN operand comes back quieted (the
//     first if both), an invalid operation gives the default NaN 0xfff8000000000000;
//   * fneg, fmr, fabs, fnabs, fctiw[z] and fsel leave CR1 alone even with Rc.
// MAME skips CR0 / XER[CA] updates no later instruction reads; this model always makes them (see the replay bench).
// FPSCR is kept only as far as the move-to / move-from instructions and the rounding mode need.
#pragma once
#include <cstdint>

struct ppc602_bus
{
	virtual ~ppc602_bus() {}
	// physical addresses; big-endian values
	virtual uint8_t  read8(uint32_t a) = 0;
	virtual uint16_t read16(uint32_t a) = 0;
	virtual uint32_t read32(uint32_t a) = 0;
	virtual uint64_t read64(uint32_t a) = 0;
	virtual void write8(uint32_t a, uint8_t d) = 0;
	virtual void write16(uint32_t a, uint16_t d) = 0;
	virtual void write32(uint32_t a, uint32_t d) = 0;
	virtual void write64(uint32_t a, uint64_t d) = 0;
	virtual uint32_t fetch(uint32_t a) = 0;
};

class ppc602
{
public:
	enum
	{
		EX_NONE = 0, EX_DSI = 3, EX_ISI = 4, EX_EI = 5, EX_ALIGN = 6, EX_PROGRAM = 7, EX_DECREMENT = 9, EX_SYSCALL = 12,
		EX_ITLBMISS = 16, EX_DTLBMISSL = 17, EX_DTLBMISSS = 18
	};

	// MSR
	static constexpr uint32_t MSR_AP = 0x00800000, MSR_SA = 0x00400000, MSR_POW = 0x00040000, MSR_TGPR = 0x00020000,
		MSR_ILE = 0x00010000, MSR_EE = 0x00008000, MSR_PR = 0x00004000, MSR_FP = 0x00002000, MSR_ME = 0x00001000,
		MSR_FE0 = 0x00000800, MSR_SE = 0x00000400, MSR_BE = 0x00000200, MSR_FE1 = 0x00000100, MSR_IP = 0x00000040,
		MSR_IR = 0x00000020, MSR_DR = 0x00000010, MSR_RI = 0x00000002, MSR_LE = 0x00000001;

	// SPR numbers
	enum
	{
		SPR_XER = 1, SPR_LR = 8, SPR_CTR = 9, SPR_DSISR = 18, SPR_DAR = 19, SPR_DEC = 22, SPR_SDR1 = 25, SPR_SRR0 = 26,
		SPR_SRR1 = 27, SPR_SPRG0 = 272, SPR_SPRG3 = 275, SPR_EAR = 282, SPR_TBL_W = 284, SPR_TBU_W = 285, SPR_PVR = 287,
		SPR_IBAT0U = 528, SPR_DBAT0U = 536, SPR_DBAT3L = 543, SPR_DMISS = 976, SPR_DCMP = 977, SPR_HASH1 = 978,
		SPR_HASH2 = 979, SPR_IMISS = 980, SPR_ICMP = 981, SPR_RPA = 982, SPR_TCR = 984, SPR_IBR = 986, SPR_ESASRR = 987,
		SPR_SEBR = 990, SPR_SER = 991, SPR_HID0 = 1008, SPR_HID1 = 1009, SPR_IABR = 1010, SPR_SP = 1021, SPR_LT = 1022,
		SPR_TBL_R = 268, SPR_TBU_R = 269
	};

	static constexpr uint32_t PVR = 0x00050200;

	uint32_t pc = 0xfff00100;
	uint32_t r[32] = {};
	uint64_t f[32] = {};        // the double's bits
	uint8_t cr[8] = {};         // a nibble each: LT GT EQ SO from bit 3 down
	uint32_t xer = 0;           // OV, CA, byte count; SO is xerso
	uint32_t xerso = 0;
	uint32_t msr = MSR_IP;
	uint32_t fpscr = 0;
	uint32_t sr[16] = {};
	uint32_t spr[1024] = {};
	uint32_t tgpr[4] = {};

	// timer values the core can't know (MAME's cycle counts): the bench supplies them
	uint64_t timebase = 0;
	uint32_t decrementer = 0;
	bool timer_read = false;    // set when the last instruction read TB or DEC

	// reservation (lwarx / stwcx.)
	bool reserved = false;
	uint32_t reserved_addr = 0;

	ppc602(ppc602_bus &b) : bus(b) {}
	void reset();

	// Runs one instruction, or takes the exception it raises. Returns the exception taken (EX_NONE if none).
	int step();
	// Takes an asynchronous exception (EX_EI or EX_DECREMENT) before the instruction at pc.
	void interrupt(int ex);

	uint32_t get_cr() const;
	void set_cr(uint32_t v);
	uint32_t get_xer() const { return xer | (xerso << 31); }
	void set_xer(uint32_t v) { xer = v & ~0x80000000u; xerso = v >> 31; }

	uint32_t last_op = 0;
	uint32_t last_pc = 0;

private:
	ppc602_bus &bus;
	struct exc { int ex; uint32_t param; };

	void take(int ex, uint32_t srr0, uint32_t param);
	void swap_tgpr();
	bool translate(uint32_t &a, int type, uint32_t &dsisr);
	uint32_t ea_phys(uint32_t ea, int type);

	uint8_t  rd8(uint32_t ea);
	uint16_t rd16(uint32_t ea);
	uint32_t rd32(uint32_t ea);
	uint64_t rd64(uint32_t ea);
	void wr8(uint32_t ea, uint8_t d);
	void wr16(uint32_t ea, uint16_t d);
	void wr32(uint32_t ea, uint32_t d);
	void wr64(uint32_t ea, uint64_t d);

	void exec(uint32_t op);
	void op13(uint32_t op);
	void op1f(uint32_t op);
	void op3b(uint32_t op);
	void op3f(uint32_t op);

	void cr0(uint32_t res) { cr[0] = (int32_t(res) < 0 ? 8 : res ? 4 : 2) | xerso; }
	void set_ov(bool ov) { if (ov) { xer |= 0x40000000; xerso = 1; } else xer &= ~0x40000000u; }
	void set_ca(bool ca) { if (ca) xer |= 0x20000000; else xer &= ~0x20000000u; }
	bool ca() const { return xer & 0x20000000; }
	void branch(uint32_t target, bool lk);
	bool cond(uint32_t bo, uint32_t bi);

	void set_round();
	double fd(int n) const;
	void setfd(int n, double v);
	void fp_cr1(uint32_t op);

	uint32_t mfspr(uint32_t n);
	void mtspr(uint32_t n, uint32_t v);

	uint32_t next_pc = 0;
	[[noreturn]] void raise(int ex, uint32_t param = 0) { throw exc{ ex, param }; }
};
