// tb_dcbz [runs] [seed] [lat]: dcbz on the pipeline with its caches (sim/ppccore/ppc_cached.sv), self-checking. A directed test:
// sim/ppccore's random programs only now and then load what a dcbz has just zeroed.
//
// Two 32-byte lines, one cached (bit 14 of the address clear) and one not (set: ppc_cached's d_cacheable), and their neighbors
// filled with a known pattern; each run takes one of five ways in to dcbz:
//   0: the line not in the cache (a cold dcbz);
//   1: the line loaded first (in the cache: dcbz's stores hit and write the line);
//   2: eight stores to the line just before (the store buffer full of them, the memory slow or busy when lat is 1);
//   3: as 2, then dcbz twice;
//   4: dcbz, then at once stores of a byte, a half and a word into the line (they must win).
// Then every byte, every half at every offset (odd ones too) and every word at every offset of the line are loaded and stored
// to a results area; at the end (the store buffer drained) the results must be the line's expected bytes, big-endian, and memory
// must hold the zeros (and 4's stores) in the line and the pattern untouched around it. Random memory latency and busy (lat 1),
// and snoops of the lines in use, as tb_eeloop. Any difference is printed. Build: run_dcbz.sh (DEFS as run.sh's).
#include "Vppc_cached.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <deque>
#include <random>
#include <vector>

typedef Vppc_cached Vtop;
static const uint32_t BASE = 0x00010000;            // the program
static const uint32_t LC = 0x00100100;              // the cached line
static const uint32_t LU = 0x00104100;              // the uncached line (bit 14)
static const uint32_t RES = 0x00110000;             // the results (cached)

static std::vector<uint8_t> mem(0x200000);
static uint32_t rd32(uint32_t a) { return uint32_t(mem[a]) << 24 | uint32_t(mem[a + 1]) << 16 | uint32_t(mem[a + 2]) << 8 | mem[a + 3]; }
static void wr32(uint32_t a, uint32_t v) { mem[a] = v >> 24; mem[a + 1] = v >> 16; mem[a + 2] = v >> 8; mem[a + 3] = v; }

static uint32_t D(int op, int d, int a, int imm) { return uint32_t(op) << 26 | d << 21 | a << 16 | (imm & 0xffff); }
static uint32_t X(int d, int a, int b, int xo, int rc = 0) { return 31u << 26 | d << 21 | a << 16 | b << 11 | xo << 1 | rc; }
static uint32_t li(int d, int i) { return D(14, d, 0, i); }
static uint32_t lis(int d, int i) { return D(15, d, 0, i); }
static uint32_t ori(int a, int s, int i) { return D(24, s, a, i); }
static uint32_t lbz(int d, int a, int o) { return D(34, d, a, o); }
static uint32_t lhz(int d, int a, int o) { return D(40, d, a, o); }
static uint32_t lwz(int d, int a, int o) { return D(32, d, a, o); }
static uint32_t stb(int s, int a, int o) { return D(38, s, a, o); }
static uint32_t sth(int s, int a, int o) { return D(44, s, a, o); }
static uint32_t stw(int s, int a, int o) { return D(36, s, a, o); }
static uint32_t dcbz(int a, int b) { return X(0, a, b, 1014); }
static uint32_t b(uint32_t from, uint32_t to) { return 18u << 26 | ((to - from) & 0x03fffffc); }

int main(int argc, char **argv)
{
	Verilated::commandArgs(argc, argv);
	long runs = argc > 1 ? atol(argv[1]) : 40;
	uint64_t seed = argc > 2 ? strtoull(argv[2], 0, 0) : 1;
	int lat = argc > 3 ? atoi(argv[3]) : 1;
	std::mt19937_64 rng(seed);
	Vtop top;
	long bad = 0, tot_cyc = 0, tot_loads = 0;
	for (long run = 0; run < runs && bad < 3; run++)
	{
		int way = int(run % 5);
		uint32_t line = (run / 5) % 2 ? LU : LC;
		std::fill(mem.begin(), mem.end(), 0);
		// the pattern: the line, a line each side
		for (uint32_t a = line - 32; a < line + 64; a++) mem[a] = uint8_t(0x11 + 7 * (a - line + 32) + (rng() % 4) * 64) | 1;
		std::vector<uint8_t> want(mem.begin() + (line - 32), mem.begin() + (line + 64));   // what memory must hold after
		uint8_t *wl = &want[32];                                                            // ... the line in it
		uint32_t p = BASE + 0x1000, done;
		auto put = [&](uint32_t op) { wr32(p, op); p += 4; };
		put(lis(30, line >> 16)); put(ori(30, 30, line & 0xffff));
		put(lis(29, RES >> 16)); put(ori(29, 29, RES & 0xffff));
		put(lis(5, 0x5a5a)); put(ori(5, 5, 0xa55a));
		if (way == 1) for (int o = 0; o < 32; o += 8) put(lwz(6, 30, o));
		if (way == 2 || way == 3)
		{
			for (int o = 0; o < 32; o += 4) put(stw(5, 30, o));
			for (int o = 0; o < 32; o++) wl[o] = uint8_t(0x5a5aa55a >> (24 - 8 * (o & 3)));
		}
		put(dcbz(0, 30));
		if (way == 3) put(dcbz(0, 30));
		for (int o = 0; o < 32; o++) wl[o] = 0;
		if (way == 4)
		{
			// a byte at 3, a half at 9 (odd: across nothing), a word at 20
			put(stb(5, 30, 3)); put(sth(5, 30, 9)); put(stw(5, 30, 20));
			wl[3] = 0x5a; wl[9] = 0xa5; wl[10] = 0x5a;
			wl[20] = 0x5a; wl[21] = 0x5a; wl[22] = 0xa5; wl[23] = 0x5a;
		}
		// the loads, each stored to the results; (expected value, size) of each, in order
		std::vector<std::pair<uint32_t, int>> ex;
		int k = 0;
		auto be = [&](int o, int n) { uint32_t v = 0; for (int i = 0; i < n; i++) v = v << 8 | wl[o + i]; return v; };
		for (int o = 0; o < 32; o++) { put(lbz(7, 30, o)); put(stw(7, 29, 4 * k++)); ex.push_back({ be(o, 1), 1 }); }
		for (int o = 0; o < 31; o++) { put(lhz(7, 30, o)); put(stw(7, 29, 4 * k++)); ex.push_back({ be(o, 2), 2 }); }
		for (int o = 0; o < 29; o++) { put(lwz(7, 30, o)); put(stw(7, 29, 4 * k++)); ex.push_back({ be(o, 4), 4 }); }
		done = p; put(b(p, p));

		top.rst = 1; top.dbg_hold = 0; top.dbg_int = 0; top.dbg_we = 0; top.int_ext = 0; top.dec_tick = 0; top.tb_tick = 0;
		top.mem_busy = 0; top.mem_ready = 0; top.sn_v = 0;
		top.clk = 0; top.eval(); top.clk = 1; top.eval();
		auto load = [&](int idx, uint64_t v) { top.dbg_we = 1; top.dbg_idx = idx; top.dbg_val = v; top.clk = 0; top.eval(); top.clk = 1; top.eval(); };
		for (int i = 0; i < 32; i++) load(i, 0);
		load(64, BASE + 0x1000);
		load(65, 0); load(66, 0);
		load(67, 0x00001030);                                  // MSR: ME, IR, DR (no interrupts)
		load(69, 0x7fffffff);                                  // DEC
		load(1024 + 986, BASE);                                // IBR
		load(1024 + 1008, 0);                                  // HID0
		load(1024 + 528, (0x7ff << 2) | 3); load(1024 + 529, 2);   // IBAT0: 256 MB at 0, RW
		load(1024 + 536, (0x7ff << 2) | 3); load(1024 + 537, 2);   // DBAT0
		top.dbg_we = 0;
		top.rst = 0;

		struct beat { uint64_t d; int wait; };
		std::deque<beat> rq;
		int busy = !lat ? 0 : rng() % 3 ? 25 : 70;
		long cyc;
		bool fin = false;
		int drain = -1;
		for (cyc = 0; cyc < 2000000; cyc++)
		{
			top.clk = 0; top.eval();
			top.int_ext = 0; top.dec_tick = 0; top.tb_tick = 0;
			top.mem_busy = drain < 0 && int(rng() % 100) < busy;
			top.sn_v = drain < 0 && lat && rng() % 8 == 0;
			{
				uint32_t pick[4] = { line, line + 32, RES + 32 * uint32_t(rng() % 12), uint32_t(top.if_pa) };
				top.sn_a = pick[rng() % 4] >> 5;
			}
			top.mem_ready = !rq.empty() && rq.front().wait <= 0;
			if (top.mem_ready) top.mem_dout = rq.front().d;
			top.eval();
			if (top.mem_ready) rq.pop_front();
			for (auto &r : rq) r.wait--;
			if (!top.mem_busy && (top.mem_rd || top.mem_we))
			{
				uint32_t a = uint32_t(top.mem_a) << 3;
				if (top.mem_we) { for (int kk = 0; kk < 8; kk++) if (top.mem_be >> kk & 1) mem[a + kk] = uint8_t(top.mem_wd >> 8 * kk); }
				else
				{
					int wait = lat ? 2 + int(rng() % 12) : 1;
					for (int bb = 0; bb < int(top.mem_burst); bb++)
					{
						uint64_t v = 0;
						for (int kk = 7; kk >= 0; kk--) v = v << 8 | mem[a + 8 * bb + kk];
						rq.push_back({ v, wait + bb });
					}
				}
			}
			top.eval();
			top.clk = 1; top.eval();
			if (drain >= 0) { if (--drain == 0) break; continue; }
			if (top.retire)
			{
				uint32_t pcs[2] = { uint32_t(top.ipc_o), top.retire2 ? uint32_t(top.ipc0_o) : 0xffffffffu };
				for (uint32_t pc : pcs) if (pc == done && top.exc_o == 0) fin = true;
				if (top.exc_o != 0)
				{
					printf("run %ld way %d line %08X: exception %d at %08X\n", run, way, line, int(top.exc_o), uint32_t(top.ipc_o));
					break;
				}
				if (fin) drain = 400;   // (the store buffer drains)
			}
		}
		long wrong = 0;
		for (size_t i = 0; i < ex.size(); i++)
		{
			uint32_t got = rd32(RES + 4 * uint32_t(i));
			if (got != ex[i].first && ++wrong <= 6)
				printf("run %ld way %d line %08X: load %zu (%d bytes) read %08X, not %08X\n", run, way, line, i, ex[i].second, got, ex[i].first);
		}
		for (uint32_t a = line - 32; a < line + 64; a++)
			if (mem[a] != want[a - (line - 32)] && ++wrong <= 12)
				printf("run %ld way %d line %08X: memory %08X holds %02X, not %02X\n", run, way, line, a, mem[a], want[a - (line - 32)]);
		tot_cyc += cyc; tot_loads += long(ex.size());
		if (!fin || wrong)
		{
			bad++;
			printf("run %ld way %d line %08X: %s, %ld wrong\n", run, way, line, fin ? "finished" : "DID NOT FINISH", wrong);
		}
	}
	printf("%s: %ld runs, %ld loads checked, %ld clocks, %ld bad\n", bad ? "FAIL" : "PASS", runs, tot_loads, tot_cyc, bad);
	return bad != 0;
}
