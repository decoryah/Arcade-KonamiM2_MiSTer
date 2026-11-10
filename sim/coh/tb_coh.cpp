// tb_coh [clocks] [seed]: two caches (rtl/ppc_cache.sv) and the DMA on the bus (rtl/m2_bus.sv), with random traffic on a few lines
// that all land on few indexes, so they're always being evicted and refilled. Each 32-bit word has one writer, which writes a
// count that only goes up; then, for any reader, on either side of either cache:
//   - the writer's own loads read exactly what it last wrote;
//   - a reader's values of a word never go back;
//   - a load or fetch whose address clock is STALE clocks after DDR3 took a write reads that write or a later one.
// So a line kept after another master wrote it, a line refilled with older data, and a lost invalidate are all caught.
// The data sides are driven as rtl/ppc_pipe.sv does: up to two accesses out, a new one asked for in the clock an answer
// comes, and now and then a load dropped (d_kill) in its address clock.
#include "Vcoh_top.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <map>
#include <random>
#include <vector>

static const int STALE = 5;
static const int NWORDS = 64;

// addresses: lines 16 KB apart share a data index (ppc_cache's ways), 32 KB apart an instruction one; four lines on each
// of two data indexes, so the two ways are always evicting
static uint32_t word_addr(int w)
{
	int line = w / 8, off = w % 8;
	return 0x40000000u + ((line % 2) * 32) + (line / 2) * 0x4000u + off * 4;
}
static int writer_of(int w) { return (w + 1) / 2 % 3; }   // 0, 1: the caches; 2: the DMA (an odd word's next is the same one's)

struct wr { uint64_t t; uint32_t v; };

int main(int argc, char **argv)
{
	uint64_t clocks = argc > 1 ? strtoull(argv[1], 0, 0) : 2000000;
	unsigned seed = argc > 2 ? strtoul(argv[2], 0, 0) : 1;
	bool lat = seed & 1;
	std::mt19937 rng(seed);
	Vcoh_top t;

	std::map<uint32_t, uint64_t> ddr;           // by 8-byte word address
	struct rbeat { uint64_t d; int wait; };
	std::deque<rbeat> rq;

	uint32_t next[NWORDS];                      // the next count of each word
	uint32_t own[NWORDS];                       // what its writer last wrote
	std::deque<wr> taken[NWORDS];               // writes DDR3 has taken: (clock, value)
	uint32_t floor_[2][2][NWORDS] = {};         // [cache][side][word]: the highest value it has read
	for (int i = 0; i < NWORDS; i++) { next[i] = 1; own[i] = 0; }
	std::map<uint32_t, int> byaddr;
	for (int i = 0; i < NWORDS; i++) byaddr[word_addr(i)] = i;

	uint64_t now = 0, errors = 0, loads = 0, fetches = 0, stores = 0, dmas = 0, stale_checks = 0;
	auto committed = [&](int w, uint64_t at) -> uint32_t {   // the latest value taken at least STALE clocks before
		uint32_t v = 0;
		for (auto &e : taken[w]) if (e.t + STALE <= at && e.v > v) v = e.v;
		// (the deque needn't hold them all)
		while (taken[w].size() > 8 && taken[w][1].t + STALE <= at) taken[w].pop_front();
		return v;
	};
	auto check = [&](int c, int side, int w, uint32_t val, uint64_t at, bool writer_own, uint32_t ownv) {
		uint32_t a = word_addr(w);
		if (writer_own && val != ownv)
		{
			printf("clock %llu: cache %d's own load of %08X read %u, it wrote %u\n", (unsigned long long)now, c, a, val, ownv);
			errors++;
		}
		if (val < floor_[c][side][w])
		{
			printf("clock %llu: cache %d %s of %08X went back: %u after %u\n", (unsigned long long)now, c, side ? "fetch" : "load", a, val, floor_[c][side][w]);
			errors++;
		}
		floor_[c][side][w] = std::max(floor_[c][side][w], val);
		uint32_t m = committed(w, at);
		stale_checks++;
		if (val < m)
		{
			printf("clock %llu: cache %d %s of %08X read %u at clock %llu, stale: %u was taken before\n", (unsigned long long)now, c, side ? "fetch" : "load", a, val, (unsigned long long)at, m);
			errors++;
		}
	};

	// each side's request state: the data side's accesses out (two at most, answered in order; a load's ownv is what its
	// cache last wrote to the word before it), and the last one taken, whose signals the core drives until it takes the
	// next (d_kill only in its address clock: now and then a load's, which then isn't answered)
	struct dacc { bool we = false; int w = 0; uint64_t at = 0; uint32_t pa = 0; int size = 4; uint64_t wdata = 0; uint32_t ownv = 0; };
	struct dside { bool aph = false, kill = false; dacc cur; std::deque<dacc> out; } ds[2];
	struct iside { bool aph = false; int w = 0; uint64_t at = 0; uint32_t pa = 0; bool kill = false; } is[2];

	t.rst = 1; t.clk = 0;
	for (int i = 0; i < 2; i++) { t.if_req = 0; t.d_req = 0; t.if_kill = 0; t.d_kill = 0; }
	t.ddr_busy = 0; t.ddr_dout_ready = 0; t.dma_we = 0;
	for (int i = 0; i < 8; i++) { t.clk = 1; t.eval(); t.clk = 0; t.eval(); }
	t.rst = 0;
	// (the tags' sweep)
	for (int i = 0; i < 300; i++) { t.clk = 1; t.eval(); t.clk = 0; t.eval(); }

	int dma_w = -1; uint32_t dma_v = 0;
	int burst_addr = 0;

	for (; now < clocks && errors < 8; now++)
	{
		// the requests for this clock (inputs before the edge); this is the combinational phase
		t.ddr_busy = lat && rng() % 5 == 0;
		t.ddr_dout_ready = !rq.empty() && rq.front().wait <= 0;
		if (t.ddr_dout_ready) t.ddr_dout = rq.front().d;

		uint8_t ifr = 0, drq = 0, ifk = 0, dk = 0, dwe = 0;
		for (int c = 0; c < 2; c++)
		{
			// the last access taken (in its address clock, or after)
			t.d_pa[c] = ds[c].cur.pa;
			t.d_size[c] = ds[c].cur.size;
			t.d_wdata[c] = ds[c].cur.wdata;
			if (ds[c].cur.we) dwe |= 1 << c;
			if (ds[c].aph && ds[c].kill) dk |= 1 << c;
			if (is[c].aph)
			{
				t.if_pa[c] = is[c].pa;
				if (is[c].kill) ifk |= 1 << c;
			}
		}
		t.d_we = dwe; t.d_kill = dk; t.if_kill = ifk;

		// new requests
		static int d_next_w[2], i_next_w[2];
		static bool d_next_we[2], d_next_cross[2];
		for (int c = 0; c < 2; c++)
		{
			// another access if that leaves two out at most after this clock's answer (none in a kill's clock)
			bool can = !(ds[c].aph && ds[c].kill) && int(ds[c].out.size()) - int(t.d_valid >> c & 1) < 2;
			int r = rng() % 16;
			int w = rng() % NWORDS;
			// bias to the words nearby the last, so hits happen
			if (rng() % 4) w = (d_next_w[c] & ~7) | (rng() % 8);
			if (w >= NWORDS) w = rng() % NWORDS;
			d_next_w[c] = w;
			d_next_we[c] = writer_of(w) == c && rng() % 2;
			d_next_cross[c] = d_next_we[c] && rng() % 16 == 0 && (word_addr(w) & 4) && w + 1 < NWORDS && word_addr(w + 1) == word_addr(w) + 4 && writer_of(w + 1) == c;
			if (r < 12 && can) drq |= 1 << c;
			t.d_va[c] = word_addr(w);

			int fw = rng() % NWORDS;
			if (rng() % 4) fw = (i_next_w[c] & ~7) | (rng() % 8);
			if (fw >= NWORDS) fw = rng() % NWORDS;
			i_next_w[c] = fw;
			t.if_va[c] = word_addr(fw);
			if (rng() % 16 < 10) ifr |= 1 << c;
		}
		t.d_req = drq; t.if_req = ifr;

		// the DMA: a word of its own now and then
		if (dma_w < 0 && rng() % 8 == 0)
		{
			int w;
			do w = rng() % NWORDS; while (writer_of(w) != 2);
			dma_w = w; dma_v = next[w]++;
		}
		t.dma_we = dma_w >= 0;
		if (dma_w >= 0)
		{
			uint32_t a = word_addr(dma_w);
			uint32_t bv = __builtin_bswap32(dma_v);
			t.dma_a = a >> 3;
			t.dma_wd = a & 4 ? uint64_t(bv) << 32 : uint64_t(bv);
			t.dma_be = a & 4 ? 0xf0 : 0x0f;
		}
		t.eval();

		// answers in this clock
		for (int c = 0; c < 2; c++)
		{
			if ((t.if_valid >> c & 1) && is[c].aph && !is[c].kill)
			{
				fetches++;
				check(c, 1, is[c].w, t.if_data[c], is[c].at, false, 0);
			}
			if (t.d_valid >> c & 1)
			{
				if (ds[c].out.empty())
				{
					printf("clock %llu: cache %d answered with no access out\n", (unsigned long long)now, c);
					errors++;
					continue;
				}
				dacc a = ds[c].out.front();
				ds[c].out.pop_front();
				if (!a.we)
				{
					loads++;
					check(c, 0, a.w, uint32_t(t.d_rdata[c]), a.at, writer_of(a.w) == c, a.ownv);
				}
			}
		}

		// what DDR3 takes at the edge
		if (t.ddr_dout_ready) rq.pop_front();
		for (auto &r : rq) r.wait--;
		if (!t.ddr_busy && t.g_we)
		{
			uint32_t a = uint32_t(t.g_a) << 3;
			uint64_t &m = ddr[a];
			for (int b = 0; b < 8; b++)
				if (t.g_be >> b & 1) m = (m & ~(0xffull << 8 * b)) | (uint64_t(t.g_wd) & (0xffull << 8 * b));
			for (int k = 0; k < 2; k++)
				if (t.g_be >> (k * 4) & 0xf)
				{
					auto it = byaddr.find(a + 4 * k);
					if (it != byaddr.end())
						taken[it->second].push_back({ now, __builtin_bswap32(uint32_t(m >> (32 * k))) });
				}
		}
		else if (!t.ddr_busy && t.g_rd)
		{
			uint32_t a = uint32_t(t.g_a) << 3;
			int wait = lat ? 2 + int(rng() % 12) : 1;
			for (int b = 0; b < int(t.g_burst); b++) rq.push_back({ ddr.count(a + 8 * b) ? ddr[a + 8 * b] : 0, wait + b });
		}
		if (t.dma_we && !t.dma_busy) { dmas++; dma_w = -1; }

		// the address clocks done; the new ones
		for (int c = 0; c < 2; c++)
		{
			bool iok = t.if_rdy >> c & 1, dok = t.d_rdy >> c & 1;
			// a fetch stays out while it missed: the cache asks again, with the same address, on its own
			if (is[c].aph) is[c].aph = false;
			if ((t.if_req >> c & 1) && iok)
			{
				is[c].aph = true;
				is[c].w = i_next_w[c];
				is[c].at = now + 1;
				is[c].pa = word_addr(i_next_w[c]);
				is[c].kill = false;
			}
			if (ds[c].aph)
			{
				if (ds[c].kill) ds[c].out.pop_back();
				ds[c].aph = false;
			}
			if ((t.d_req >> c & 1) && dok)
			{
				int w = d_next_w[c];
				dacc d;
				d.w = w; d.at = now + 1; d.pa = word_addr(w); d.size = 4; d.we = d_next_we[c];
				if (!d.we) d.ownv = own[w];
				if (d.we)
				{
					uint32_t v = next[w]++;
					own[w] = v;
					d.wdata = v;
					if (d_next_cross[c])
					{
						// across 8 bytes: this word and the next, both counts
						uint32_t v2 = next[w + 1]++;
						own[w + 1] = v2;
						d.size = 8;
						d.wdata = uint64_t(v) << 32 | v2;
					}
					stores++;
				}
				ds[c].cur = d;
				ds[c].out.push_back(d);
				ds[c].aph = true;
				ds[c].kill = !d.we && rng() % 16 == 0;
				if (ds[c].out.size() > 2)
				{
					printf("clock %llu: cache %d took a third access\n", (unsigned long long)now, c);
					errors++;
				}
			}
		}
		t.clk = 1; t.eval();
		t.clk = 0; t.eval();
	}
	printf("%s: %llu clocks, %llu loads, %llu fetches, %llu stores, %llu DMA words, %llu checks, %llu errors\n", errors ? "FAIL" : "PASS",
		(unsigned long long)now, (unsigned long long)loads, (unsigned long long)fetches, (unsigned long long)stores, (unsigned long long)dmas,
		(unsigned long long)stale_checks, (unsigned long long)errors);
	return errors != 0;
}
