// tb_m2boot: the bring-up machine (rtl/m2_boot.sv) on the boot ROM, its DDR3 a model with random wait states and read
// latency. Downloads the ROM through the loader (as the HPS would), releases reset, and checks each instruction it
// retires against the PCs of MAME's power-on trace (work/cap/boot/p1.pcs, from p1.tr by work/scripts/trpcs.py).
//
//   tb_m2boot rom pcs [-n instructions] [-seed n] [-fast] [-more clocks] [-cd image] [-ee eeprom] [-ata log]
//     -fast: DDR3 never busy, reads answered in 2 clocks; -more: after the trace, run on that many clocks (66.67 M a
//     second), printing where it is every million and each register stub access not seen before
#include "Vm2_boot.h"
#include "verilated.h"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <deque>
#include <map>
#include <random>
#include <vector>

static std::vector<uint8_t> slurp(const char *fn)
{
	FILE *f = fopen(fn, "rb");
	if (!f) { perror(fn); exit(1); }
	std::vector<uint8_t> v;
	uint8_t b[65536];
	size_t n;
	while ((n = fread(b, 1, sizeof b, f)) > 0) v.insert(v.end(), b, b + n);
	fclose(f);
	return v;
}

int main(int argc, char **argv)
{
	if (argc < 3) { fprintf(stderr, "tb_m2boot rom pcs [-n N] [-seed n] [-fast]\n"); return 2; }
	std::vector<uint8_t> rom = slurp(argv[1]);
	std::vector<uint8_t> pcb = slurp(argv[2]);
	std::vector<uint32_t> pcs(pcb.size() / 4);
	memcpy(pcs.data(), pcb.data(), pcs.size() * 4);
	size_t limit = pcs.size();
	unsigned seed = 1;
	bool fast = false;
	uint64_t more = 0;
	uint32_t from = 0;                     // -from pc: with -more, the PCs from that one on, to pcs.txt
	std::vector<uint32_t> p2pcs;           // -p2 pcs: ppc2's power-on trace, reported where it first differs
	size_t p2k = 0;
	bool p2off = false;
	uint32_t p2last[8] = {};
	FILE *ffull = nullptr, *faudio = nullptr;
	int snap = 0;                          // -snap n: every n frames the picture, frameNNNN.ppm
	int coin = -1, hist_from = -1;
	std::vector<uint8_t> ymz;
	bool evil = false;
	bool board = false;
	std::map<uint32_t, uint32_t> hist[2];
	FILE *fata = nullptr;                  // -ata file: each access to the CD drive, as work/lua/cd_ata.lua logs MAME's
	std::vector<uint8_t> cd, ee, tk;
	FILE *fpc = nullptr;
	long npc = 0;
	for (int i = 3; i < argc; i++)
	{
		if (!strcmp(argv[i], "-n") && i + 1 < argc) limit = std::min(limit, size_t(strtoull(argv[++i], 0, 0)));
		else if (!strcmp(argv[i], "-seed") && i + 1 < argc) seed = unsigned(strtoul(argv[++i], 0, 0));
		else if (!strcmp(argv[i], "-fast")) fast = true;
		else if (!strcmp(argv[i], "-from") && i + 1 < argc) from = uint32_t(strtoul(argv[++i], 0, 16));
		else if (!strcmp(argv[i], "-more") && i + 1 < argc) more = strtoull(argv[++i], 0, 0);
		else if (!strcmp(argv[i], "-cd") && i + 1 < argc) cd = slurp(argv[++i]);
		else if (!strcmp(argv[i], "-snap") && i + 1 < argc) snap = atoi(argv[++i]);
		else if (!strcmp(argv[i], "-coin") && i + 1 < argc) coin = atoi(argv[++i]);    // at this frame a coin, then start and the buttons in turn
		else if (!strcmp(argv[i], "-board")) board = true;                             // memory about as the board's
		else if (!strcmp(argv[i], "-hist") && i + 1 < argc) hist_from = atoi(argv[++i]); // from this frame, every 120 frames, the PCs most retired
		else if (!strcmp(argv[i], "-ee") && i + 1 < argc) ee = slurp(argv[++i]);
		else if (!strcmp(argv[i], "-ymz") && i + 1 < argc) ymz = slurp(argv[++i]);                  // the YMZ280B's samples (Evil Night)
		else if (!strcmp(argv[i], "-evil")) evil = true;                                  // the coin, start and trigger where Evil Night has them
		else if (!strcmp(argv[i], "-tk") && i + 1 < argc) { tk = slurp(argv[++i]); tk.push_back(1); }  // the M48T58, then the board's byte: RAM 2 x 8 MB
		else if (!strcmp(argv[i], "-ata") && i + 1 < argc) fata = fopen(argv[++i], "w");
		else if (!strcmp(argv[i], "-full") && i + 1 < argc) ffull = fopen(argv[++i], "rb");     // the disc's raw image, as the SD card has it
		else if (!strcmp(argv[i], "-audio") && i + 1 < argc) faudio = fopen(argv[++i], "wb");   // what comes out: 16-bit stereo at 44.1 kHz
		else if (!strcmp(argv[i], "-p2") && i + 1 < argc)
		{
			std::vector<uint8_t> b = slurp(argv[++i]);
			p2pcs.resize(b.size() / 4);
			memcpy(p2pcs.data(), b.data(), p2pcs.size() * 4);
		}
	}
	std::mt19937 rng(seed);

	// DDR3 from 0x30000000: 104 MB, 8-byte words; the CD image from 0x32000000, loaded directly (it would take 24 M clocks)
	const uint32_t BASE = 0x30000000u >> 3, WORDS = 13u << 20, CDW = 0x02000000u >> 3;
	std::vector<uint64_t> ddr(WORDS, 0);
	for (size_t i = 0; i < cd.size(); i++) ddr[CDW + i / 8] |= uint64_t(cd[i]) << 8 * (i % 8);
	for (size_t i = 0; i < ymz.size(); i++) ddr[0x6000000 / 8 + i / 8] |= uint64_t(ymz[i]) << 8 * (i % 8);
	struct rd { uint64_t d; int wait; };
	std::deque<rd> rq;

	static uint8_t sd_buf[4096];
	int sd_left = 0, sd_wait = 0, sd_div = 0, au_div = 0;
	Vm2_boot t;
	t.clk = 0; t.rst = 1; t.ld_wr = 0; t.ld_sel = 0; t.ddr_busy = 0; t.ddr_dout_ready = 0;
	t.cd_mounted = ffull != nullptr; t.sd_ack = 0; t.sd_wr = 0;
	t.in_p1 = 0xff; t.in_dsw = 0xff; t.in_p4 = 0xffff; t.in_p6 = 0xffff; t.in_p5 = 0xffff;
	for (int i = 0; i < 3; i++) { t.gun_x[i] = 320; t.gun_y[i] = 120; }
	t.eval();

	uint64_t cyc = 0;
	bool bad = false;
	// one clock: the DDR3 model's outputs for this clock, then the edge
	uint32_t ata_n = 0;
	// the raster, as rtl/m2_vtiming.sv
	int r_div = 0, r_h = 0, r_v = 0, r_frame = 0;
	std::vector<uint8_t> pic(640 * 240 * 3);
	auto clock = [&]() {
		if (++r_div == 5)
		{
			r_div = 0;
			int x = r_h - 172, y = r_v - 20;
			if (snap && x >= 0 && x < 640 && y >= 0 && y < 240)
			{
				uint8_t *p = &pic[3 * (640 * y + x)];
				p[0] = t.rgb >> 16; p[1] = t.rgb >> 8; p[2] = t.rgb;
			}
			if (++r_h == 857)
			{
				r_h = 0;
				if (++r_v == 262)
				{
					r_v = 0;
					if (snap && r_frame % snap == 0)
					{
						char fn[64];
						snprintf(fn, sizeof fn, "frame%04d.ppm", r_frame);
						FILE *f = fopen(fn, "wb");
						if (f) { fprintf(f, "P6\n640 240\n255\n"); fwrite(pic.data(), 1, pic.size(), f); fclose(f); }
					}
					r_frame++;
					if (coin >= 0)
					{
						int d = r_frame - coin;
						t.in_p1 = 0xff & ~((d >= 0 && d < 8) ? 1 : 0) & ~((d >= 120 && d % 240 < 8) ? 16 : 0);
						if (evil)
						{
							t.in_p1 = 0xff & ~((d >= 0 && d < 8) ? 1 : 0);
							t.in_p4 = 0xffff & ~((d >= 120 && d % 240 < 8) ? 0x80 : 0);
							t.in_p5 = 0xffff & ~((d >= 300 && d % 40 < 6) ? 0x100 : 0);
						}
						else
						{
						int b = 0;
						for (int q = 0; q < 4; q++) if (d >= 240 && (d + 40 * q) % 120 < 8) b |= 16 << q;
						t.in_p4 = 0xffff & ~b;
						}
					}
					if (hist_from >= 0 && r_frame >= hist_from && (r_frame - hist_from) % 120 == 119)
						for (int j = 0; j < 2; j++)
						{
							std::vector<std::pair<uint32_t, uint32_t>> h;
							uint64_t all = 0;
							for (auto &e : hist[j]) { h.push_back({ e.second, e.first }); all += e.second; }
							std::sort(h.rbegin(), h.rend());
							printf("HIST f%d ppc%d %llu:", r_frame, j + 1, (unsigned long long)all);
							for (size_t q = 0; q < h.size() && q < 24; q++) printf(" %08X=%u", h[q].second, h[q].first);
							printf("\n");
							fflush(stdout);
							hist[j].clear();
						}
				}
			}
			t.hpos = (r_h - 172) & 1023;
			t.vpos = (r_v - 20) & 511;
		}
		// the SD card: 4 KB a go, after a while
		t.sd_wr = 0;
		if (sd_left == 0 && !t.sd_ack && t.sd_rd)
		{
			if (sd_wait == 0) sd_wait = 2000 + rng() % 20000;
			else if (--sd_wait == 0)
			{
				fseek(ffull, long(uint64_t(t.sd_lba) * 512), SEEK_SET);
				size_t got = fread(sd_buf, 1, 4096, ffull);
				if (got < 4096) memset(sd_buf + got, 0, 4096 - got);
				sd_left = 4096; t.sd_ack = 1;
			}
		}
		else if (sd_left > 0)
		{
			if (++sd_div == 8) { sd_div = 0; t.sd_wr = 1; t.sd_d = sd_buf[4096 - sd_left]; sd_left--; }
		}
		else if (t.sd_ack && ++sd_div == 8) { sd_div = 0; t.sd_ack = 0; }
		if (faudio && ++au_div == 1512)
		{
			au_div = 0;
			int16_t a[2] = { int16_t(t.audio_l), int16_t(t.audio_r) };
			fwrite(a, 2, 2, faudio);
		}
		if (hist_from >= 0 && r_frame >= hist_from)
		{
			if (t.retire) hist[0][t.ipc_o & ~31u]++;
			if (t.p2_retire) hist[1][t.p2_ipc_o & ~31u]++;
		}
		t.ddr_busy = fast ? 0 : board ? (rng() % 4 != 0) : (rng() % 4 == 0);
		t.ddr_dout_ready = 0;
		if (!rq.empty() && rq.front().wait <= 0)
		{
			t.ddr_dout_ready = 1;
			t.ddr_dout = rq.front().d;
		}
		t.eval();
		if (!t.ddr_busy && (t.ddr_rd || t.ddr_we))
		{
			uint32_t w = t.ddr_addr;
			int burst = t.ddr_burstcnt;
			if (w < BASE || w + burst > BASE + WORDS || (burst != 1 && !(burst == 4 && !t.ddr_we && (w & 3) == 0))) { printf("DDR3 access out of range: %08X, burst %d\n", w, burst); bad = true; }
			else if (t.ddr_we)
			{
				uint64_t &m = ddr[w - BASE];
				for (int b = 0; b < 8; b++)
					if (t.ddr_be >> b & 1) m = (m & ~(0xffull << 8 * b)) | (uint64_t(t.ddr_din) & (0xffull << 8 * b));
			}
			else
			{
				// (a line's words one a clock, after the delay)
				int wait = fast ? 1 : board ? 30 : 2 + int(rng() % 12);
				for (int k = 0; k < burst; k++) rq.push_back({ ddr[w - BASE + k], wait + k });
			}
		}
		if (t.ddr_dout_ready) rq.pop_front();
		for (auto &r : rq) r.wait--;
		t.clk = 1; t.eval();
		t.clk = 0; t.eval();
		cyc++;
		if (fata && t.st_ndev != ata_n)
		{
			ata_n = t.st_ndev;
			if ((t.st_dev_a >> 24) == 0x3f || (t.st_dev_a >> 20) == 0x376)
				fprintf(fata, "1 %c %X 10 %X pc%08X f%llu\n", t.st_dev_w ? 'w' : 'r', t.st_dev_a, t.st_dev_d & 0xffff, t.st_pc[0], (unsigned long long)(cyc / 1122000));
		}
		if (t.p2_retire && !p2off && p2k < p2pcs.size())
			for (int j = t.p2_retire2 ? 0 : 1; j < 2 && !p2off; j++)
			{
				uint32_t pc = j ? t.p2_ipc_o : t.p2_ipc0_o;
				if (p2k < p2pcs.size() && pc != p2pcs[p2k])
				{
					printf("ppc2 instruction %zu: RTL %08X, MAME %08X (clock %llu); RTL before:", p2k, pc, p2pcs[p2k], (unsigned long long)cyc);
					for (int q = 0; q < 8; q++) printf(" %08X", p2last[q]);
					printf("\n  MAME next:");
					for (size_t q = p2k; q < p2k + 8 && q < p2pcs.size(); q++) printf(" %08X", p2pcs[q]);
					printf("\n");
					p2off = true;
				}
				memmove(p2last, p2last + 1, 7 * 4); p2last[7] = pc;
				p2k++;
			}
	};

	// the download, then 16 clocks more in reset
	for (size_t i = 0; i < rom.size(); )
	{
		t.ld_wr = !t.ld_wait;
		if (t.ld_wr) { t.ld_addr = uint32_t(i); t.ld_data = rom[i]; i++; }
		clock();
		t.ld_wr = 0;
	}
	t.ld_sel = 2;
	for (size_t i = 0; i < ee.size(); i++)
	{
		t.ld_wr = 1; t.ld_addr = uint32_t(i); t.ld_data = ee[i];
		clock();
		t.ld_wr = 0;
	}
	t.ld_sel = 3;
	for (size_t i = 0; i < tk.size(); i++)
	{
		t.ld_wr = 1; t.ld_addr = uint32_t(i); t.ld_data = tk[i];
		clock();
		t.ld_wr = 0;
	}
	t.ld_sel = 0;
	for (int i = 0; i < 16; i++) clock();
	uint64_t ldcyc = cyc;
	for (uint32_t w = 0; w < rom.size() / 8; w++)
	{
		uint64_t e = 0;
		for (int b = 0; b < 8; b++) e |= uint64_t(rom[8 * w + b]) << 8 * b;
		if (ddr[w] != e) { printf("download: word %u is %016llX, not %016llX\n", w, (unsigned long long)ddr[w], (unsigned long long)e); return 1; }
	}
	printf("downloaded %zu bytes in %llu clocks\n", rom.size(), (unsigned long long)ldcyc);
	t.rst = 0;

	size_t k = 0;
	uint64_t last = cyc, start = cyc;
	auto check = [&](uint32_t pc) {
		if (k < limit && pc != pcs[k])
		{
			printf("instruction %zu: RTL %08X, MAME %08X (clock %llu)\n", k, pc, pcs[k], (unsigned long long)(cyc - start));
			printf("  MAME before:");
			for (size_t j = k >= 8 ? k - 8 : 0; j < k; j++) printf(" %08X", pcs[j]);
			printf("\n");
			bad = true;
		}
		k++;
	};
	while (k < limit && !bad)
	{
		clock();
		if (t.retire)
		{
			if (t.retire2) check(t.ipc0_o);
			if (!bad) check(t.ipc_o);
			last = cyc;
		}
		if (cyc - last > 100000) { printf("instruction %zu: nothing retired for 100000 clocks (MAME %08X)\n", k, pcs[k]); bad = true; }
	}
	printf("%s: %zu instructions in %llu clocks (%.2f clocks an instruction), last PC %08X; status: pc %08X count %u exc %u/%u, %u register accesses, last %08X %s %08X\n",
		bad ? "FAIL" : "PASS", std::min(k, limit), (unsigned long long)(cyc - start), double(cyc - start) / double(std::max<size_t>(k, 1)),
		k ? pcs[std::min(k, limit) - 1] : 0, t.st_pc[0], t.st_count[0], t.st_exc[0], t.st_nexc[0], t.st_ndev, t.st_dev_a, t.st_dev_w ? "<-" : "->", t.st_dev_d);
#ifdef MPEG_HPS_CHECK
	{
		// a build with MPEG_CTL and MPEG_HPS (-CFLAGS -DMPEG_HPS_CHECK): the block the MPEG unit shares with the ARM, at DDR3 0x30400000,
		// as its reset leaves it through the bus: the header, the count, the line the ARM writes and the log clear
		const uint32_t mb = 0x00400000u >> 3;
		int nz = 0;
		for (uint32_t i = 0; i < 4096; i++) if (ddr[mb + 0x200 + i]) nz++;
		for (uint32_t i = 8; i < 12; i++) if (ddr[mb + i]) nz++;
		bool ok = ddr[mb] == 0x4D324D5000010C12ull && nz == 0 && ddr[mb + 1] <= (cyc >> 20) && ddr[mb + 1] + 1 >= ((cyc - ldcyc) >> 20);
		printf("MPEG block: header %016llX, count %llu after %llu clocks, %d words of the log and the ARM's line not clear: %s\n", (unsigned long long)ddr[mb],
			(unsigned long long)ddr[mb + 1], (unsigned long long)cyc, nz, ok ? "as it should be" : "WRONG");
		if (!ok) bad = true;
	}
#endif
#ifdef MPEG_HPS_TEST
	// A build with MPEG_CTL and MPEG_HPS, run on a test ROM (made outside this repo) with
	// -n 0 -more N: the CPU gives the MPEG unit one picture after another (its data put in RAM here) and waits for each one's
	// end-of-picture bit; this bench is the ARM's side, in the DDR3 block at 0x30400000. So the unit's log, ring, line read and hold
	// go through the real register path, m2_bus and m2_boot. Checked: every log entry against the CPU's writes (seen at the
	// register access itself) and the pictures' ends; each picture's bytes in the ring; the first two pictures let go at once (no
	// "MPGD" yet); the later ones only after this bench has written their done word (3 ms after the end entry), and within a
	// poll of it.
	const uint32_t mt_mb = 0x00400000u >> 3;
	const int MT_L = 3005, MT_TOT = 3016, MT_NP = 6;
	auto mt_byte = [&](int pic, int j) -> uint8_t {
		if (j < MT_L - 4) return uint8_t(1 + (uint32_t(pic * 7919 + j) * 2654435761u >> 16) % 255);
		if (j < MT_L) return j == MT_L - 2 ? 1 : 0;          // 00 00 01 00: the start code that ends the picture
		return uint8_t(0xa0 + j % 16);
	};
	for (int i = 0; i < MT_NP + 4; i++)
		for (int j = 0; j < MT_TOT; j++)
		{
			uint32_t a = 0x01100000u + uint32_t(i) * 0x2000 + uint32_t(j);
			ddr[a / 8] = (ddr[a / 8] & ~(0xffull << 8 * (a % 8))) | uint64_t(mt_byte(i, j)) << 8 * (a % 8);
		}
	struct mt_ent { uint32_t kind; uint64_t payload; };
	std::deque<mt_ent> mt_exp;
	uint32_t mt_nd = t.st_ndev, mt_nlog = 0, mt_pos = 0, mt_seq = 0, mt_hb = 0;
	int mt_ends = 0, mt_done_pics = 0, mt_bad = 0;
	bool mt_attached = false, mt_end_open = false;
	uint64_t mt_end_clock = 0, mt_done_at = 0, mt_done_clock = 0, mt_once_max = 0, mt_held_min = ~0ull, mt_held_max = 0, mt_after_done_max = 0;
	auto mt_clock = [&]() {
		if (t.st_ndev != mt_nd)
		{
			mt_nd = t.st_ndev;
			if (t.st_dev_w && (t.st_dev_a >> 16) == 0x0008)
			{
				mt_exp.push_back({ 0, uint64_t((t.st_dev_a >> 2) & 0xff) << 32 | t.st_dev_d });
				if (t.st_dev_a == 0x00080004 && t.st_dev_d == 2)
				{
					mt_pos = (mt_pos + MT_L) & 0xffffff;
					mt_exp.push_back({ 1, uint64_t(MT_L) << 24 | mt_pos });
				}
				if (t.st_dev_a == 0x0008000c && (t.st_dev_d & 2) && t.st_dev_d != 0xff)     // (not the program's clear of all the bits)
				{
					// the CPU has seen the end-of-picture bit
					if (!mt_end_open) { printf("MPEG test: picture %d's end-of-picture bit before its end entry\n", mt_done_pics); mt_bad++; }
					else if (!mt_attached)
					{
						mt_once_max = std::max(mt_once_max, cyc - mt_end_clock);
						if (cyc - mt_end_clock > 3000) { printf("MPEG test: picture %d, no ARM side: let go after %llu clocks\n", mt_done_pics, (unsigned long long)(cyc - mt_end_clock)); mt_bad++; }
					}
					else if (!mt_done_clock) { printf("MPEG test: picture %d let go before its done word (%llu clocks after its end entry)\n", mt_done_pics, (unsigned long long)(cyc - mt_end_clock)); mt_bad++; }
					else
					{
						mt_held_min = std::min(mt_held_min, cyc - mt_end_clock); mt_held_max = std::max(mt_held_max, cyc - mt_end_clock);
						mt_after_done_max = std::max(mt_after_done_max, cyc - mt_done_clock);
						if (cyc - mt_done_clock > 16384 + 4000) { printf("MPEG test: picture %d let go %llu clocks after its done word\n", mt_done_pics, (unsigned long long)(cyc - mt_done_clock)); mt_bad++; }
					}
					mt_end_open = false; mt_done_clock = 0;
					mt_done_pics++;
					// (from the third picture on an ARM side is there)
					if (mt_done_pics == 2) { mt_attached = true; ddr[mt_mb + 8] = 0x4D50474400000000ull | ++mt_hb; }
				}
			}
		}
		if (mt_attached && cyc % 300000 == 0) ddr[mt_mb + 8] = 0x4D50474400000000ull | ++mt_hb;
		for (uint64_t e; (e = ddr[mt_mb + 0x200 + (mt_nlog & 4095)]) >> 63 && ((e >> 48) & 0x1fff) == mt_nlog; mt_nlog++)
		{
			uint32_t kind = uint32_t(e >> 61) & 3;
			uint64_t payload = e & 0xffffffffffffull;
			if (mt_exp.empty() || mt_exp.front().kind != kind || mt_exp.front().payload != payload)
			{
				printf("MPEG test: entry %u is kind %u %012llX, expected %s %012llX\n", mt_nlog, kind, (unsigned long long)payload, mt_exp.empty() ? "none" : mt_exp.front().kind ? "kind 1" : "kind 0",
					(unsigned long long)(mt_exp.empty() ? 0 : mt_exp.front().payload));
				mt_bad++;
			}
			if (!mt_exp.empty()) mt_exp.pop_front();
			if (kind == 1)
			{
				uint32_t pos = uint32_t(payload) & 0xffffff;
				for (int i = 0; i < MT_L; i++)
				{
					uint32_t a = 0x10000u + ((pos - MT_L + i) & 0x3ffff);
					if (uint8_t(ddr[mt_mb + a / 8] >> 8 * (a % 8)) != mt_byte(mt_ends, i)) { printf("MPEG test: picture %d's ring byte %d isn't its data\n", mt_ends, i); mt_bad++; break; }
				}
				mt_ends++; mt_seq = mt_nlog; mt_end_clock = cyc; mt_end_open = true;
				if (mt_attached) mt_done_at = cyc + 200000;
			}
		}
		if (mt_done_at && cyc >= mt_done_at) { ddr[mt_mb + 9] = 0x80000000ull | mt_seq; mt_done_clock = cyc; mt_done_at = 0; }
	};
#endif
	if (!bad && more)
	{
		// on past the trace: where it goes
		std::map<uint64_t, uint64_t> seen;     // register stub accesses: (address, write) -> times
		uint64_t lists = 0;                    // the Triangle Engine's, started
		uint32_t ndev = t.st_ndev;
		for (uint64_t c = 0; c < more; c++)
		{
			clock();
#ifdef MPEG_HPS_TEST
			mt_clock();
#endif
			if (from && t.retire)
			{
				if (!fpc && (t.ipc_o == from || (t.retire2 && t.ipc0_o == from))) fpc = fopen("pcs.txt", "w");
				if (fpc && npc < 8000000)
				{
					if (t.retire2) fprintf(fpc, "%08X\n", t.ipc0_o);
					fprintf(fpc, "%08X\n", t.ipc_o);
					npc++;
				}
			}
			if (t.st_ndev != ndev)
			{
				ndev = t.st_ndev;
				uint64_t key = uint64_t(t.st_dev_a) << 1 | t.st_dev_w;
				if (t.st_dev_a == 0x0004000C && t.st_dev_w) lists++;
				if (seen[key]++ == 0)
					printf("  clock %llu, %u retired, pc %08X %08X: first %s %08X (%08X)\n",(unsigned long long)c, t.st_count[0], t.st_pc[0], t.st_pc[1],
						t.st_dev_w ? "write" : "read ", t.st_dev_a, t.st_dev_d);
			}
			if (c % 1000000 == 999999)
				printf("clock %llu: ppc1 pc %08X, %u retired, exceptions %u (last %u); ppc2 pc %08X, %u retired, exceptions %u (last %u); %u register accesses, %llu lists\n",(unsigned long long)c + 1,
					t.st_pc[0], t.st_count[0], t.st_nexc[0], t.st_exc[0], t.st_pc[1], t.st_count[1], t.st_nexc[1], t.st_exc[1], t.st_ndev, (unsigned long long)lists);
		}
	}
#ifdef MPEG_HPS_TEST
	{
		bool ok = mt_bad == 0 && mt_done_pics >= MT_NP && ddr[mt_mb] == 0x4D324D5000010C12ull;
		printf("MPEG test: %d pictures given and let go, %u log entries (%zu of the CPU's writes not in the log yet), header %016llX\n", mt_done_pics, mt_nlog, mt_exp.size(),
			(unsigned long long)ddr[mt_mb]);
		printf("MPEG test: with no ARM side let go within %llu clocks of the end entry; with one, %llu-%llu clocks after it (the done word comes 200000 after), at most %llu after the done word: %s\n",
			(unsigned long long)mt_once_max, (unsigned long long)mt_held_min, (unsigned long long)mt_held_max, (unsigned long long)mt_after_done_max, ok ? "PASS" : "FAIL");
		if (!ok) bad = true;
	}
#endif
	if (fpc) fclose(fpc);
	if (fata) fclose(fata);
	return bad ? 1 : 0;
}
