// tb_tk: m2_tk with HZ = 100 (a second is 100 clocks): the RTC load, the counting (month ends, leap years, the year), the day of the
// week, R holding the bytes, W setting the clock, the CPU's and the save's reads, chg
#include "Vm2_tk.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

static Vm2_tk *t;
static int fails = 0;

static void clk()
{
	t->clk = 0; t->eval();
	t->clk = 1; t->eval();
}

static void secs(int n) { for (int i = 0; i < 100 * n; i++) clk(); }   // (built with HZ = 100: each check reads in fewer clocks)

static uint8_t rd(int a)
{
	t->cpu_rd = 1; t->ra = a; clk(); t->cpu_rd = 0;
	return t->rd;
}

static void wr(int a, int d)
{
	t->we = 1; t->wa = a; t->wd = d; clk(); t->we = 0;
}

static void rtc(int s, int m, int h, int date, int mon, int yr, int wday)
{
	// the RTC's words: [7:0] s, [15:8] m, [23:16] h, [31:24] date, [39:32] mon, [47:40] yr, [55:48] wday; [64] toggles
	t->rtc[0] = s | (m << 8) | (h << 16) | (date << 24);
	t->rtc[1] = mon | (yr << 8) | (wday << 16) | (0x40 << 24);
	t->rtc[2] ^= 1;
	clk(); clk();
}

static void expect(const char *what, int a, int want)
{
	int got = rd(a);
	if (got != want) { printf("FAIL %s: %04x = %02x, want %02x\n", what, a, got, want); fails++; }
}

static void time_is(const char *what, int s, int m, int h, int day, int date, int mon, int yr)
{
	expect(what, 0x1ff9, s); expect(what, 0x1ffa, m); expect(what, 0x1ffb, h); expect(what, 0x1ffc, day);
	expect(what, 0x1ffd, date); expect(what, 0x1ffe, mon); expect(what, 0x1fff, yr);
}

int main(int argc, char **argv)
{
	Verilated::commandArgs(argc, argv);
	t = new Vm2_tk;
	t->rtc[0] = t->rtc[1] = t->rtc[2] = 0;
	t->ld_we = 0; t->we = 0; t->cpu_rd = 0; t->ua = 0;
	for (int i = 0; i < 4; i++) clk();

	// power-up: 2000-01-01 00:00:00, a Saturday (7)
	time_is("power-up", 0x00, 0x00, 0x00, 0x07, 0x01, 0x01, 0x00);

	// the RTC: 2026-11-17 23:59:58, a Tuesday (wday 2, the chip's 3)
	rtc(0x58, 0x59, 0x23, 0x17, 0x11, 0x26, 2);
	time_is("rtc", 0x58, 0x59, 0x23, 0x03, 0x17, 0x11, 0x26);
	secs(2);
	time_is("midnight", 0x00, 0x00, 0x00, 0x04, 0x18, 0x11, 0x26);

	// month ends: 2026-11-30 23:59:59 -> 12-01; 12-31 -> 2027-01-01; Saturday -> Sunday wraps 7 -> 1
	rtc(0x59, 0x59, 0x23, 0x30, 0x11, 0x26, 1);
	secs(1); time_is("nov 30", 0x00, 0x00, 0x00, 0x03, 0x01, 0x12, 0x26);
	rtc(0x59, 0x59, 0x23, 0x31, 0x12, 0x26, 6);
	secs(1); time_is("new year", 0x00, 0x00, 0x00, 0x01, 0x01, 0x01, 0x27);
	// February: 2027 (not leap) 02-28 -> 03-01; 2028 (leap) 02-28 -> 02-29 -> 03-01; 2000 leap, 2100 not reachable (99 -> 00)
	rtc(0x59, 0x59, 0x23, 0x28, 0x02, 0x27, 0);
	secs(1); time_is("feb 2027", 0x00, 0x00, 0x00, 0x02, 0x01, 0x03, 0x27);
	rtc(0x59, 0x59, 0x23, 0x28, 0x02, 0x28, 1);
	secs(1); time_is("feb 28 2028", 0x00, 0x00, 0x00, 0x03, 0x29, 0x02, 0x28);
	rtc(0x59, 0x59, 0x23, 0x29, 0x02, 0x28, 2);
	secs(1); time_is("feb 29 2028", 0x00, 0x00, 0x00, 0x04, 0x01, 0x03, 0x28);
	rtc(0x59, 0x59, 0x23, 0x28, 0x02, 0x32, 1);
	secs(1); time_is("feb 2032", 0x00, 0x00, 0x00, 0x03, 0x29, 0x02, 0x32);
	rtc(0x59, 0x59, 0x23, 0x28, 0x02, 0x30, 1);
	secs(1); time_is("feb 2030", 0x00, 0x00, 0x00, 0x03, 0x01, 0x03, 0x30);
	rtc(0x59, 0x59, 0x23, 0x30, 0x04, 0x26, 1);
	secs(1); time_is("apr 30", 0x00, 0x00, 0x00, 0x03, 0x01, 0x05, 0x26);
	rtc(0x59, 0x59, 0x23, 0x31, 0x12, 0x99, 1);
	secs(1); time_is("2099", 0x00, 0x00, 0x00, 0x03, 0x01, 0x01, 0x00);
	// BCD carries: 09 -> 10, 19 -> 20
	rtc(0x09, 0x19, 0x09, 0x09, 0x09, 0x09, 1);
	secs(1); time_is("bcd", 0x10, 0x19, 0x09, 0x02, 0x09, 0x09, 0x09);

	// R: the bytes hold still while the clock goes on
	rtc(0x00, 0x30, 0x12, 0x20, 0x11, 0x26, 5);
	wr(0x1ff8, 0x40);
	secs(3);
	expect("R holds", 0x1ff9, 0x00);
	expect("control", 0x1ff8, 0x40);
	wr(0x1ff8, 0x00); clk();
	expect("R cleared", 0x1ff9, 0x03);

	// W: write the bytes, clear W: the clock from them (the flag bits dropped)
	wr(0x1ff8, 0x80);
	wr(0x1ff9, 0x80 | 0x45); wr(0x1ffa, 0x10); wr(0x1ffb, 0x08); wr(0x1ffc, 0x02); wr(0x1ffd, 0x05); wr(0x1ffe, 0x06); wr(0x1fff, 0x24);
	secs(2);
	expect("W holds", 0x1ffa, 0x10);
	wr(0x1ff8, 0x00); clk();
	time_is("W set", 0x45, 0x10, 0x08, 0x02, 0x05, 0x06, 0x24);
	secs(15);
	time_is("W runs", 0x00, 0x11, 0x08, 0x02, 0x05, 0x06, 0x24);

	// memory: the download, the CPU's writes and reads, chg only below 0x1ff8, the save's reads
	t->ld_we = 1; t->ld_a = 0x0000; t->ld_d = 'G'; clk(); t->ld_we = 0;
	expect("loaded", 0x0000, 'G');
	t->we = 1; t->wa = 0x004a; t->wd = 0x12; t->clk = 0; t->eval();
	if (!t->chg) { printf("FAIL chg on a write to 0x004a\n"); fails++; }
	clk(); t->we = 0;
	t->we = 1; t->wa = 0x1ff8; t->wd = 0x00; t->clk = 0; t->eval();
	if (t->chg) { printf("FAIL chg on a write to the control register\n"); fails++; }
	clk(); t->we = 0;
	expect("written", 0x004a, 0x12);
	t->ua = 0x004a; clk(); clk(); clk();
	if (t->ud != 0x12) { printf("FAIL save read: %02x\n", t->ud); fails++; }
	t->ua = 0x0000; clk(); clk(); clk();
	if (t->ud != 'G') { printf("FAIL save read 0: %02x\n", t->ud); fails++; }

	printf(fails ? "tb_tk: %d FAIL\n" : "tb_tk: PASS\n", fails);
	delete t;
	return fails != 0;
}
