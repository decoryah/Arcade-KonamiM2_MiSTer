// tb_te.cpp: the Triangle Engine against MAME. For each dump number given: RAM and the registers as they were before MAME ran a list
// (work/lua/te_dump.lua), the list run, and every byte it wrote compared with the same place in dump k+1 (a list runs inside its
// start in MAME, so that's what it made). Bytes MAME's list changed and this one didn't can't be told from what the CPU did since, so those
// are only counted, by 64 KB page. TRAM isn't dumped: it stays from the dump before.
//
//   tb_te [-d dir] [-slow] [-ppm prefix] [-v] k [k ...]
#include "Vm2_te.h"
#include "verilated.h"
#ifdef TE_PROF
#include "Vm2_te___024root.h"
#endif
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <deque>
#include <map>
#include <algorithm>

static const uint32_t RAM_BASE = 0x40000000, RAM_SIZE = 0x1000000;
static std::vector<uint8_t> ram, wrote;
static Vm2_te *t;
static uint64_t clocks;
static bool slow;
static uint32_t rnd = 12345;
static uint32_t rn() { rnd = rnd * 1103515245 + 12345; return rnd >> 16; }

static uint64_t rd64(uint32_t a)
{
	uint32_t o = (a - RAM_BASE) & (RAM_SIZE - 1) & ~7u;
	uint64_t v = 0;
	for (int i = 0; i < 8; i++) v |= uint64_t(ram[o + i]) << (8 * i);
	return v;
}

// memory: reads answered in order after a latency; a read is 4 words
struct Rd { uint32_t a; int beat; uint64_t at; };
static std::deque<Rd> rq;
static uint64_t writes, reads;
#ifdef TE_PROF
static uint64_t st_n[128];
static const char *st_name[] = { "I_STOP", "I_FLUSH", "I_FETCH", "I_REGS", "I_REGW", "I_AFTER", "T_LOAD", "T_MM",
	"V_NEXT", "V_FIELD", "V_DONE",
	"S_SORT", "S_AR", "S_FD", "S_FDE", "S_DIV0", "S_DIV1", "S_DIV2", "S_XYS", "S_FC",
	"S_ATTR", "S_Q1", "S_Q2", "S_Q3", "S_Q4", "S_OP", "S_FX1", "S_JOB",
	"E_START", "E_NEXT",
	"P_RUN" };
static const int P_RUN_N = int(sizeof st_name / sizeof *st_name) - 1;
static uint64_t stalled;
static uint64_t p_bil, p_pt, p_u0, p_v0, p_both, p_pt_go, p_go, p_hold, p_ser, p_drain, p_zr, p_zw, p_cr, p_cw, p_stall;
static uint64_t f_list, f_pix, e_wpix, e_wdrain;
static uint64_t cx_clk, cx_emit_run, cx_emit_str, cx_ctl, cx_nosrc;  // (TE_PROF: compressed loads' clocks: texels from runs, from strings, control bytes, waiting for source)
static std::map<unsigned, uint64_t> cx_bits;
static std::map<std::string, uint64_t> cc_why;    // (TE_PROF: the color cache's state in the clocks pixels stall on it)                          // (texels by their bits and the group's fields: colour bits, alpha bits, ssb)
static std::map<unsigned, uint64_t> regw_n;          // (TE_PROF: the list's register writes, by byte offset)
static std::map<unsigned, uint64_t> regh_n, regh_w;  // (TE_PROF: register instructions by offset << 8 | count: how many, the clocks they waited for the pixels)  // I_FETCH waiting for the list's word, for the pixels; E_START for the walk, for the drain
#endif

#ifdef Z_SDRAM
// The Z buffer's SDRAM (built with -DZ_SDRAM, the core's Z_SDRAM): a 32 MB chip at the pins of rtl/m2_zmem.sv, on clk_mem (twice clk). It takes a
// command at the clock's falling edge (the PLL's shifted clock), and a READ's word is on DQ for the controller's edge ZCAP after the one that
// sent the READ (4: CL3 and the board's delays; env ZCAP). Checked: the commands' order and spacing (tRCD, tRP, tRAS, tRC, tRFC, the refresh
// interval), DQ driven for a WRITE. env ZLATE=1 sets the controller's read a clock later.
static std::vector<uint8_t> zram(1u << 25);
static uint64_t zreads, zwrites, mc, zerrs;
static int zenv(const char *n, int d) { const char *s = getenv(n); return s ? atoi(s) : d; }
static const int ZCAP = zenv("ZCAP", 4);
struct ZBank { bool open; uint32_t row; int64_t t_act, t_pre; };
static ZBank zb[4] = { { false, 0, -100, -100 }, { false, 0, -100, -100 }, { false, 0, -100, -100 }, { false, 0, -100, -100 } };
static int64_t z_ref = -1, z_reft = -100;
static bool z_mode;
static uint16_t z_rd[64];
static bool z_rv[64];
static void zerr(const char *what)
{
	if (zerrs++ < 20) printf("  SDRAM: %s at mem clock %llu\n", what, (unsigned long long)mc);
}
// the chip's clock edge: the command the controller's last edge (mc) sent
static void chip_edge()
{
	int c = (t->sd_nras << 2) | (t->sd_ncas << 1) | t->sd_nwe;
	int64_t n = int64_t(mc);
	unsigned a = t->sd_a, ba = t->sd_ba;
	ZBank &k = zb[ba];
	switch (c)
	{
	case 7: break;
	case 3: // ACTIVE
		if (!z_mode) zerr("ACTIVE before the mode's set");
		if (k.open) zerr("ACTIVE on an open bank");
		if (n - k.t_pre < 3) zerr("tRP");
		if (n - k.t_act < 8) zerr("tRC");
		if (n - z_reft < 9) zerr("tRFC");
		k.open = true; k.row = a; k.t_act = n;
		break;
	case 5: case 4: // READ, WRITE
	{
		if (!k.open) { zerr("READ or WRITE on a closed bank"); break; }
		if (n - k.t_act < 3) zerr("tRCD");
		uint32_t ad = (k.row << 12) | (ba << 10) | ((a & 0x1ff) << 1);
		if (c == 5)
		{
			z_rd[(n + ZCAP) & 63] = uint16_t(zram[ad] | (zram[ad + 1] << 8));
			z_rv[(n + ZCAP) & 63] = true;
			zreads++;
		}
		else
		{
			if (!t->sd_dq_oe) zerr("WRITE without DQ driven");
			if (!(t->sd_dqm & 1)) zram[ad] = uint8_t(t->sd_dq_o);
			if (!(t->sd_dqm & 2)) zram[ad + 1] = uint8_t(t->sd_dq_o >> 8);
			zwrites++;
			static FILE *fzl = getenv("TE_ZL") ? fopen(getenv("TE_ZL"), "w") : nullptr;
			if (fzl) fprintf(fzl, "W %07x %llu\n", ad, (unsigned long long)mc);
		}
		if (a & 0x400)
		{
			// auto precharge: from the end of the burst of 1, after tWR for a write
			k.open = false;
			k.t_pre = n + (c == 4 ? 3 : 1);
			if (k.t_pre - k.t_act < 6) zerr("tRAS");
		}
		break;
	}
	case 2: // PRECHARGE
		for (int i = 0; i < 4; i++)
			if ((a & 0x400) || unsigned(i) == ba)
			{
				if (zb[i].open && n - zb[i].t_act < 6) zerr("tRAS");
				zb[i].open = false; zb[i].t_pre = n;
			}
		break;
	case 1: // AUTO REFRESH
		for (int i = 0; i < 4; i++)
		{
			if (zb[i].open) zerr("REFRESH with a bank open");
			if (n - zb[i].t_pre < 3) zerr("REFRESH: tRP");
		}
		if (n - z_reft < 9) zerr("tRFC");
		if (z_mode && z_ref >= 0 && n - z_ref > 1040) zerr("refresh late");
		z_ref = z_reft = n;
		break;
	case 0: // LOAD MODE
		if (a != 0x030) zerr("mode not burst 1, CL3");
		z_mode = true;
		break;
	default: zerr("unknown command");
	}
}
// the controller's edges: what's on DQ for it, then the edge
static void mem_edge()
{
	t->sd_dq_i = z_rv[(mc + 1) & 63] ? z_rd[(mc + 1) & 63] : 0xdead;
	z_rv[(mc + 1) & 63] = false;
	t->clk_mem = 1;
}
#endif

static void clock1()
{
	// what the bench shows this clock
	bool busy = slow ? (rn() & 3) != 0 : (rn() & 7) == 0;
	t->m_busy = busy;
	t->m_ready = 0;
	if (!rq.empty() && clocks >= rq.front().at)
	{
		Rd &r = rq.front();
		t->m_ready = 1;
		t->m_dout = rd64(r.a + r.beat * 8);
		if (++r.beat == 4) rq.pop_front();
	}
#ifdef Z_SDRAM
	t->clk_mem = 0;
	t->sd_late = getenv("ZLATE") != nullptr;
#endif
	t->clk = 0; t->eval();
#ifdef Z_SDRAM
	chip_edge();
#endif
	if (!busy)
	{
		if (t->m_rd)
		{
			reads++;
			rq.push_back({ uint32_t(t->m_a) << 3, 0, clocks + (slow ? 30 : 12) });
		}
		else if (t->m_we)
		{
			writes++;
			uint32_t o = ((uint32_t(t->m_a) << 3) - RAM_BASE);
			if (o >= RAM_SIZE) printf("write out of RAM %08x at clock %llu\n", uint32_t(t->m_a) << 3, (unsigned long long)clocks);
			else
				for (int i = 0; i < 8; i++)
					if ((t->m_be >> i) & 1)
					{
						uint8_t b = uint8_t(t->m_wd >> (8 * i));
						if (ram[o + i] != b) wrote[o + i] = 1;
						ram[o + i] = b;
					}
		}
	}
#ifdef Z_SDRAM
	mem_edge();
#endif
	t->clk = 1; t->eval();
#ifdef Z_SDRAM
	mc++;
	// the second half: clk_mem's falling edge (the chip's), its next rising edge
	t->clk_mem = 0; t->eval();
	chip_edge();
	mem_edge(); t->eval();
	mc++;
#endif
#ifdef TE_PROF
	st_n[t->rootp->m2_te__DOT__st & 127]++;
	if (t->rootp->m2_te__DOT__w_on) st_n[P_RUN_N]++;   // (the walk, beside the setup's states)
#ifdef TE_PROF
	{
		auto *q = t->rootp;
		if (!strcmp(st_name[q->m2_te__DOT__st & 127], "I_FETCH"))
		{
			if (!q->m2_te__DOT__f_ok) f_list++;
			else if (!(q->m2_te__DOT__f_w >> 28 == 2 && (q->m2_te__DOT__f_w >> 24 & 15) == 0))
			{
				unsigned h = (unsigned(q->m2_te__DOT__f_w) & 0xffff) << 8 | (unsigned(q->m2_te__DOT__f_w) >> 16 & 0xff);
				static uint64_t last_irp = ~0ull;
				if (q->m2_te__DOT__f_w >> 28 == 1)
				{
					if (q->m2_te__DOT__gc_irp != last_irp) regh_n[h]++;
					last_irp = q->m2_te__DOT__gc_irp;
					if (q->m2_te__DOT__w_on || q->m2_te__DOT__p_any) regh_w[h]++;
				}
				f_pix++;
			}
		}
		if (!strcmp(st_name[q->m2_te__DOT__st & 127], "I_REGW"))
		{
			regw_n[unsigned(q->m2_te__DOT__ls_a) << 2]++;
			if ((unsigned(q->m2_te__DOT__ls_a) << 2) == 0x14) regw_n[0x100000 | (unsigned(q->m2_te__DOT__dc_new) & 0x3f)]++;  // (the list control's: what it asks)
		}
		if (!strcmp(st_name[q->m2_te__DOT__st & 127], "T_MM") && q->m2_te__DOT__mm_cmp && q->m2_te__DOT__mm_n)
		{
			cx_clk++;
			if (!q->m2_te__DOT__cx_grp) cx_ctl++;
			else if (q->m2_te__DOT__cx_have && !q->m2_te__DOT__cx_str) cx_emit_run++;
			else if (q->m2_te__DOT__cx_n < 8 && !q->m2_te__DOT__cx_word) cx_nosrc++;
			else cx_emit_str++;
			if (q->m2_te__DOT__cx_pe) cx_bits[unsigned(q->m2_te__DOT__cx_dbits) << 16 | unsigned(q->m2_te__DOT__cx_cbits) << 8 | unsigned(q->m2_te__DOT__cx_ab) << 4 | unsigned(q->m2_te__DOT__cx_ssb)]++;
		}
		if (!strcmp(st_name[q->m2_te__DOT__st & 127], "E_START"))
		{
			if (q->m2_te__DOT__w_on) e_wpix++;
			else if (q->m2_te__DOT__p_any) e_wdrain++;
		}
	}
#endif
	{
		static uint32_t watch = getenv("TE_WATCH") ? uint32_t(strtoul(getenv("TE_WATCH"), nullptr, 16)) : 0;
		auto *q = t->rootp;
		static int wtrace;
		{
			// every colour write, in order (TE_CW=file)
			static FILE *fcw = getenv("TE_CW") ? fopen(getenv("TE_CW"), "w") : nullptr;
			if (fcw && q->m2_te__DOT__cc__DOT__w_go)
				fprintf(fcw, "%07x %08x %llu\n", unsigned(q->m2_te__DOT__cc__DOT__w_a) << 1, unsigned(q->m2_te__DOT__c_wd), (unsigned long long)clocks);
#ifdef Z_SDRAM
			// every line put in the SDRAM's queue (TE_ZP=file), against what reaches the chip (TE_ZL)
			static FILE *fzp = getenv("TE_ZP") ? fopen(getenv("TE_ZP"), "w") : nullptr;
			if (fzp && q->m2_te__DOT__zmem__DOT__push) fprintf(fzp, "W %07x\n", unsigned(q->m2_te__DOT__zl_wa) << 5);
#endif
		}
		// the watched pixel's Z test (V1), and every Z write to its Z address
		if (watch && (q->m2_te__DOT__v1_d & 0xfffffff) == (watch & 0xfffffff) && q->m2_te__DOT__pu && q->m2_te__DOT__v1_v)
			printf("  Z test at clock %llu: z %07x zc %d w16 %04x z_q %04x zp %d zb %d\n", (unsigned long long)clocks, unsigned(q->m2_te__DOT__v1_z), int(q->m2_te__DOT__v1_zc),
				unsigned(q->m2_te__DOT__v1_w16), unsigned(q->m2_te__DOT__z_q), int(q->m2_te__DOT__zp), int(q->m2_te__DOT__zb));
		{
			static uint32_t wz = getenv("TE_WZ") ? uint32_t(strtoul(getenv("TE_WZ"), nullptr, 16)) : 0;
			static int was_wn;
			if (was_wn) printf("  Z write at clock %llu: %04x\n", (unsigned long long)clocks, unsigned(q->m2_te__DOT__z_wd));
			was_wn = wz && q->m2_te__DOT__z_wn && (q->m2_te__DOT__z_wa & 0xfffffff) == (wz & 0xfffffff) && q->m2_te__DOT__pe;
		}
		if (watch && q->m2_te__DOT__d_addr == watch && q->m2_te__DOT__pu)
		{
			// (TE_PIPDUMP=first entry: 16 palette entries from there, and TRAM's first 8 words, as they are now)
			if (getenv("TE_PIPDUMP"))
			{
				unsigned p0 = unsigned(strtoul(getenv("TE_PIPDUMP"), nullptr, 16));
				printf("  pip %02x:", p0);
				for (unsigned i = 0; i < 16; i++) printf(" %08x", unsigned(q->m2_te__DOT__fetch_a__DOT__pip__DOT__mem[(p0 + i) & 255]));
				printf("\n  tram:");
				unsigned t0 = getenv("TE_TRAMAT") ? unsigned(strtoul(getenv("TE_TRAMAT"), nullptr, 16)) / 4 : 0;   // (a byte address)
				for (unsigned i = t0; i < t0 + 8; i++)
					printf(" %08x", unsigned(i & 1 ? q->m2_te__DOT__fetch_a__DOT__tram1__DOT__mem[(i >> 1) & 2047] : q->m2_te__DOT__fetch_a__DOT__tram0__DOT__mem[(i >> 1) & 2047]));
				printf("\n");
				printf("  uvmax %08x uvmask %08x lod bases %08x %08x %08x %08x addr %08x\n", unsigned(q->m2_te__DOT__tm_uvmax), unsigned(q->m2_te__DOT__tm_uvmask),
					unsigned(q->m2_te__DOT__tm_lod0), unsigned(q->m2_te__DOT__tm_lod1), unsigned(q->m2_te__DOT__tm_lod2), unsigned(q->m2_te__DOT__tm_lod3), unsigned(q->m2_te__DOT__tm_addr));
			}
			if (getenv("TE_PIPDUMP"))
			{
				// (the texel stages as they are now: whichever pixels they hold)
				printf("  t0 %04x,%04x t1 %04x,%04x wk %03x wy %03x\n", unsigned(q->m2_te__DOT__t0_u), unsigned(q->m2_te__DOT__t0_v), unsigned(q->m2_te__DOT__t1_u),
					unsigned(q->m2_te__DOT__t1_v), unsigned(q->m2_te__DOT__wk), unsigned(q->m2_te__DOT__wy));
				printf("  tu %04x tv %04x lod %d min %d a2_lod %d a3_lod %d a4_base %06x k_u0 %03x k_v0 %03x a2_v0 %03x a3_vo %06x\n", unsigned(q->m2_te__DOT__tu), unsigned(q->m2_te__DOT__tv),
					int(q->m2_te__DOT__t_lod), int(q->m2_te__DOT__t_min), int(q->m2_te__DOT__a2_lod), int(q->m2_te__DOT__a3_lod), unsigned(q->m2_te__DOT__a4_base),
					unsigned(q->m2_te__DOT__k_u0), unsigned(q->m2_te__DOT__k_v0), unsigned(q->m2_te__DOT__a2_v0), unsigned(q->m2_te__DOT__a3_vo));
			}
			wtrace = 14;
			printf("  tex: cntl %08x addr %08x pip %08x exp %08x c0 %08x c1 %08x c2 %08x c3 %08x lod0 %08x\n", unsigned(q->m2_te__DOT__tm_cntl), unsigned(q->m2_te__DOT__tm_addr), unsigned(q->m2_te__DOT__tm_pip), unsigned(q->m2_te__DOT__tm_exp),
				unsigned(q->m2_te__DOT__tm_c0), unsigned(q->m2_te__DOT__tm_c1), unsigned(q->m2_te__DOT__tm_c2), unsigned(q->m2_te__DOT__tm_c3), unsigned(q->m2_te__DOT__tm_lod0));
		}
		if (wtrace && q->m2_te__DOT__pe)
		{
			wtrace--;
			printf("    %2d: t_d %08x i_d %08x tb_a %06x tb_b %06x tb_t %06x ti %02x%02x%02x/%02x td %02x%02x%02x/%02x src %02x%02x%02x/%02x ds %02x%02x%02x\n", wtrace, unsigned(q->m2_te__DOT__t_d), unsigned(q->m2_te__DOT__i_d),
				unsigned(q->m2_te__DOT__tb_a), unsigned(q->m2_te__DOT__tb_b), unsigned(q->m2_te__DOT__tb_t),
				unsigned(q->m2_te__DOT__ti_r), unsigned(q->m2_te__DOT__ti_g), unsigned(q->m2_te__DOT__ti_b), unsigned(q->m2_te__DOT__ti_a),
				unsigned(q->m2_te__DOT__td_r), unsigned(q->m2_te__DOT__td_g), unsigned(q->m2_te__DOT__td_b), unsigned(q->m2_te__DOT__td_a),
				unsigned(q->m2_te__DOT__sr), unsigned(q->m2_te__DOT__sg), unsigned(q->m2_te__DOT__sb), unsigned(q->m2_te__DOT__sa),
				unsigned(q->m2_te__DOT__ds_r), unsigned(q->m2_te__DOT__ds_g), unsigned(q->m2_te__DOT__ds_b));
		}
		if (watch && q->m2_te__DOT__d_addr == watch && q->m2_te__DOT__pu)
			printf("  pixel at clock %llu: user %08x sctl %08x dctl %08x tmul %08x smul %08x tc0 %08x tc1 %08x sc0 %08x sc1 %08x const %08x alu %08x ssb %08x da %08x sa %08x discard %08x tab %08x master %08x z %08x\n",
				(unsigned long long)clocks, unsigned(q->m2_te__DOT__db_user), unsigned(q->m2_te__DOT__db_sctl), unsigned(q->m2_te__DOT__db_dctl), unsigned(q->m2_te__DOT__db_tmul), unsigned(q->m2_te__DOT__db_smul),
				unsigned(q->m2_te__DOT__db_tc0), unsigned(q->m2_te__DOT__db_tc1), unsigned(q->m2_te__DOT__db_sc0), unsigned(q->m2_te__DOT__db_sc1), unsigned(q->m2_te__DOT__db_constin), unsigned(q->m2_te__DOT__db_alu),
				unsigned(q->m2_te__DOT__db_ssb), unsigned(q->m2_te__DOT__db_da), unsigned(q->m2_te__DOT__db_sa), unsigned(q->m2_te__DOT__db_discard), unsigned(q->m2_te__DOT__tm_tab), unsigned(q->m2_te__DOT__gc_master), unsigned(q->m2_te__DOT__db_zctl));
	}
	stalled += !t->rootp->m2_te__DOT__pe;
#ifdef Z_SDRAM
	{
		// the Z cache's fetches, by what asked: a write's miss, a read's, the line ahead; and the clocks a read waited after each kind
		static uint64_t zf[3], zw[3];
		static int last = 2;
		auto *r = t->rootp;
		if (r->m2_te__DOT__zc__DOT__f_st == 0)
		{
			if (r->m2_te__DOT__zc__DOT__w_miss) last = 0, zf[0]++;
			else if (r->m2_te__DOT__zc__DOT__r_miss) last = 1, zf[1]++;
			else if (r->m2_te__DOT__zc__DOT__p_want) last = 2, zf[2]++;
		}
		if (r->m2_te__DOT__zr_stall) zw[last]++;
		if (getenv("TE_ZF") && (r->m2_te__DOT__st & 127) == 0 && zf[0] + zf[1] + zf[2])
		{
			printf("  Z fetches: %llu for writes, %llu for reads, %llu ahead; read stalls after each %llu %llu %llu\n", (unsigned long long)zf[0], (unsigned long long)zf[1], (unsigned long long)zf[2],
				(unsigned long long)zw[0], (unsigned long long)zw[1], (unsigned long long)zw[2]);
			zf[0] = zf[1] = zf[2] = zw[0] = zw[1] = zw[2] = 0;
		}
	}
#endif
	{
		static int was;
		int s = t->rootp->m2_te__DOT__st & 127;
		if (getenv("TE_TRAM"))
		{
			static unsigned char used[4096];
			used[t->rootp->m2_te__DOT__fetch_a__DOT__t_ra & 4095] = 1;
			if (!strcmp(st_name[s], "T_MM") && strcmp(st_name[was], "T_MM") && t->rootp->m2_te__DOT__mm_dst == 0)
			{
				int w = 0, l8 = 0, l32 = 0;
				for (int i = 0; i < 4096; i++) w += used[i];
				for (int i = 0; i < 4096; i += 8) { int u = 0; for (int j = 0; j < 8; j++) u |= used[i + j]; l8 += u; }
				for (int i = 0; i < 4096; i += 32) { int u = 0; for (int j = 0; j < 32; j++) u |= used[i + j]; l32 += u; }
				printf("  tram used: %d of 4096 words, %d of 512 32-byte lines, %d of 128 128-byte blocks\n", w, l8, l32);
				memset(used, 0, sizeof used);
			}
		}
		{
			// (with TE_LOADS: each change of the texture's format, and the state it came in)
			static uint32_t last_exp = 0xffffffff;
			if (getenv("TE_LOADS") && t->rootp->m2_te__DOT__tm_exp != last_exp)
			{
				last_exp = t->rootp->m2_te__DOT__tm_exp;
				printf("  exp %08x at clock %llu in %s\n", unsigned(last_exp), (unsigned long long)clocks, st_name[s]);
			}
		}
		if (getenv("TE_LOADS") && !strcmp(st_name[s], "T_LOAD") && strcmp(st_name[was], "T_LOAD"))
			printf("  load command at clock %llu: ldcntl %08x cntl %08x src %08x count %08x lod0 %08x exp %08x\n", (unsigned long long)clocks,
				unsigned(t->rootp->m2_te__DOT__tm_ldcntl), unsigned(t->rootp->m2_te__DOT__tm_cntl), unsigned(t->rootp->m2_te__DOT__tm_src),
				unsigned(t->rootp->m2_te__DOT__tm_count), unsigned(t->rootp->m2_te__DOT__tm_lod0), unsigned(t->rootp->m2_te__DOT__tm_exp));
		if (getenv("TE_LOADS") && !strcmp(st_name[s], "T_MM") && strcmp(st_name[was], "T_MM"))
			printf("  load at clock %llu src %08x dst %04x count %x pip %d compressed %d (texels %x) exp %08x\n", (unsigned long long)clocks, unsigned(t->rootp->m2_te__DOT__mm_src),
				unsigned(t->rootp->m2_te__DOT__mm_dst), unsigned(t->rootp->m2_te__DOT__mm_n), int(t->rootp->m2_te__DOT__mm_pip), int(t->rootp->m2_te__DOT__mm_cmp),
				unsigned(t->rootp->m2_te__DOT__tm_count), unsigned(t->rootp->m2_te__DOT__tm_exp));
		{
			static FILE *fev = getenv("TE_EV") ? fopen(getenv("TE_EV"), "w") : nullptr;
			if (fev && s != was) fprintf(fev, "%d %llu\n", s, (unsigned long long)clocks);
		}
		{
			// each attribute set up: which, flat, the same as the last
			static uint64_t at_n[8], at_flat[8], at_same[8], tri;
			static uint32_t pq[3];
			auto *qq = t->rootp;
			if (!strcmp(st_name[s], "S_OP") && strcmp(st_name[was], "S_OP"))
			{
				int ai = qq->m2_te__DOT__at_i;
				uint32_t a1 = qq->m2_te__DOT__q1f, a2 = qq->m2_te__DOT__q2f, a3 = qq->m2_te__DOT__q3f;
				at_n[ai]++;
				if (a1 == a2 && a1 == a3 && ai < 4) at_flat[ai]++;
				else if (ai > 0 && ai < 4 && a1 == pq[0] && a2 == pq[1] && a3 == pq[2]) at_same[ai]++;
				pq[0] = a1; pq[1] = a2; pq[2] = a3;
			}
			{
				// (TE_LODS: how many texel samples of each texture, by its TXTADDRCNTL, took each level; printed as a list ends)
				static std::map<uint64_t, uint64_t> lods;
				if (getenv("TE_LODS"))
				{
					if (qq->m2_te__DOT__pe && qq->m2_te__DOT__v9_v && qq->m2_te__DOT__t_look)
						lods[(uint64_t(qq->m2_te__DOT__tm_addr & 0xffff) << 32) | (uint64_t(qq->m2_te__DOT__tm_lod1 & 0xffff) << 16) | qq->m2_te__DOT__t_lod]++;
					if (!strcmp(st_name[s], "I_STOP") && strcmp(st_name[was], "I_STOP") && !lods.empty())
					{
						for (auto &l : lods) printf("  lods: addr %04x lod1 base %04x lod %u: %llu\n", unsigned(l.first >> 32), unsigned(l.first >> 16) & 0xffff, unsigned(l.first & 15), (unsigned long long)l.second);
						lods.clear();
					}
				}
			}
			{
				// (TE_BLENDI=rrggbbaa: the texture blender's inputs whenever the iterated colour is that, at E4, where rt.. are)
				static const char *bi = getenv("TE_BLENDI");
				// (or TE_BLENDW=first,last: every one in those clocks)
				static const char *bw = getenv("TE_BLENDW");
				static unsigned long long bw0 = bw ? strtoull(bw, nullptr, 10) : 0, bw1 = bw && strchr(bw, ',') ? strtoull(strchr(bw, ',') + 1, nullptr, 10) : 0;
				if (bw && clocks >= bw0 && clocks <= bw1)
					printf("  clk %llu tq_a %06x tq_b %06x tq_t %06x tab %08x c2 %08x c3 %08x\n", (unsigned long long)clocks, unsigned(qq->m2_te__DOT__tq_a), unsigned(qq->m2_te__DOT__tq_b),
						unsigned(qq->m2_te__DOT__tq_t), unsigned(qq->m2_te__DOT__tm_tab), unsigned(qq->m2_te__DOT__tm_c2), unsigned(qq->m2_te__DOT__tm_c3));
				if (bw && clocks >= bw0 && clocks <= bw1)
					printf("  clk %llu pe %d e4 %d t2 %d t3 %d t4 %d bl_c %d e3_o %d d2_e %d d2_o %d | t_d %08x i_d %08x ti %02x%02x%02x tbl %02x%02x%02x\n", (unsigned long long)clocks,
						int(qq->m2_te__DOT__pe), int(qq->m2_te__DOT__e4_v), int(qq->m2_te__DOT__t2_v), int(qq->m2_te__DOT__t3_v), int(qq->m2_te__DOT__t4_v), int(qq->m2_te__DOT__bl_c),
						int(qq->m2_te__DOT__e3_o), int(qq->m2_te__DOT__d2_e), int(qq->m2_te__DOT__d2_o), unsigned(qq->m2_te__DOT__t_d), unsigned(qq->m2_te__DOT__i_d),
						unsigned(qq->m2_te__DOT__ti_r), unsigned(qq->m2_te__DOT__ti_g), unsigned(qq->m2_te__DOT__ti_b), unsigned(qq->m2_te__DOT__tbl_r), unsigned(qq->m2_te__DOT__tbl_g), unsigned(qq->m2_te__DOT__tbl_b));
				if (qq->m2_te__DOT__pe && qq->m2_te__DOT__e4_v && ((bi && unsigned(qq->m2_te__DOT__fa_q) == unsigned(strtoul(bi, nullptr, 16))) || (bw && clocks >= bw0 && clocks <= bw1)))
					printf("  blend at clock %llu: i %08x t %02x%02x%02x/%02x ssb %d a3_lod %d\n", (unsigned long long)clocks, unsigned(qq->m2_te__DOT__fa_q),
						unsigned(qq->m2_te__DOT__bx_r), unsigned(qq->m2_te__DOT__bx_g), unsigned((qq->m2_te__DOT__bl_oa >> 8) & 255), unsigned((qq->m2_te__DOT__bl_ob >> 8) & 255),
						int((qq->m2_te__DOT__ts_c >> 2) & 1), int(qq->m2_te__DOT__a3_lod));
			}
			if (!strcmp(st_name[s], "P_RUN") && strcmp(st_name[was], "P_RUN") && getenv("TE_TRI"))
			{
				static int nt;
				if (nt++ < atoi(getenv("TE_TRI")))
					printf("  tri: user %08x dctl %08x discard %08x master %08x y %d..%d x1 %d lr %d zbase %08x dbase %08x stride %08x mask %02x\n", unsigned(qq->m2_te__DOT__db_user), unsigned(qq->m2_te__DOT__db_dctl),
						unsigned(qq->m2_te__DOT__db_discard), unsigned(qq->m2_te__DOT__gc_master), int(qq->m2_te__DOT__y1), int(qq->m2_te__DOT__y3), int(qq->m2_te__DOT__x1), int(qq->m2_te__DOT__scan_lr), unsigned(qq->m2_te__DOT__db_zbase), unsigned(qq->m2_te__DOT__db_dbase), unsigned(qq->m2_te__DOT__db_dstride), int(qq->m2_te__DOT__at_mask));
			}
			if (!strcmp(st_name[s], "E_START") && (++tri % 500) == 0)
			{
				printf("  attrs at %llu triangles:", (unsigned long long)tri);
				for (int i = 0; i < 7; i++) printf(" %llu/%llu/%llu", (unsigned long long)at_n[i], (unsigned long long)at_flat[i], (unsigned long long)at_same[i]);
				printf("\n");
			}
		}
		was = s;
	}
	if (t->rootp->m2_te__DOT__w_on)
	{
		auto *q = t->rootp;
		bool px_left = q->m2_te__DOT__px != q->m2_te__DOT__pxe;
		if (!q->m2_te__DOT__pe)
		{
			p_stall++;
			p_zr += q->m2_te__DOT__zr_stall; p_zw += q->m2_te__DOT__zw_stall; p_cr += q->m2_te__DOT__cr_stall; p_cw += q->m2_te__DOT__cw_stall;
#ifdef TE_PROF
			if (q->m2_te__DOT__cr_stall || q->m2_te__DOT__cw_stall)
			{
				static const char *cst[] = { "INIT", "IDLE", "EVW", "FILL", "FILLW", "REARM", "FWALK", "FLOOK", "FEND" };
				static const char *bst[] = { "b-idle", "b-look", "b-rd", "b-wr", "b-tag" };
				auto *c = q;
				char key[160];
				unsigned st = c->m2_te__DOT__cc__DOT__st, bs = c->m2_te__DOT__cc__DOT__b_st, qc = c->m2_te__DOT__cc__DOT__q_cnt;
				snprintf(key, sizeof key, "%s %s %s q%s%s%s%s", q->m2_te__DOT__cr_stall ? "R" : "-", q->m2_te__DOT__cw_stall ? "W" : "-", st < 9 ? cst[st] : "?", qc == 0 ? "0" : qc < 8 ? "1-7" : qc < 16 ? "8-15" : "16",
					bs < 5 ? (std::string(" ") + bst[bs]).c_str() : " ?", c->m2_te__DOT__cc__DOT__m_req && !c->m2_te__DOT__m_owned ? " port-wait" : "", c->m2_te__DOT__cc__DOT__r_v && !c->m2_te__DOT__cc__DOT__r_hit ? " rmiss" : "");
				cc_why[key]++;
			}
#endif
		}
		else if (!px_left) p_drain++;
		else if (q->m2_te__DOT__t_hold)
		{
			p_hold++;
			if (q->m2_te__DOT__tk_i == 0)
			{
				bool bil = q->m2_te__DOT__tm_addr >> 5 & 1;
				if (!bil) p_pt++;
				else
				{
					p_bil++;
					unsigned uf = q->m2_te__DOT__tu & 15, vf = q->m2_te__DOT__tv & 15;
					if (uf == 0 && vf == 0) p_both++;
					else if (uf == 0) p_u0++;
					else if (vf == 0) p_v0++;
				}
			}
		}
		else if (q->m2_te__DOT__serial && q->m2_te__DOT__p_any) p_ser++;
		else p_go++;
	}
#endif
	clocks++;
}

static void cpu_write(uint32_t off, uint32_t d)
{
	t->a = off >> 2; t->wd = d; t->we = 1;
	clock1();
	t->we = 0;
}

static bool load(const std::string &fn, std::vector<uint8_t> &v, size_t n)
{
	FILE *f = fopen(fn.c_str(), "rb");
	if (!f) { printf("no %s\n", fn.c_str()); return false; }
	v.resize(n);
	size_t r = fread(v.data(), 1, n, f);
	fclose(f);
	if (r != n) printf("%s short\n", fn.c_str());
	return true;
}
static uint32_t be32(const std::vector<uint8_t> &v, uint32_t o)
{
	return (v[o] << 24) | (v[o + 1] << 16) | (v[o + 2] << 8) | v[o + 3];
}

static void ppm(const std::string &fn, const std::vector<uint8_t> &m, uint32_t base, uint32_t stride, bool b32)
{
	// (as wide as a row, up to 640: a 320-pixel frame is 320 wide)
	const uint32_t wd = stride != 0 && stride < 640 ? stride : 640;
	FILE *f = fopen(fn.c_str(), "wb");
	fprintf(f, "P6\n%u 240\n255\n", wd);
	for (uint32_t y = 0; y < 240; y++)
		for (uint32_t x = 0; x < wd; x++)
		{
			uint32_t o = base - RAM_BASE + (y * stride + x) * (b32 ? 4 : 2);
			uint8_t c[3] = { 0, 0, 0 };
			if (o + 4 < RAM_SIZE)
			{
				if (b32) { c[0] = m[o + 1]; c[1] = m[o + 2]; c[2] = m[o + 3]; }
				else
				{
					uint32_t p = (m[o] << 8) | m[o + 1];
					c[0] = (p >> 10) << 3; c[1] = (p >> 5) << 3; c[2] = p << 3;
				}
			}
			fwrite(c, 1, 3, f);
		}
	fclose(f);
}

int main(int argc, char **argv)
{
	std::string dir = "/mnt/c/repos/konamim2-mister/work/cap/te", pfx;
	bool verbose = false;
	std::vector<int> ks;
	for (int i = 1; i < argc; i++)
	{
		std::string a = argv[i];
		if (a == "-d") dir = argv[++i];
		else if (a == "-slow") slow = true;
		else if (a == "-ppm") pfx = argv[++i];
		else if (a == "-v") verbose = true;
		else ks.push_back(atoi(argv[i]));
	}
	t = new Vm2_te;
	t->rst = 1; t->we = 0; t->m_busy = 0; t->m_ready = 0;
	for (int i = 0; i < 10; i++) clock1();
	t->rst = 0;
	for (int i = 0; i < 300; i++) clock1();
#ifdef Z_SDRAM
	while (!t->sd_ready) clock1();
#endif

	wrote.resize(RAM_SIZE);
	int bad = 0;
	int k_last = -2;
	for (int k : ks)
	{
		// (the next dump after the last: else the RAM's changed behind the Z buffer's copy, as a master's write would tell it)
		if (k != k_last + 1 && k_last != -2)
		{
#ifdef Z_SDRAM
			std::fill(zram.begin(), zram.end(), 0);
#endif
			t->rst = 1;
			for (int i = 0; i < 10; i++) clock1();
			t->rst = 0;
			for (int i = 0; i < 300; i++) clock1();
#ifdef Z_SDRAM
			while (!t->sd_ready) clock1();
#endif
		}
		k_last = k;
		std::vector<uint8_t> te, next, nte;
		if (!load(dir + "/" + std::to_string(k) + "_ram.bin", ram, RAM_SIZE)) return 2;
		if (!load(dir + "/" + std::to_string(k) + "_te.bin", te, 0x10000)) return 2;
		if (!load(dir + "/" + std::to_string(k + 1) + "_ram.bin", next, RAM_SIZE)) return 2;
		if (!load(dir + "/" + std::to_string(k + 1) + "_te.bin", nte, 0x10000)) return 2;
		std::vector<uint8_t> before = ram;
		std::fill(wrote.begin(), wrote.end(), 0);

		// the registers. Not TEICNTL, TEDCNTL's action is the list's only
		for (uint32_t r : { 0u, 2u, 4u, 5u, 6u, 7u, 8u, 9u }) cpu_write(r * 4, be32(te, r * 4));
		cpu_write(0x4000, be32(te, 0x4000));
		for (uint32_t o = 0x6000; o < 0x6000 + 0x400 + 21 * 4; o += 4) cpu_write(o, be32(te, o));
		for (uint32_t o = 0x8000; o < 0x8000 + 34 * 4; o += 4) cpu_write(o, be32(te, o));

		uint64_t c0 = clocks;
		writes = reads = 0;
#ifdef Z_SDRAM
		zreads = zwrites = 0;
#endif
		cpu_write(0x000c, 0x21);
		while (t->busy && clocks - c0 < 60000000ull) clock1();
		if (t->busy) { printf("k %d: still busy at %llu clocks\n", k, (unsigned long long)(clocks - c0)); 
#ifdef TE_PROF
		{ auto *r = t->rootp;
			printf("  st %d m_owned %d c_req %d lb_rd %d lb_wait %d f_want %d f_ok %d rq %d m_rd %d m_we %d\n", int(r->m2_te__DOT__st), int(r->m2_te__DOT__m_owned), int(r->m2_te__DOT__c_req), int(r->m2_te__DOT__lb_rd), int(r->m2_te__DOT__lb_wait), int(r->m2_te__DOT__f_want), int(r->m2_te__DOT__f_ok), int(rq.size()), int(t->m_rd), int(t->m_we));
			printf("  pe %d pu %d p_any %d serial %d px %d pxe %d nx %d zw %d cr %d cw %d ms_out %d ms_left %d mm_n %d\n", int(r->m2_te__DOT__pe), int(r->m2_te__DOT__pu), int(r->m2_te__DOT__p_any), int(r->m2_te__DOT__serial), int(r->m2_te__DOT__px), int(r->m2_te__DOT__pxe), int(r->m2_te__DOT__nx), int(r->m2_te__DOT__zw_stall), int(r->m2_te__DOT__cr_stall), int(r->m2_te__DOT__cw_stall), int(r->m2_te__DOT__ms_out), int(r->m2_te__DOT__ms_left), int(r->m2_te__DOT__mm_n));
#ifdef Z_SDRAM
			printf("  Z cache: f_st %d f_t %x f_i %x r_v %d r_a %06x r_hit %d tr_q %x w_v %d w_done %d w_a %06x k_hit %d f_kc %d f_got %d l_rbusy %d zk_walk %d\n", int(r->m2_te__DOT__zc__DOT__f_st),
				unsigned(r->m2_te__DOT__zc__DOT__f_t), unsigned(r->m2_te__DOT__zc__DOT__f_i), int(r->m2_te__DOT__zc__DOT__r_v), unsigned(r->m2_te__DOT__zc__DOT__r_a) << 1,
				int(r->m2_te__DOT__zc__DOT__r_hit), unsigned(r->m2_te__DOT__zc__DOT__tr_q), int(r->m2_te__DOT__zc__DOT__w_v), int(r->m2_te__DOT__zc__DOT__w_done), unsigned(r->m2_te__DOT__zc__DOT__w_a) << 1,
				int(r->m2_te__DOT__zk_hit), int(r->m2_te__DOT__zc__DOT__f_kc), int(r->m2_te__DOT__zc__DOT__f_got), int(r->m2_te__DOT__zl_rbusy), int(r->m2_te__DOT__zk_walk));
#endif
			}
#endif
		return 3; }
		uint64_t c1 = clocks;
#ifdef TE_PROF
		for (int i = 1; i < int(sizeof st_name / sizeof *st_name); i++)
			if (st_n[i]) printf("  %-8s %10llu %5.1f%%\n", st_name[i], (unsigned long long)st_n[i], 100.0 * st_n[i] / (c1 - c0));
		memset(st_n, 0, sizeof st_n);
		printf("  stalled  %10llu %5.1f%%\n", (unsigned long long)stalled, 100.0 * stalled / (c1 - c0));
		stalled = 0;
		printf("  P_RUN: %llu pixels go, %llu held by the texels, %llu serial, %llu draining, %llu stalled (Z read %llu, Z write %llu, colour read %llu, colour write %llu)\n",
			(unsigned long long)p_go, (unsigned long long)p_hold, (unsigned long long)p_ser, (unsigned long long)p_drain, (unsigned long long)p_stall,
			(unsigned long long)p_zr, (unsigned long long)p_zw, (unsigned long long)p_cr, (unsigned long long)p_cw);
		printf("  textured: %llu point, %llu bilinear (of those %llu no U fraction, %llu no V, %llu neither)\n", (unsigned long long)p_pt, (unsigned long long)p_bil, (unsigned long long)p_u0, (unsigned long long)p_v0, (unsigned long long)p_both);
		p_pt = p_bil = p_u0 = p_v0 = p_both = 0;
		p_go = p_hold = p_ser = p_drain = p_zr = p_zw = p_cr = p_cw = p_stall = 0;
		printf("  waits: I_FETCH for the list %llu, for the pixels %llu; E_START for the walk %llu, for the drain %llu\n", (unsigned long long)f_list, (unsigned long long)f_pix,
			(unsigned long long)e_wpix, (unsigned long long)e_wdrain);
		f_list = f_pix = e_wpix = e_wdrain = 0;
		{
			std::vector<std::pair<uint64_t, std::string>> v;
			for (auto &kv : cc_why) v.push_back({kv.second, kv.first});
			std::sort(v.rbegin(), v.rend());
			printf("  color stalls by the cache's state:");
			for (size_t i = 0; i < v.size() && i < 14; i++) printf(" [%s] %llu;", v[i].second.c_str(), (unsigned long long)v[i].first);
			printf("\n");
			cc_why.clear();
		}
		if (cx_clk)
		{
			printf("  compressed loads: %llu clocks: control %llu, in a run %llu, in a string %llu, short of source %llu; texels by dbits/cbits/abits/ssb:", (unsigned long long)cx_clk,
				(unsigned long long)cx_ctl, (unsigned long long)cx_emit_run, (unsigned long long)cx_emit_str, (unsigned long long)cx_nosrc);
			for (auto &kv : cx_bits) printf(" %u/%u/%u/%u:%llu", kv.first >> 16, kv.first >> 8 & 255, kv.first >> 4 & 15, kv.first & 15, (unsigned long long)kv.second);
			printf("\n");
			cx_clk = cx_ctl = cx_emit_run = cx_emit_str = cx_nosrc = 0; cx_bits.clear();
		}
		printf("  register writes:");
		for (auto &kv : regw_n) printf(" %05x:%llu", kv.first, (unsigned long long)kv.second);
		printf("\n");
		regw_n.clear();
		printf("  register instructions (offset:count n waited):");
		for (auto &kv : regh_n) printf(" %04x:%u %llu %llu", kv.first >> 8, kv.first & 255, (unsigned long long)kv.second, (unsigned long long)regh_w[kv.first]);
		printf("\n");
		regh_n.clear(); regh_w.clear();
#endif
		while (!rq.empty()) clock1();
#ifdef Z_SDRAM
		while (!t->z_idle) clock1();
		printf("  Z: %llu lines read, %llu written; SDRAM timing errors %llu\n", (unsigned long long)zreads / 16, (unsigned long long)zwrites / 16, (unsigned long long)zerrs);
		if (getenv("TE_ZCMP"))
		{
			// the Z buffer, TE_ZCMP bytes from the list's Z base, against what MAME's RAM has there after it: by 16-pixel line, the first few
			uint32_t zb = be32(te, 0x8000 + 0 * 4), n = uint32_t(strtoul(getenv("TE_ZCMP"), nullptr, 0)), nd = 0, nl = 0, shown = 0;
			zb = getenv("TE_ZB") ? uint32_t(strtoul(getenv("TE_ZB"), nullptr, 16)) : zb;
			// (a line the fast clear's map has is its value, whatever the SDRAM holds)
			auto zbyte = [&](uint32_t a) -> uint8_t {
#ifdef TE_PROF
				auto *r = t->rootp;
				uint32_t li = ((a >> 5) - (uint32_t(r->m2_te__DOT__db_zbase) >> 5)) & 0xfffff;
				if (li < 32768 && !r->m2_te__DOT__zk_walk && r->m2_te__DOT__zk_z__DOT__mem[li])
					return uint8_t((a & 1) ? r->m2_te__DOT__zk_c >> 8 : r->m2_te__DOT__zk_c);
#endif
				return zram[a & ((1u << 25) - 1)];
			};
			for (uint32_t o = 0; o < n; o += 32)
			{
				int d = 0;
				for (uint32_t i = 0; i < 32; i++) d += zbyte(zb + o + i) != next[(zb - RAM_BASE + o + i) & (RAM_SIZE - 1)];
				nd += d; nl += d != 0;
				if (d && shown++ < 8) printf("    Z %08x: %d bytes differ (this %02x%02x MAME %02x%02x)\n", zb + o, d, zbyte(zb + o), zbyte(zb + o + 1),
					next[(zb - RAM_BASE + o) & (RAM_SIZE - 1)], next[(zb - RAM_BASE + o + 1) & (RAM_SIZE - 1)]);
			}
			printf("  Z buffer at %08x: %u bytes differ from MAME's, in %u lines\n", zb, nd, nl);
		}
#endif

		// the comparison
		uint64_t nw = 0, nbad = 0;
		std::map<uint32_t, uint64_t> pbad, pmiss, pwrote;
		int shown = 0;
		uint32_t db = getenv("TE_DB") ? uint32_t(strtoul(getenv("TE_DB"), nullptr, 16)) : be32(nte, 0x8000 + 10 * 4), ds = be32(nte, 0x8000 + 11 * 4), dctl = be32(nte, 0x8000 + 9 * 4);
		for (uint32_t i = 0; i < RAM_SIZE; i++)
		{
			if (wrote[i])
			{
				nw++;
				pwrote[i >> 16]++;
				if (ram[i] != next[i])
				{
					nbad++;
					pbad[i >> 16]++;
					if (verbose && shown < 30)
					{
						shown++;
						printf("  %08x: this %02x MAME %02x was %02x\n", RAM_BASE + i, ram[i], next[i], before[i]);
					}
				}
			}
			else if (next[i] != before[i]) pmiss[i >> 16]++;
		}
		printf("k %d: %llu clocks, %llu reads, %llu writes: %llu bytes written, %llu differ from MAME. irp %08x, iwp %08x\n",
			k, (unsigned long long)(c1 - c0), (unsigned long long)reads, (unsigned long long)writes, (unsigned long long)nw, (unsigned long long)nbad,
			be32(te, 8), be32(te, 6 * 4));
		for (auto &p : pwrote)
			printf("  page %08x: wrote %llu, differ %llu, MAME's changes not written here %llu\n", RAM_BASE + (p.first << 16), (unsigned long long)p.second,
				(unsigned long long)pbad[p.first], (unsigned long long)pmiss[p.first]);
		if (verbose)
			for (auto &p : pmiss)
				if (!pwrote.count(p.first))
					printf("  page %08x: not written here, MAME's changes %llu\n", RAM_BASE + (p.first << 16), (unsigned long long)p.second);
		if (nbad) bad = 1;
		if (!pfx.empty())
		{
			printf("  (the picture: %08x, stride %d, %s)\n", db, ds, dctl & 1 ? "32 bits" : "16 bits");
			ppm(pfx + std::to_string(k) + "_this.ppm", ram, db, ds, dctl & 1);
			ppm(pfx + std::to_string(k) + "_mame.ppm", next, db, ds, dctl & 1);
		}
	}
	printf(bad ? "DIFFERENT\n" : "ALL SAME\n");
	return bad;
}
