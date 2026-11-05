// tb_replay.cpp: the DSP alone, given what the game gave MAME's (a log from work/lua/dsp_wp.lua), paced by the log's frames. Prints each read
// beside MAME's answer, and where the DSP's program has got to.
//
//   tb_replay <log> [last frame]
#include "Vm2_dspp.h"
#include "Vm2_dspp___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
static Vm2_dspp *t;
#define R t->rootp
static int dac_n;
static long clocks;
static bool mw;
static void tick()
{
	t->dac_tick = ++dac_n >= 1512;
	if (t->dac_tick) dac_n = 0;
	t->m_busy = 0; t->m_ready = mw; t->m_dout = 0;
	t->eval();
	mw = t->m_rd;
	t->clk = 1; t->eval(); t->clk = 0; t->eval();
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
int main(int argc, char **argv)
{
	Verilated::commandArgs(argc, argv);
	t = new Vm2_dspp;
	t->rst = 1; for (int i = 0; i < 8; i++) tick(); t->rst = 0; tick();
	FILE *f = fopen(argv[1], "r");
	int last = argc > 2 ? atoi(argv[2]) : 520;
	char l[256];
	int fr = -1, shown = 0, bad = 0;
	long frame_start = 0;
	const long FRAME = 1122000;
	while (fgets(l, sizeof l, f))
	{
		char d; unsigned a, v; int c, sz; char pc[32], tag[32], rep[32] = "";
		int n = sscanf(l, "%d %c %x %d %x %31s %31s %31s", &c, &d, &a, &sz, &v, pc, tag, rep);
		if (n < 7 || tag[0] != 'f') continue;
		int nf = atoi(tag + 1);
		if (nf > last) break;
		if (nf < 460) continue;
		if (fr >= 0)
			while (nf != fr)
			{
				while (clocks < frame_start + FRAME) tick();
				frame_start = clocks;
				fr++;
				if (fr % 4 == 0 || fr < 470)
					printf("f%d: pc %03X up %u duration %u partial %08X en %08X intr %d out %d dac %04X %04X\n", fr, unsigned(R->m2_dspp__DOT__pc), unsigned(R->m2_dspp__DOT__up_time),
						unsigned(R->m2_dspp__DOT__duration), unsigned(R->m2_dspp__DOT__partial_int), unsigned(R->m2_dspp__DOT__int_enable), int(t->intr), int(R->m2_dspp__DOT__o_count), t->dac_l, t->dac_r);
			}
		else fr = nf;
		for (int i = 0; i < 30; i++) tick();
		uint32_t off = a & 0xffff;
		if (d == 'w') hw(off, v);
		else if (off != 0x1ffc)
		{
			uint32_t got = hr(off);
			if (got != v && shown++ < 60) printf("f%d read %04X: %X, MAME's %X\n", nf, off, got, v);
			if (got != v) bad++;
		}
	}
	printf("%d reads differ\n", bad);
	return 0;
}
