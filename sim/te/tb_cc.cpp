// tb_cc.cpp: the Triangle Engine's colour cache (te_cache, rtl/m2_te.sv) by itself against a plain memory. Random spans of pixels are
// given to its two ports as the engine's pipe gives them: a pixel's source line and destination line told ahead (s_n, d_n: 20 and 26 steps
// before its read and its write), its read, then its write 6 steps after the read; both ports advance only when neither stalls. Checked:
// every read's answer against what the pixels before it wrote (or memory's first contents), and after each flush all of memory against
// the same. Wants are sometimes dropped and sometimes made up, spans' source and destination are sometimes each other's lines 4 KB apart
// (the same place in the cache), memory's latency and its busy clocks are random, and the port's grant is sometimes held back.
//
// What the pipe never does, and so this doesn't: read bytes that the write of the same step or of the step before writes (the engine draws
// such pixels one at a time, "serial"), or use the masked 16-bit write's wait (w_wait), or the Z buffer's sink.
//
//   tb_cc [steps] [seed]      (default 2000000 1)
#include "Vte_cache.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <deque>
#include <vector>

// (-DCC_NOWANTS: a cache with no s_n / d_n, the one before te-cc-ahead: to check the bench itself against it)
#ifdef CC_NOWANTS
#define WANTS(x)
#else
#define WANTS(x) x
#endif

static const uint32_t SIZE = 1u << 20;             // the memory the spans stay in (from 0x40000000)
static std::vector<uint8_t> mem(SIZE), ref(SIZE);
static uint8_t init_at(uint32_t o) { return uint8_t((o * 2654435761u) >> 13); }
static uint32_t rnd = 1;
static uint32_t rn() { rnd = rnd * 1103515245 + 12345; return rnd >> 16; }
static uint32_t rn32() { return (rn() << 16) ^ rn(); }

struct Ev
{
	bool r = false, w = false, sw = false, dw = false, r32 = false, w32 = false, four = false;
	uint32_t ra = 0, wa = 0, wd = 0, sl = 0, dl = 0;
	uint8_t be = 15;
};
static std::deque<Ev> sched;                        // sched[k]: what the step k steps from now does
static Ev &at(size_t k) { while (sched.size() <= k) sched.emplace_back(); return sched[k]; }

// a span of pixels, as the walker would hand them in: one a step
struct Span
{
	int left = 0, dir = 1;
	bool blend = false, b32 = false, four = false, wants = true;
	uint32_t s = 0, d = 0;
	uint32_t ls = ~0u, ld = ~0u;
};
static Span sp;
static uint32_t row_s, row_d;

static void new_span()
{
	uint32_t k = rn() % 100;
	sp = Span();
	sp.b32 = rn() % 5 == 0;
	sp.four = !sp.b32 && k < 6;
	sp.blend = !sp.four && rn() % 3 != 0;
	sp.dir = sp.four || rn() % 3 ? 1 : -1;
	sp.wants = rn() % 10 != 0;                       // (a span whose lines aren't told ahead at all)
	sp.left = 1 + (rn() % 8 == 0 ? rn() % 400 : rn() % 60);
	// the destination: the row after the last, or somewhere else
	if (rn() % 4 == 0) row_d = rn32() % (SIZE / 2);
	else row_d = (row_d + (rn() % 2 ? 1280 : rn() % 2 ? 2560 : 64)) % (SIZE / 2);
	sp.d = row_d + (rn() % 64) * 2;
	// the source: the destination itself, or a place 4 KB lines apart (the same place in the cache), or anywhere in the other half
	uint32_t m = rn() % 10;
	if (m < 4) sp.s = sp.d;
	else if (m < 7) sp.s = (sp.d + 4096 * (1 + rn() % 8)) % SIZE;
	else { if (rn() % 3 == 0) row_s = rn32() % (SIZE / 2); else row_s = (row_s + 1280) % (SIZE / 2); sp.s = SIZE / 2 + row_s; }
	uint32_t al = sp.four ? 7u : sp.b32 ? 3u : 1u;
	sp.d &= ~al; sp.s &= ~al;
}

// the pixel handed in this step: its wants now, its read 20 steps on, its write 26
static void hand_in()
{
	if (sp.left == 0) { if (rn() % 6 == 0) return; new_span(); }
	sp.left--;
	uint32_t n = sp.four ? 8 : sp.b32 ? 4 : 2;
	if (sp.d + n > SIZE || sp.s + n > SIZE || (sp.dir < 0 && (sp.d < n || sp.s < n))) { sp.left = 0; return; }
	bool drawn = rn() % 16 != 0;                    // (a pixel the Z test or a discard throws away: told ahead, never written)
	if (sp.wants)
	{
		Ev &e = at(0);
		if (sp.blend && (sp.s >> 5) != sp.ls && rn() % 50) { e.sw = true; e.sl = sp.s >> 5; }
		if ((sp.d >> 5) != sp.ld && rn() % 50) { e.dw = true; e.dl = sp.d >> 5; }
		sp.ls = sp.s >> 5; sp.ld = sp.d >> 5;
	}
	if (sp.blend) { Ev &e = at(20); e.r = true; e.ra = sp.s; e.r32 = sp.b32; }
	if (drawn)
	{
		Ev &e = at(26);
		e.w = true; e.wa = sp.d; e.w32 = sp.b32; e.four = sp.four; e.wd = sp.b32 ? rn32() : rn();
		e.be = sp.b32 && rn() % 4 == 0 ? uint8_t(rn() & 15) : 15;
	}
	sp.d += sp.dir * int(n); sp.s += sp.dir * int(n);
}

static bool overlap(uint32_t a, uint32_t an, uint32_t b, uint32_t bn) { return a < b + bn && b < a + an; }
static uint32_t wlen(const Ev &e) { return e.four ? 8 : e.w32 ? 4 : 2; }

int main(int argc, char **argv)
{
	uint64_t steps = argc > 1 ? strtoull(argv[1], nullptr, 10) : 2000000;
	rnd = argc > 2 ? uint32_t(strtoul(argv[2], nullptr, 10)) : 1;
	bool rand_lat = true;
	for (uint32_t i = 0; i < SIZE; i++) mem[i] = ref[i] = init_at(i);
	Vte_cache *t = new Vte_cache;
	struct Rd { uint32_t o; int beat; uint64_t at; uint8_t d[32]; };   // (a line as memory had it when the read was taken)
	std::deque<Rd> rq;
	uint64_t clocks = 0, nsteps = 0, nread = 0, nwrite = 0, nflush = 0, nbogus = 0, nstall = 0, bad = 0;
	bool owned = false;
	int other = 0;                                  // clocks the port is someone else's
	auto clk = [&](bool busy, bool ready, uint64_t dout) {
		t->m_busy = busy; t->m_ready = ready; t->m_dout = dout; t->m_gnt = owned;
		t->clk = 0; t->eval();
		if (!busy)
		{
			if (t->m_rd)
			{
				Rd r = { (uint32_t(t->m_a) << 3) & (SIZE - 1) & ~31u, 0, clocks + (rand_lat ? 4 + rn() % 37 : 12), {} };
				memcpy(r.d, &mem[r.o], 32);
				rq.push_back(r);
			}
			else if (t->m_we)
			{
				uint32_t o = (uint32_t(t->m_a) << 3) & (SIZE - 1);
				if ((uint32_t(t->m_a) >> 25) != 4) { printf("write outside RAM %08x\n", uint32_t(t->m_a) << 3); bad++; }
				for (int i = 0; i < 8; i++) if ((t->m_be >> i) & 1) mem[o + i] = uint8_t(t->m_wd >> (8 * i));
			}
		}
		bool req = t->m_req;
		t->clk = 1; t->eval();
		// the port: the cache's while it asks, once nothing else has it (as m2_te's m_owned)
		if (other > 0) other--;
		if (!owned) { if (req && other == 0) owned = true; }
		else if (!req) { owned = false; if (rn() % 8 == 0) other = 1 + rn() % 30; }
		clocks++;
	};
	auto mclk = [&]() {
		bool busy = (rn() & 7) == 0, ready = false;
		uint64_t dout = 0;
		if (!rq.empty() && clocks >= rq.front().at)
		{
			Rd &r = rq.front();
			ready = true;
			for (int i = 0; i < 8; i++) dout |= uint64_t(r.d[r.beat * 8 + i]) << (8 * i);
			if (++r.beat == 4) rq.pop_front();
		}
		clk(busy, ready, dout);
	};
	t->rst = 1; t->r_n = t->w_n = 0; t->r_adv = t->w_adv = 0; t->flush = 0; WANTS(t->s_n = t->d_n = 0); t->sink_in = 0; t->sink_wait = 0; t->w_wait = 0;
	for (int i = 0; i < 10; i++) mclk();
	t->rst = 0;
	for (int i = 0; i < 300; i++) mclk();

	bool pend_r = false, pend_r32 = false;
	uint32_t exp_q = 0, pend_ra = 0;
	Ev last_w;                                      // the step before's write
	uint32_t reg_wd = 0, next_wd = 0;
	uint8_t reg_be = 15, next_be = 15;
	bool was_pe = false;
	auto compare_all = [&](const char *when) {
		uint64_t d = 0;
		for (uint32_t i = 0; i < SIZE; i++)
			if (mem[i] != ref[i]) { if (d++ < 8) printf("  %s: memory %08x has %02x, the pixels wrote %02x (first contents %02x)\n", when, 0x40000000 + i, mem[i], ref[i], init_at(i)); }
		if (d) { printf("FAIL %s: %llu bytes of memory differ at clock %llu (step %llu, seed %u)\n", when, (unsigned long long)d, (unsigned long long)clocks, (unsigned long long)nsteps, rnd); bad += d; }
	};
	// between spans, now and then: nothing handed in until the pipe's empty and three steps more, then a flush (the engine flushes when a
	// list stops, its pixels long gone)
	// Before half of those flushes, a made-up destination want for another line of the last read's place, and steps enough for the
	// write-back to act on it: if that place's line was dirty it's then marked clean, and the flush's walk, which has the read port's
	// tags, must look each place's mark up at its own address, not at the read port's
	bool draining = false, flushing = false, tease = false, have_ra = false;
	uint32_t last_ra = 0;
	int quiet = 0;
	while ((nsteps < steps || flushing || draining || !sched.empty()) && bad == 0)
	{
		// (the clock after the edge: what the ports say)
		if (was_pe) { reg_wd = next_wd; reg_be = next_be; }
		bool pe = !(t->r_stall || t->w_stall);
		if (pend_r && !t->r_stall)
		{
			uint32_t q = t->q;
			if (q != exp_q)
			{
				printf("FAIL: read of %08x (%d bits) gave %08x, the pixels wrote %08x; clock %llu, step %llu\n", 0x40000000 + pend_ra, pend_r32 ? 32 : 16, q, exp_q,
					(unsigned long long)clocks, (unsigned long long)nsteps);
				bad++;
			}
			pend_r = false;
			nread++;
		}
		if (!pe) nstall++;
		t->r_adv = t->w_adv = pe;
		t->wd = reg_wd; t->be = reg_be;
		WANTS(t->s_n = t->d_n = 0); t->flush = 0;
		t->r_n = t->w_n = 0;
		if (flushing)
		{
			if (t->flushed) { flushing = false; nflush++; compare_all("after a flush"); }
		}
		else if (pe)
		{
			// a step
			if (!draining && sp.left == 0 && (rn() % 8 == 0 || nsteps >= steps)) { draining = true; quiet = 3; tease = have_ra && rn() % 2 == 0; }
			if (!draining) hand_in();
			Ev e = sched.empty() ? Ev() : sched.front();
			if (!sched.empty()) sched.pop_front();
			nsteps++;
			if (e.sw) { WANTS(t->s_n = 1; t->s_na = e.sl); }
			if (e.dw) { WANTS(t->d_n = 1; t->d_na = e.dl); }
			// (wants for lines no pixel will use, now and then)
			if (!e.sw && rn() % 97 == 0) { WANTS(t->s_n = 1; t->s_na = rn32() % (SIZE >> 5)); nbogus++; }
			if (!e.dw && rn() % 97 == 0) { WANTS(t->d_n = 1; t->d_na = rn32() % (SIZE >> 5)); nbogus++; }
			if (tease && draining && sched.empty() && !e.r && !e.w && !e.sw && !e.dw)
			{
				WANTS(t->d_n = 1; t->d_na = ((last_ra >> 5) + 128 * (1 + rn() % 8)) % (SIZE >> 5));
				nbogus++; tease = false; quiet = 12 + rn() % 12; e.dw = true;
			}
			// the read, unless its bytes are this step's write's or the last's
			uint32_t rl = e.r32 ? 4 : 2;
			if (e.r && e.w && overlap(e.ra, rl, e.wa, wlen(e))) e.r = false;
			if (e.r && last_w.w && overlap(e.ra, rl, last_w.wa, wlen(last_w))) e.r = false;
			if (e.r)
			{
				t->r_n = 1; t->r_na = e.ra >> 1; t->r_ns32 = e.r32;
				pend_r = true; pend_r32 = e.r32; pend_ra = e.ra;
				last_ra = e.ra; have_ra = true;
				exp_q = e.r32 ? uint32_t(ref[e.ra] << 24 | ref[e.ra + 1] << 16 | ref[e.ra + 2] << 8 | ref[e.ra + 3]) : uint32_t(ref[e.ra] << 8 | ref[e.ra + 1]);
			}
			if (e.w)
			{
				t->w_n = 1; t->w_na = e.wa >> 1; t->w_ns32 = e.w32; t->w_nfour = e.four;
				next_wd = e.wd; next_be = e.be;
				if (e.four) for (int k = 0; k < 4; k++) { ref[e.wa + 2 * k] = uint8_t(e.wd >> 8); ref[e.wa + 2 * k + 1] = uint8_t(e.wd); }
				else if (e.w32) { for (int k = 0; k < 4; k++) if ((e.be >> (3 - k)) & 1) ref[e.wa + k] = uint8_t(e.wd >> (24 - 8 * k)); }
				else { ref[e.wa] = uint8_t(e.wd >> 8); ref[e.wa + 1] = uint8_t(e.wd); }
				nwrite++;
			}
			last_w = e;
			if (draining && sched.empty() && !e.r && !e.w && !e.sw && !e.dw)
			{
				if (quiet > 0) quiet--;
				else { WANTS(t->s_n = t->d_n = 0); t->flush = 1; flushing = true; draining = false; }
			}
		}
		was_pe = pe;
		mclk();
		if (clocks > steps * 400 + 1000000) { printf("FAIL: stuck at clock %llu, step %llu\n", (unsigned long long)clocks, (unsigned long long)nsteps); bad++; }
	}
	if (!bad)
	{
		// the last flush
		for (int i = 0; i < 4; i++) { t->r_adv = t->w_adv = !(t->r_stall || t->w_stall); t->r_n = t->w_n = 0; WANTS(t->s_n = t->d_n = 0); mclk(); }
		t->flush = 1; mclk(); t->flush = 0;
		for (int i = 0; i < 200000 && !t->flushed; i++) mclk();
		if (!t->flushed) { printf("FAIL: the last flush never ended\n"); bad++; }
		for (int i = 0; i < 2000; i++) mclk();
		compare_all("at the end");
	}
	printf("%s: %llu steps in %llu clocks (%llu stalled), %llu reads checked, %llu writes, %llu flushes, %llu made-up wants, seed %s\n", bad ? "FAIL" : "PASS",
		(unsigned long long)nsteps, (unsigned long long)clocks, (unsigned long long)nstall, (unsigned long long)nread, (unsigned long long)nwrite,
		(unsigned long long)nflush, (unsigned long long)nbogus, argc > 2 ? argv[2] : "1");
	return bad ? 1 : 0;
}
