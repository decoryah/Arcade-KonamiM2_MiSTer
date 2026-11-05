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
	"V_NEXT", "V_FIELD", "V_PUT", "V_SCW", "V_SCE", "V_DONE",
	"S_SORT", "S_AR", "S_FD", "S_FDE", "S_DIV0", "S_DIV1", "S_DIV2", "S_XYS", "S_FC",
	"S_ATTR", "S_Q1", "S_Q2", "S_Q3", "S_Q4", "S_OP", "S_FX1",
	"E_START", "E_NEXT",
	"P_RUN" };
static const int P_RUN_N = int(sizeof st_name / sizeof *st_name) - 1;
static uint64_t stalled;
static uint64_t p_bil, p_pt, p_u0, p_v0, p_both, p_pt_go, p_go, p_hold, p_ser, p_drain, p_zr, p_zw, p_cr, p_cw, p_stall;
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
	t->clk = 0; t->eval();
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
	t->clk = 1; t->eval();
#ifdef TE_PROF
	st_n[t->rootp->m2_te__DOT__st & 127]++;
	stalled += !t->rootp->m2_te__DOT__pe;
	{
		static int was;
		int s = t->rootp->m2_te__DOT__st & 127;
		if (getenv("TE_LOADS") && !strcmp(st_name[s], "T_MM") && strcmp(st_name[was], "T_MM"))
			printf("  load src %08x dst %04x count %x pip %d\n", unsigned(t->rootp->m2_te__DOT__mm_src), unsigned(t->rootp->m2_te__DOT__mm_dst), unsigned(t->rootp->m2_te__DOT__mm_n), int(t->rootp->m2_te__DOT__mm_pip));
		was = s;
	}
	if ((t->rootp->m2_te__DOT__st & 127) == P_RUN_N)
	{
		auto *q = t->rootp;
		bool px_left = q->m2_te__DOT__px != q->m2_te__DOT__pxe;
		if (!q->m2_te__DOT__pe)
		{
			p_stall++;
			p_zr += q->m2_te__DOT__zr_stall; p_zw += q->m2_te__DOT__zw_stall; p_cr += q->m2_te__DOT__cr_stall; p_cw += q->m2_te__DOT__cw_stall;
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
	FILE *f = fopen(fn.c_str(), "wb");
	fprintf(f, "P6\n640 240\n255\n");
	for (uint32_t y = 0; y < 240; y++)
		for (uint32_t x = 0; x < 640; x++)
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

	wrote.resize(RAM_SIZE);
	int bad = 0;
	int k_last = -2;
	for (int k : ks)
	{
		// (the next dump after the last: else the RAM's changed behind the Z buffer's copy, as a master's write would tell it)
		if (k != k_last + 1 && k_last != -2)
		{
			t->rst = 1;
			for (int i = 0; i < 10; i++) clock1();
			t->rst = 0;
			for (int i = 0; i < 300; i++) clock1();
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
		cpu_write(0x000c, 0x21);
		while (t->busy && clocks - c0 < 60000000ull) clock1();
		if (t->busy) { printf("k %d: still busy at %llu clocks\n", k, (unsigned long long)(clocks - c0)); 
#ifdef TE_PROF
		{ auto *r = t->rootp;
			printf("  st %d m_owned %d m_own %d z_req %d c_req %d lb_rd %d lb_wait %d f_want %d f_ok %d rq %d m_rd %d m_we %d\n", int(r->m2_te__DOT__st), int(r->m2_te__DOT__m_owned), int(r->m2_te__DOT__m_own), int(r->m2_te__DOT__z_req), int(r->m2_te__DOT__c_req), int(r->m2_te__DOT__lb_rd), int(r->m2_te__DOT__lb_wait), int(r->m2_te__DOT__f_want), int(r->m2_te__DOT__f_ok), int(rq.size()), int(t->m_rd), int(t->m_we));
			printf("  pe %d pu %d p_any %d serial %d px %d pxe %d nx %d zr %d zw %d cr %d cw %d ms_out %d ms_left %d mm_n %d\n", int(r->m2_te__DOT__pe), int(r->m2_te__DOT__pu), int(r->m2_te__DOT__p_any), int(r->m2_te__DOT__serial), int(r->m2_te__DOT__px), int(r->m2_te__DOT__pxe), int(r->m2_te__DOT__nx), int(r->m2_te__DOT__zr_stall), int(r->m2_te__DOT__zw_stall), int(r->m2_te__DOT__cr_stall), int(r->m2_te__DOT__cw_stall), int(r->m2_te__DOT__ms_out), int(r->m2_te__DOT__ms_left), int(r->m2_te__DOT__mm_n));
			printf("  zc st %d b_st %d  cc st %d b_st %d\n", int(r->m2_te__DOT__zc__DOT__st), int(r->m2_te__DOT__zc__DOT__b_st), int(r->m2_te__DOT__cc__DOT__st), int(r->m2_te__DOT__cc__DOT__b_st)); }
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
#endif
		while (!rq.empty()) clock1();

		// the comparison
		uint64_t nw = 0, nbad = 0;
		std::map<uint32_t, uint64_t> pbad, pmiss, pwrote;
		int shown = 0;
		uint32_t db = be32(nte, 0x8000 + 10 * 4), ds = be32(nte, 0x8000 + 11 * 4), dctl = be32(nte, 0x8000 + 9 * 4);
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
