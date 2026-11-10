// tb_ppcreplay trace [-rom file] [-ram file -state file] [-max N] [-errors N] [-quiet] [-free lo hi [-hot N] [-lax]]: runs the reference 602 (tools/ref/ppc602) against a MAME
// trace made by work/lua/boot_trace.lua (tools/lua/ppc_trace.lua): before each instruction an "R" line with r0-r31, CR,
// LR, CTR, XER, MSR, SRR0, SRR1, FPSCR, then the instruction, then every data access it made ("MR/MW addr bits data").
//
// Loads are served from a memory built from the logged accesses (and the boot ROM); stores must match the log byte for
// byte; after each instruction the GPRs, LR, CTR, MSR, SRR0 and SRR1 must match the next R line. CR and XER differences
// are counted, not failed: MAME skips CR0 / CA updates nothing reads before they're overwritten, and a wrong live value
// shows up as a wrong branch or GPR. Reads of TB / DEC take MAME's values; external and decrementer interrupts are taken
// where MAME took them. A trace started mid-run needs its RAM dump and its CPU's .state file (FPRs, SRs, SPRGs, SDR1,
// TB, DEC, and the SPRs the breakpoints saw written: "SPR<n> value").
// Built with WITH_RTL (run.sh with RTL=1), the RTL core (rtl/ppc_core.sv) runs each instruction too and must match the
// model exactly: its stores, and every register after each instruction (CR, XER and the FPRs included).
#include "../../tools/ref/ppc602/ppc602.h"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <unordered_map>
#include <vector>

struct maccess { bool w; uint32_t a; int bytes; uint64_t d; };

struct memory : ppc602_bus
{
	std::vector<uint8_t> ram = std::vector<uint8_t>(16 << 20);      // 0x40000000
	std::vector<uint8_t> rom = std::vector<uint8_t>(2 << 20);       // 0x20000000, 0xfff00000
	std::unordered_map<uint32_t, uint8_t> other;
	std::vector<maccess> writes;
	int unknown_reads = 0;
	std::unordered_map<uint32_t, bool> known;                        // non-RAM, non-ROM bytes the log has shown

	uint8_t *ptr(uint32_t a)
	{
		if (a >= 0x40000000 && a < 0x41000000) return &ram[a - 0x40000000];
		if (a >= 0x20000000 && a < 0x20200000) return &rom[a - 0x20000000];
		if (a >= 0xfff00000) return &rom[a - 0xfff00000];
		return nullptr;
	}
	uint8_t get(uint32_t a)
	{
		if (uint8_t *p = ptr(a)) return *p;
		auto it = other.find(a);
		if (it == other.end()) { unknown_reads++; return 0; }
		return it->second;
	}
	void put(uint32_t a, uint8_t v)
	{
		if (uint8_t *p = ptr(a)) *p = v;
		else other[a] = v;
	}
	// a read that isn't an maccess (the RTL bench's)
	uint64_t peek(uint32_t a, int n)
	{
		uint64_t v = 0;
		for (int i = 0; i < n; i++)
		{
			uint8_t *p = ptr(a + i);
			auto it = other.find(a + i);
			v = (v << 8) | (p ? *p : it != other.end() ? it->second : 0);
		}
		return v;
	}
	uint64_t rdn(uint32_t a, int n) { uint64_t v = 0; for (int i = 0; i < n; i++) v = (v << 8) | get(a + i); return v; }
	// -free: every data access the model makes, in order
	std::vector<maccess> *rec = nullptr;
	uint64_t rd(uint32_t a, int n) { uint64_t v = rdn(a, n); if (rec) rec->push_back({ false, a, n, v }); return v; }
	void wrn(uint32_t a, int n, uint64_t v)
	{
		writes.push_back({ true, a, n, v });
		if (rec) rec->push_back({ true, a, n, v });
		for (int i = n - 1; i >= 0; i--) { put(a + i, uint8_t(v)); v >>= 8; }
	}
	uint8_t  read8(uint32_t a) override  { return uint8_t(rd(a, 1)); }
	uint16_t read16(uint32_t a) override { return uint16_t(rd(a, 2)); }
	uint32_t read32(uint32_t a) override { return uint32_t(rd(a, 4)); }
	uint64_t read64(uint32_t a) override { return rd(a, 8); }
	void write8(uint32_t a, uint8_t d) override   { wrn(a, 1, d); }
	void write16(uint32_t a, uint16_t d) override { wrn(a, 2, d); }
	void write32(uint32_t a, uint32_t d) override { wrn(a, 4, d); }
	void write64(uint32_t a, uint64_t d) override { wrn(a, 8, d); }
	uint32_t fetch(uint32_t a) override { return uint32_t(rdn(a, 4)); }
};

struct step
{
	bool have = false;
	uint32_t reg[40];
	uint32_t pc;
	std::string text;
	std::vector<maccess> acc;
};

static const char *REGNAME[40] = {
	"r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15",
	"r16", "r17", "r18", "r19", "r20", "r21", "r22", "r23", "r24", "r25", "r26", "r27", "r28", "r29", "r30", "r31",
	"cr", "lr", "ctr", "xer", "msr", "srr0", "srr1", "fpscr" };

struct reader
{
	FILE *f;
	char line[4096];
	bool pending = false;
	step pre;        // the R line read ahead
	bool eof = false;

	bool getline() { return fgets(line, sizeof line, f) != nullptr; }

	// Reads one instruction: its R line, its PC line, and the accesses up to the next R line.
	bool next(step &s)
	{
		s = step();
		s.acc.clear();
		// find an R line
		while (!pending)
		{
			if (!getline()) return false;
			if (line[0] == 'R' && line[1] == ' ') { parse_r(pre); pending = true; }
		}
		memcpy(s.reg, pre.reg, sizeof s.reg);
		pending = false;
		// the instruction
		if (!getline()) return false;
		s.pc = uint32_t(strtoul(line, nullptr, 16));
		s.text = line;
		while (!s.text.empty() && (s.text.back() == '\n' || s.text.back() == '\r')) s.text.pop_back();
		// accesses, until the next R
		while (getline())
		{
			if (line[0] == 'R' && line[1] == ' ') { parse_r(pre); pending = true; break; }
			if (line[0] == 'M' && (line[1] == 'R' || line[1] == 'W'))
			{
				char *p = line + 3;
				maccess a;
				a.w = line[1] == 'W';
				a.a = uint32_t(strtoul(p, &p, 16));
				a.bytes = int(strtoul(p, &p, 16)) / 8;
				a.d = strtoull(p, &p, 16);
				s.acc.push_back(a);
			}
		}
		s.have = true;
		return true;
	}

	void parse_r(step &s)
	{
		char *p = line + 2;
		for (int i = 0; i < 40; i++)
			s.reg[i] = uint32_t(strtoul(p, &p, 16));
	}
};

static void load_state(ppc602 &c, const uint32_t *reg)
{
	for (int i = 0; i < 32; i++) c.r[i] = reg[i];
	c.set_cr(reg[32]);
	c.spr[ppc602::SPR_LR] = reg[33];
	c.spr[ppc602::SPR_CTR] = reg[34];
	c.set_xer(reg[35]);
	c.msr = reg[36];
	c.spr[ppc602::SPR_SRR0] = reg[37];
	c.spr[ppc602::SPR_SRR1] = reg[38];
	c.fpscr = reg[39];
}

static void get_state(ppc602 &c, uint32_t *reg)
{
	for (int i = 0; i < 32; i++) reg[i] = c.r[i];
	reg[32] = c.get_cr();
	reg[33] = c.spr[ppc602::SPR_LR];
	reg[34] = c.spr[ppc602::SPR_CTR];
	reg[35] = c.get_xer();
	reg[36] = c.msr;
	reg[37] = c.spr[ppc602::SPR_SRR0];
	reg[38] = c.spr[ppc602::SPR_SRR1];
	reg[39] = c.fpscr;
}

#ifdef WITH_RTL
// ---- the RTL core in lockstep (built by run.sh with RTL=1) ---------------------------------------------------------
// It runs each instruction right after the model, on the same memory (no instruction both loads and stores, so the
// model's stores don't change what the RTL reads); its stores aren't made again, only compared with the model's. Between
// instructions it stops at its instruction boundary (dbg_hold), where interrupts and MAME's timer values go in.
// With PIPE (run.sh with RTL=1 PIPE=1) it is the pipeline (rtl/ppc_pipe.sv), one instruction at a time the same way
// (sim/ppccore runs it free), its fetch and data sides answering in a clock. With -free lo hi, the model runs the trace
// first, then the pipeline runs it free-running; its clocks an instruction are counted inside the idle loop [lo, hi] and out.
#ifdef PIPE
#include "Vppc_pipe.h"
typedef Vppc_pipe Vtop;
#else
#include "Vppc_core.h"
typedef Vppc_core Vtop;
#endif
#include "verilated.h"

static const int KEPT[] = { 8, 9, 18, 19, 25, 26, 27, 272, 273, 274, 275, 282, 528, 529, 530, 531, 532, 533, 534, 535,
	536, 537, 538, 539, 540, 541, 542, 543, 976, 977, 978, 979, 980, 981, 982, 984, 986, 987, 990, 991, 1008, 1009, 1010,
	1013, 1021, 1022, 346, 1011 };

struct rtl_core
{
	Vtop t;
	memory &mem;
	std::vector<maccess> writes;
	rtl_core(memory &m) : mem(m) {}

#ifdef PIPE
	bool iout = false, aph = false;   // aph: the access taken last clock, its address clock now
	uint64_t ddata = 0;
	// -free: hold X at this edge when an access (not faulted) is in its address clock (the instruction retiring then is
	// the one before the hold point)
	bool hold_on_access = false;
	// -free: the data side answers with the model's accesses, in order (and they must be the same)
	const std::vector<maccess> *src = nullptr;
	size_t si = 0;
	bool lax = false;                // -lax: a write's data may differ (counted): the 602's singles against MAME's doubles
	uint64_t lax_diff = 0;
	std::string err;
	int perf = 0;                    // what X did this clock (perf_o), at perf_pc
	uint32_t perf_pc = 0;
	void clk()
	{
		t.clk = 0; t.eval();
		t.if_valid = iout;
		if (iout) t.if_data = uint32_t(mem.peek(t.if_pa, 4));
		t.d_valid = 0;
		t.if_rdy = 1; t.d_rdy = 1;
		t.eval();
		// the access in its address clock, answered then
		if (aph && !t.d_kill)
		{
			int n = t.d_size;
			maccess a = { bool(t.d_we), uint32_t(t.d_pa), n, t.d_we ? t.d_wdata & (n == 8 ? ~0ull : (1ull << (8 * n)) - 1) : 0 };
			if (src)
			{
				const maccess *e = si < src->size() ? &(*src)[si] : nullptr;
				if (e && lax && a.w && e->w && e->a == a.a && e->bytes == a.bytes && e->d != a.d) lax_diff++;
				else if (!e || e->w != a.w || e->a != a.a || e->bytes != a.bytes || (a.w && e->d != a.d))
				{
					char b[160];
					snprintf(b, sizeof b, "access %zu: RTL %s %08X %d %llX, model %s %08X %d %llX", si, a.w ? "W" : "R", a.a, n,
						(unsigned long long)a.d, e && e->w ? "W" : "R", e ? e->a : 0, e ? e->bytes : 0, e ? (unsigned long long)e->d : 0ull);
					if (err.empty()) err = b;
				}
				else if (!a.w) ddata = e->d;
				si++;
			}
			else if (a.w) writes.push_back(a);
			else ddata = mem.peek(t.d_pa, n);
			t.d_valid = 1;
			t.d_rdata = ddata;
			if (hold_on_access) t.dbg_hold = 1;
		}
		t.eval();
		perf = t.perf_o;
		perf_pc = t.perf_pc_o;
		iout = t.if_req;
		aph = t.d_req;
		t.clk = 1; t.eval();
	}
#else
	void clk()
	{
		t.clk = 0; t.eval();
		t.bus_ack = t.bus_req;
		if (t.bus_req)
		{
			int n = t.bus_size;
			if (t.bus_we) writes.push_back({ true, uint32_t(t.bus_addr), n, t.bus_wdata & (n == 8 ? ~0ull : (1ull << (8 * n)) - 1) });
			else t.bus_rdata = mem.peek(t.bus_addr, n);
		}
		t.eval();
		t.clk = 1; t.eval();
	}
#endif
	void set(int idx, uint64_t v) { t.dbg_we = 1; t.dbg_idx = idx; t.dbg_val = v; clk(); t.dbg_we = 0; }
	// to the next retire, then back to the boundary (idle: nothing left out)
	bool settle()
	{
		for (int i = 0; i < 2000; i++) { clk(); if (t.dbg_idle) return true; }
		return false;
	}
	bool finish()
	{
		for (int i = 0; i < 2000; i++) { clk(); if (t.retire) return settle(); }
		return false;
	}
	bool run_one()
	{
		writes.clear();
		t.dbg_hold = 0;
		clk();
		t.dbg_hold = 1;
		if (t.retire) return settle();
		return finish();
	}
	bool interrupt(int ex)
	{
		t.dbg_int = ex == ppc602::EX_EI ? 1 : 2;
		clk();
		t.dbg_int = 0;
		return finish();
	}
	void load_regs(const uint32_t *reg, uint32_t pc)
	{
		for (int i = 0; i < 32; i++) set(i, reg[i]);
		set(65, reg[32]); set(1024 + 8, reg[33]); set(1024 + 9, reg[34]); set(66, reg[35]); set(67, reg[36]);
		set(1024 + 26, reg[37]); set(1024 + 27, reg[38]); set(68, reg[39]); set(64, pc);
	}
	void start(const ppc602 &c)
	{
		t.rst = 1; t.dbg_hold = 1; t.dbg_int = 0; t.dbg_we = 0; t.int_ext = 0; t.dec_tick = 0; t.tb_tick = 0;
#ifdef PIPE
		t.if_valid = 0; t.d_valid = 0;
#else
		t.bus_ack = 0;
#endif
		clk();
		for (int i = 0; i < 32; i++) set(32 + i, c.f[i]);
		for (int i = 0; i < 4; i++) set(72 + i, c.tgpr[i]);
		for (int i = 0; i < 16; i++) set(80 + i, c.sr[i]);
		for (int n : KEPT) set(1024 + n, c.spr[n]);
		set(69, c.decrementer); set(70, uint32_t(c.timebase)); set(71, uint32_t(c.timebase >> 32));
		uint32_t reg[40];
		get_state(const_cast<ppc602 &>(c), reg);
		load_regs(reg, c.pc);
		t.rst = 0;
		clk(); clk();
	}
	// the differences from the model, or ""
	std::string diff(const ppc602 &c)
	{
		std::string o;
		char b[128];
		uint32_t st[40];
		get_state(const_cast<ppc602 &>(c), st);
		uint32_t rs[40];
		for (int i = 0; i < 32; i++) rs[i] = t.gpr_o[i];
		rs[32] = t.cr_o; rs[33] = t.lr_o; rs[34] = t.ctr_o; rs[35] = t.xer_o; rs[36] = t.msr_o; rs[37] = t.srr0_o;
		rs[38] = t.srr1_o; rs[39] = t.fpscr_o;
		for (int i = 0; i < 40; i++)
			if (rs[i] != st[i]) { snprintf(b, sizeof b, "   %-5s model %08X  RTL %08X\n", REGNAME[i], st[i], rs[i]); o += b; }
		if (t.pc_o != c.pc) { snprintf(b, sizeof b, "   pc    model %08X  RTL %08X\n", c.pc, uint32_t(t.pc_o)); o += b; }
		for (int i = 0; i < 32; i++)
		{
			uint64_t f = uint64_t(t.fpr_o[2 * i]) | (uint64_t(t.fpr_o[2 * i + 1]) << 32);
			if (f != c.f[i]) { snprintf(b, sizeof b, "   f%-4d model %016llX  RTL %016llX\n", i, (unsigned long long)c.f[i], (unsigned long long)f); o += b; }
		}
		return o;
	}
};
#endif

int main(int argc, char **argv)
{
	if (argc < 2) { fprintf(stderr, "usage: tb_ppcreplay trace [-rom file] [-ram file -state file] [-max N] [-errors N] [-quiet]\n"); return 2; }
	const char *tracefile = argv[1], *romfile = nullptr, *ramfile = nullptr, *statefile = nullptr;
	uint64_t maxn = ~0ull;
	int maxerr = 10;
	bool quiet = false;
	bool freerun = false, lax = false;
	int hot = 0;                        // -hot N: the N instructions losing the most clocks, by cause
	uint32_t idle_lo = 1, idle_hi = 0;
	for (int i = 2; i < argc; i++)
	{
		if (!strcmp(argv[i], "-rom") && i + 1 < argc) romfile = argv[++i];
		else if (!strcmp(argv[i], "-ram") && i + 1 < argc) ramfile = argv[++i];
		else if (!strcmp(argv[i], "-state") && i + 1 < argc) statefile = argv[++i];
		else if (!strcmp(argv[i], "-max") && i + 1 < argc) maxn = strtoull(argv[++i], nullptr, 0);
		else if (!strcmp(argv[i], "-errors") && i + 1 < argc) maxerr = atoi(argv[++i]);
		else if (!strcmp(argv[i], "-quiet")) quiet = true;
		else if (!strcmp(argv[i], "-free") && i + 2 < argc)
		{
			freerun = true;
			idle_lo = uint32_t(strtoul(argv[++i], nullptr, 16));
			idle_hi = uint32_t(strtoul(argv[++i], nullptr, 16));
		}
		else if (!strcmp(argv[i], "-hot") && i + 1 < argc) hot = atoi(argv[++i]);
		else if (!strcmp(argv[i], "-lax")) lax = true;
	}
	memory mem;
	if (romfile)
	{
		FILE *rf = fopen(romfile, "rb");
		if (!rf) { perror(romfile); return 2; }
		size_t n = fread(mem.rom.data(), 1, mem.rom.size(), rf);
		fclose(rf);
		if (!quiet) printf("boot ROM: %zu bytes\n", n);
	}
	if (ramfile)
	{
		FILE *rf = fopen(ramfile, "rb");
		if (!rf) { perror(ramfile); return 2; }
		size_t n = fread(mem.ram.data(), 1, mem.ram.size(), rf);
		fclose(rf);
		if (!quiet) printf("RAM: %zu bytes\n", n);
	}
	reader rd;
	rd.f = fopen(tracefile, "r");
	if (!rd.f) { perror(tracefile); return 2; }

	ppc602 cpu(mem);
	cpu.reset();
	step cur, nxt;
	if (!rd.next(cur)) { fprintf(stderr, "empty trace\n"); return 2; }
	if (statefile)
	{
		FILE *sf = fopen(statefile, "r");
		if (!sf) { perror(statefile); return 2; }
		char name[64], val[64];
		uint64_t tbl = 0, tbh = 0;
		while (fscanf(sf, "%63s %63s", name, val) == 2)
		{
			uint64_t v = strtoull(val, nullptr, 16);
			int k;
			if (sscanf(name, "SPRG%d", &k) == 1) cpu.spr[ppc602::SPR_SPRG0 + k] = uint32_t(v);
			else if (sscanf(name, "SPR%d", &k) == 1 && k >= 0 && k < 1024) cpu.spr[k] = uint32_t(v);
			else if (sscanf(name, "SR%d", &k) == 1 && k >= 0 && k < 16 && strncmp(name, "SRR", 3)) cpu.sr[k] = uint32_t(v);
			else if (name[0] == 'F' && sscanf(name + 1, "%d", &k) == 1 && k >= 0 && k < 32) cpu.f[k] = v;
			else if (!strcmp(name, "SDR1")) cpu.spr[ppc602::SPR_SDR1] = uint32_t(v);
			else if (!strcmp(name, "DEC")) cpu.decrementer = uint32_t(v);
			else if (!strcmp(name, "TBL")) tbl = v;
			else if (!strcmp(name, "TBH")) tbh = v;
		}
		fclose(sf);
		cpu.timebase = (tbh << 32) | uint32_t(tbl);
	}
	load_state(cpu, cur.reg);
	cpu.pc = cur.pc;
#ifdef WITH_RTL
	rtl_core *rtl = new rtl_core(mem);
	rtl->start(cpu);
	uint64_t rtl_errors = 0;
	// in lockstep, or (-free) the model alone first, recording what the free run needs
	bool lock = !freerun;
	struct irq_at { uint64_t n; int ex; };                 // before instruction n
	struct timer_at { uint64_t n; uint32_t rd, v; };       // after instruction n: rD is MAME's v
	std::vector<uint32_t> rec_pc;
	std::vector<maccess> rec_acc;
	std::vector<irq_at> rec_irq;
	std::vector<timer_at> rec_tmr;
	if (freerun) mem.rec = &rec_acc;
#define RTL(x) do { if (lock) { x; } } while (0)
#define REC(x) do { if (freerun) { x; } } while (0)
#else
#define RTL(x)
#define REC(x)
#endif

	uint64_t n = 0, repeats = 0, cr_diff = 0, xer_diff = 0, fpscr_diff = 0, irqs = 0, exceptions = 0, timer_reads = 0;
	int errors = 0;
	std::unordered_map<uint32_t, uint64_t> cr_diff_pcs;
	bool more = true;
	while (more && n < maxn)
	{
		more = rd.next(nxt);
		// the logged reads feed the memory before the instruction runs (they include the recompiler's fetches)
		for (auto &a : cur.acc)
			if (!a.w)
			{
				uint64_t v = a.d;
				for (int i = a.bytes - 1; i >= 0; i--) { mem.put(a.a + i, uint8_t(v)); v >>= 8; }
			}
		// an interrupt MAME took here
		if (cpu.pc != cur.pc)
		{
			uint32_t base = (cur.reg[36] & ppc602::MSR_IP) ? 0xfff00000 : cpu.spr[ppc602::SPR_IBR];
			if ((cur.pc == (base | 0x500) || cur.pc == (base | 0x900)) && cur.reg[37] == cpu.pc)
			{
				cpu.interrupt(cur.pc == (base | 0x500) ? ppc602::EX_EI : ppc602::EX_DECREMENT);
				RTL(rtl->interrupt(cur.pc == (base | 0x500) ? ppc602::EX_EI : ppc602::EX_DECREMENT));
				REC(rec_irq.push_back({ n, cur.pc == (base | 0x500) ? ppc602::EX_EI : ppc602::EX_DECREMENT }));
				irqs++;
			}
		}
		if (cpu.pc != cur.pc)
		{
			printf("ERROR at instruction %llu: pc %08X, MAME's %08X (%s)\n", (unsigned long long)n, cpu.pc, cur.pc, cur.text.c_str());
			if (++errors >= maxerr) break;
			load_state(cpu, cur.reg);
			cpu.pc = cur.pc;
			RTL(rtl->load_regs(cur.reg, cur.pc));
		}
		// MAME's hook fires again when the recompiler leaves a block and comes back to the same instruction: the same pc,
		// nothing changed, nothing stored
		if (more && nxt.pc == cur.pc && !memcmp(nxt.reg, cur.reg, sizeof cur.reg) &&
			std::none_of(cur.acc.begin(), cur.acc.end(), [](const maccess &a) { return a.w; }))
		{
			repeats++;
			std::swap(cur, nxt);
			continue;
		}
		mem.writes.clear();
		REC(rec_pc.push_back(cpu.pc));
		int ex = cpu.step();
		if (ex) exceptions++;
		n++;
#ifdef WITH_RTL
		// the RTL's stores against the model's: the same accesses in the same order
		bool rtl_ran = !lock || rtl->run_one();
		bool rtl_st = !lock || rtl->writes.size() == mem.writes.size();
		for (size_t k = 0; k < rtl->writes.size() && rtl_st; k++)
			rtl_st = rtl->writes[k].a == mem.writes[k].a && rtl->writes[k].bytes == mem.writes[k].bytes && rtl->writes[k].d == mem.writes[k].d;
		if (!rtl_ran || !rtl_st)
		{
			printf("RTL ERROR at instruction %llu, %s: %s\n", (unsigned long long)n - 1, cur.text.c_str(), rtl_ran ? "stores differ" : "no retire");
			for (auto &a : mem.writes) printf("   model %08X %d %llX\n", a.a, a.bytes, (unsigned long long)a.d);
			for (auto &a : rtl->writes) printf("   RTL   %08X %d %llX\n", a.a, a.bytes, (unsigned long long)a.d);
			rtl_errors++;
			if (++errors >= maxerr) break;
		}
#endif
		// stores against the log: compare bytes
		std::unordered_map<uint32_t, uint8_t> want, got;
		for (auto &a : cur.acc)
			if (a.w) { uint64_t v = a.d; for (int i = a.bytes - 1; i >= 0; i--) { want[a.a + i] = uint8_t(v); v >>= 8; } }
		for (auto &a : mem.writes)
			{ uint64_t v = a.d; for (int i = a.bytes - 1; i >= 0; i--) { got[a.a + i] = uint8_t(v); v >>= 8; } }
		bool store_bad = want.size() != got.size();
		if (!store_bad)
			for (auto &kv : want)
			{
				auto it = got.find(kv.first);
				if (it == got.end() || it->second != kv.second) { store_bad = true; break; }
			}
		if (store_bad)
		{
			printf("ERROR at instruction %llu, %s: stores differ\n", (unsigned long long)n - 1, cur.text.c_str());
			for (auto &a : cur.acc) if (a.w) printf("   MAME  %08X %d %llX\n", a.a, a.bytes, (unsigned long long)a.d);
			for (auto &a : mem.writes) printf("   model %08X %d %llX\n", a.a, a.bytes, (unsigned long long)a.d);
			// MAME's stores stand
			for (auto &kv : want) mem.put(kv.first, kv.second);
			if (++errors >= maxerr) break;
		}
		if (!more) break;
		if (cpu.timer_read)
		{
			// the destination of mftb / mfspr DEC: MAME's value
			uint32_t rdn = (cpu.last_op >> 21) & 31;
			cpu.r[rdn] = nxt.reg[rdn];
			RTL(rtl->set(rdn, nxt.reg[rdn]));
			REC(rec_tmr.push_back({ n - 1, rdn, nxt.reg[rdn] }));
			timer_reads++;
		}
		// an interrupt MAME took straight after this instruction (one that set MSR[EE], or a block's end)
		if (cpu.pc != nxt.pc)
		{
			uint32_t base = (cpu.msr & ppc602::MSR_IP) ? 0xfff00000 : cpu.spr[ppc602::SPR_IBR];
			if ((nxt.pc == (base | 0x500) || nxt.pc == (base | 0x900)) && nxt.reg[37] == cpu.pc)
			{
				cpu.interrupt(nxt.pc == (base | 0x500) ? ppc602::EX_EI : ppc602::EX_DECREMENT);
				RTL(rtl->interrupt(nxt.pc == (base | 0x500) ? ppc602::EX_EI : ppc602::EX_DECREMENT));
				REC(rec_irq.push_back({ n, nxt.pc == (base | 0x500) ? ppc602::EX_EI : ppc602::EX_DECREMENT }));
				irqs++;
			}
		}
		uint32_t st[40];
		get_state(cpu, st);
#ifdef WITH_RTL
		// the RTL against the model
		std::string rd = lock ? rtl->diff(cpu) : "";
		if (!rd.empty())
		{
			printf("RTL ERROR at instruction %llu, %s\n%s", (unsigned long long)n - 1, cur.text.c_str(), rd.c_str());
			rtl_errors++;
			if (++errors >= maxerr) break;
			for (int i = 0; i < 32; i++) rtl->set(32 + i, cpu.f[i]);
			rtl->load_regs(st, cpu.pc);
		}
#endif
		bool bad = cpu.pc != nxt.pc;
		for (int i = 0; i < 40; i++)
		{
			if (st[i] == nxt.reg[i]) continue;
			if (i == 32) { cr_diff++; cr_diff_pcs[cur.pc]++; continue; }
			if (i == 35) { xer_diff++; continue; }
			if (i == 39) { fpscr_diff++; continue; }
			bad = true;
		}
		if (bad)
		{
			printf("ERROR at instruction %llu, %s\n", (unsigned long long)n - 1, cur.text.c_str());
			if (cpu.pc != nxt.pc) printf("   pc   model %08X  MAME %08X (%s)\n", cpu.pc, nxt.pc, "next");
			for (int i = 0; i < 40; i++)
				if (st[i] != nxt.reg[i] && i != 32 && i != 35 && i != 39)
					printf("   %-5s model %08X  MAME %08X  (before %08X)\n", REGNAME[i], st[i], nxt.reg[i], cur.reg[i]);
			if (++errors >= maxerr) break;
			load_state(cpu, nxt.reg);
			cpu.pc = nxt.pc;
			RTL(rtl->load_regs(nxt.reg, nxt.pc));
		}
		else
		{
			// the model's CR and XER stand (a wrong live value shows as a wrong branch or GPR later); FPSCR is MAME's,
			// as the model keeps only part of it
			cpu.fpscr = nxt.reg[39];
#ifdef WITH_RTL
			if (lock && rtl->t.fpscr_o != cpu.fpscr) rtl->set(68, cpu.fpscr);
#endif
		}
		std::swap(cur, nxt);
	}
	printf("%llu instructions (%llu repeated hooks skipped), %d errors; %llu interrupts taken, %llu exceptions, %llu timer reads; "
		"CR differs after %llu, XER after %llu, FPSCR after %llu; %d reads of unlogged addresses\n",
		(unsigned long long)n, (unsigned long long)repeats, errors, (unsigned long long)irqs, (unsigned long long)exceptions,
		(unsigned long long)timer_reads, (unsigned long long)cr_diff, (unsigned long long)xer_diff,
		(unsigned long long)fpscr_diff, mem.unknown_reads);
#ifdef WITH_RTL
	if (lock) printf("RTL: %llu errors against the model\n", (unsigned long long)rtl_errors);
#endif
#if defined(WITH_RTL) && defined(PIPE)
	// -free: the pipeline from the same start, free-running, against what the model did: the same instructions in order,
	// the same data accesses (it gets the model's read data); held only where MAME took an interrupt or gave a timer
	// value. Its clocks (the free ones), inside the idle loop [idle_lo, idle_hi] and outside.
	if (freerun && !errors)
	{
		Vtop &t = rtl->t;
		rtl->src = &rec_acc;
		rtl->lax = lax;
		uint64_t k = 0, cyc = 0, last = 0, cyc_in = 0, cyc_out = 0, ins_in = 0, ins_out = 0;
		uint64_t why[9] = {};             // outside the idle loop: the clocks by what X did (perf_o)
		std::map<uint32_t, uint64_t> lost[9];   // ... by the instruction in X
		bool in_idle = false;
		size_t ii = 0, ti = 0;
		std::string err;
		while (k < rec_pc.size() && err.empty())
		{
			if (ii < rec_irq.size() && rec_irq[ii].n == k)
			{
				// held at the boundary before instruction k: the interrupt
				t.dbg_hold = 1;
				if (!rtl->settle() || !rtl->interrupt(rec_irq[ii].ex)) err = "no interrupt";
				ii++;
				continue;
			}
			t.dbg_hold = 0;
			// an interrupt before the next instruction but one: if the next is an access, X mustn't take the one after
			rtl->hold_on_access = ii < rec_irq.size() && rec_irq[ii].n == k + 1;
			rtl->clk();
			rtl->hold_on_access = false;
			cyc++;
			if (rtl->perf != 1) in_idle = rtl->perf_pc >= idle_lo && rtl->perf_pc <= idle_hi;
			if (!in_idle && rtl->perf < 9) { why[rtl->perf]++; if (hot && rtl->perf > 1) lost[rtl->perf][rtl->perf_pc]++; }
			if (!rtl->err.empty()) { err = rtl->err; break; }
			if (cyc - last > 100000) { err = "no retire"; break; }
			if (!t.retire) continue;
			if (t.retire2)
			{
				// an access, then the instruction after it (the clocks go to the first)
				if (t.ipc0_o != rec_pc[k] || k + 1 >= rec_pc.size() || (ti < rec_tmr.size() && rec_tmr[ti].n == k) ||
					(ii < rec_irq.size() && rec_irq[ii].n == k + 1))
				{
					char b[128];
					snprintf(b, sizeof b, "instruction %llu: RTL %08X and the next, model %08X", (unsigned long long)k,
						uint32_t(t.ipc0_o), rec_pc[k]);
					err = b;
					break;
				}
				if (t.ipc0_o >= idle_lo && t.ipc0_o <= idle_hi) { cyc_in += cyc - last; ins_in++; }
				else { cyc_out += cyc - last; ins_out++; }
				last = cyc;
				k++;
			}
			if (t.ipc_o != rec_pc[k])
			{
				char b[96];
				snprintf(b, sizeof b, "instruction %llu: RTL %08X, model %08X", (unsigned long long)k, uint32_t(t.ipc_o), rec_pc[k]);
				err = b;
				break;
			}
			if (t.ipc_o >= idle_lo && t.ipc_o <= idle_hi) { cyc_in += cyc - last; ins_in++; }
			else { cyc_out += cyc - last; ins_out++; }
			last = cyc;
			k++;
			if (ti < rec_tmr.size() && rec_tmr[ti].n == k - 1)
			{
				// MAME's timer value, before anything reads it
				t.dbg_hold = 1;
				if (!rtl->settle()) err = "not idle";
				rtl->set(rec_tmr[ti].rd, rec_tmr[ti].v);
				ti++;
			}
			if (ii < rec_irq.size() && rec_irq[ii].n == k) t.dbg_hold = 1;
		}
		if (!err.empty()) printf("free run ERROR after %llu instructions: %s\n", (unsigned long long)k, err.c_str());
		printf("free run: %llu instructions, %llu clocks (%.3f an instruction); outside the idle loop %llu in %llu (%.3f), "
			"inside %llu in %llu (%.3f); %zu accesses\n", (unsigned long long)k, (unsigned long long)cyc, k ? double(cyc) / k : 0.0,
			(unsigned long long)ins_out, (unsigned long long)cyc_out, ins_out ? double(cyc_out) / ins_out : 0.0,
			(unsigned long long)ins_in, (unsigned long long)cyc_in, ins_in ? double(cyc_in) / ins_in : 0.0, rtl->si);
		if (lax) printf("writes of other data (-lax): %llu\n", (unsigned long long)rtl->lax_diff);
		static const char *WHY[9] = { "ran", "no instruction", "GPR load", "FPR load/move", "FPR float op", "float unit busy",
			"access out", "multi-clock", "held" };
		printf("outside the idle loop, by clock:");
		for (int i = 0; i < 9; i++) if (why[i]) printf(" %s %llu;", WHY[i], (unsigned long long)why[i]);
		printf("\n");
		for (int i = 2; i < 9 && hot; i++)
		{
			if (lost[i].empty()) continue;
			std::vector<std::pair<uint64_t, uint32_t>> v;
			for (auto &kv : lost[i]) v.push_back({ kv.second, kv.first });
			std::sort(v.rbegin(), v.rend());
			printf("  %s:", WHY[i]);
			for (size_t j = 0; j < v.size() && j < size_t(hot); j++) printf(" %08X(%llu)", v[j].second, (unsigned long long)v[j].first);
			printf("\n");
		}
		if (!err.empty()) errors++;
	}
#endif
	if (cr_diff && !quiet)
	{
		std::vector<std::pair<uint64_t, uint32_t>> v;
		for (auto &kv : cr_diff_pcs) v.push_back({ kv.second, kv.first });
		std::sort(v.rbegin(), v.rend());
		printf("CR differs most after:");
		for (size_t i = 0; i < v.size() && i < 8; i++) printf(" %08X(%llu)", v[i].second, (unsigned long long)v[i].first);
		printf("\n");
	}
	return errors ? 1 : 0;
}
