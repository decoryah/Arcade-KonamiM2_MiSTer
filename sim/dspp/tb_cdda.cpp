// tb_cdda.cpp: the CD audio's stream: a made-up image, MiSTer's SD handshake with a random delay; every sample out, against the image; a second
// play in the middle of the first, the position, the end.
#include "Vm2_cdda.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <vector>
static Vm2_cdda *t;
static uint32_t rnd = 77;
static uint32_t rn() { rnd = rnd * 1103515245 + 12345; return rnd >> 8; }
static const uint32_t SECT = 2352;
static uint8_t img(uint64_t o) { uint32_t x = uint32_t(o) * 2654435761u; return x >> 24; }
static int errs;
static int wait_n, send; static uint64_t sa; static bool acked;
static int dac_n;
static uint32_t maxwait = 3000;
static void tick()
{
	t->tick = ++dac_n >= 1512;
	if (t->tick) dac_n = 0;
	t->sd_ack = acked; t->sd_wr = 0;
	if (!acked && t->sd_rd)
	{
		if (wait_n == 0) wait_n = 1 + rn() % maxwait;
		else if (--wait_n == 0) { acked = true; send = 4096; sa = uint64_t(t->sd_lba) * 512; t->sd_ack = 1; }
	}
	else if (acked)
	{
		if (send > 0) { if (rn() % 4 == 0) { t->sd_wr = 1; t->sd_d = img(sa++); send--; } }
		else if (rn() % 8 == 0) { acked = false; t->sd_ack = 0; }
	}
	t->eval();
	t->clk = 1; t->eval(); t->clk = 0; t->eval();
	t->play = 0; t->stop = 0;
}
static void play_check(uint32_t lba, uint32_t len, int upto)
{
	t->play = 1; t->lba = lba; t->len = len;
	tick();
	uint64_t off = uint64_t(lba - 150) * SECT;
	int n = 0, got = 0, skipped = 0;
	uint32_t pl = 0, pr = 0; bool have = false;
	// the first sample is whichever follows the fill; then one a tick
	uint32_t next = 0;
	for (long c = 0; c < long(upto) * 1512 + 2000000 && n < upto; c++)
	{
		bool tk = dac_n == 1511;
		tick();
		if (tk)
		{
			for (int i = 0; i < 8; i++) tick();
			uint32_t l = t->l, r = t->r;
			if (l == 0 && r == 0 && !got) { skipped++; continue; }
			uint32_t wl = img(off + next * 4) | img(off + next * 4 + 1) << 8, wr = img(off + next * 4 + 2) | img(off + next * 4 + 3) << 8;
			if (l != wl || r != wr) { if (errs++ < 10) printf("FAIL sample %u: %04X %04X, wanted %04X %04X\n", next, l, r, wl, wr); }
			next++; got++; n++;
		}
	}
	(void)pl; (void)pr; (void)have;
	printf("lba %u: %d samples, %d ticks before the first\n", lba, got, skipped);
	if (got < upto) { printf("FAIL too few\n"); errs++; }
}
int main(int argc, char **argv)
{
	Verilated::commandArgs(argc, argv);
	t = new Vm2_cdda;
	t->rst = 1; for (int i = 0; i < 8; i++) tick(); t->rst = 0;
	t->mounted = 1;
	play_check(12078, 1000, 5000);
	play_check(211128, 1000, 7000);     // (in the middle of what went before)
	maxwait = 100;
	// to the end
	t->play = 1; t->lba = 20000; t->len = 3;
	tick();
	uint32_t p0 = t->pos;
	for (long c = 0; c < 3000000 && t->playing; c++) tick();
	if (t->playing || !t->finished) { printf("FAIL doesn't finish\n"); errs++; }
	if (t->pos != 20003 || p0 != 20000) { printf("FAIL position %u (from %u)\n", t->pos, p0); errs++; }
	printf(errs ? "FAIL %d errors\n" : "PASS\n", errs);
	return errs != 0;
}
