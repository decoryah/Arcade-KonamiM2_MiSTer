// tb_ymz: rtl/m2_ymz280b.sv against a port of MAME 0.289's sound/ymz280b.cpp (BSD-3), its stream a sample at a time, on the real sample ROM: every round's sums
// compared. What's written goes in between rounds, to both. The ROM's DDR3 is a model with random waits.
//   tb_ymz rom [seed] [ticks] [trace]: without a trace random voices; a trace is the game's writes, "tick 0 reg" / "tick 1 data"
#include "Vm2_ymz280b.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <random>
#include <vector>

static std::vector<uint8_t> rom;
static inline uint8_t rd(uint32_t a) { return rom[a & (rom.size() - 1)]; }

struct Voice {
	int fnum = 0, looping = 0, mode = 0, keyon = 0, level = 0, pan = 0, start = 0, loop_start = 0, loop_end = 0, stop = 0;
	int playing = 0, ramp = 0, position = 0, signal = 0, step = 0, loop_signal = 0, loop_step = 0, loop_count = 0;
	int output_pos = 512, last = 0, curr = 0;
	int ostep() const { return (mode == 1 ? (fnum & 0xff) : (fnum & 0x1ff)) + 1; }
	int lvol() const { return pan == 8 ? level : pan < 8 ? level : level * (15 - pan) / 7; }
	int rvol() const { return pan == 8 ? level : pan < 8 ? (pan == 0 ? 0 : level * (pan - 1) / 7) : level; }
};
static const int index_scale[8] = { 0x0e6, 0x0e6, 0x0e6, 0x0e6, 0x133, 0x199, 0x200, 0x266 };

struct Model {
	Voice v[8];
	int cur = 0, keyon_enable = 0, ext_enable = 0;
	unsigned status = 0;
	void write(int data) {
		if (cur < 0x80) {
			Voice &o = v[(cur >> 2) & 7];
			switch (cur & 0xe3) {
				case 0x00: o.fnum = (o.fnum & 0x100) | data; break;
				case 0x01:
					o.fnum = (o.fnum & 0xff) | ((data & 1) << 8);
					o.looping = (data >> 4) & 1;
					if (!(data & 0x60)) data &= 0x7f; else o.mode = (data >> 5) & 3;
					if (!o.keyon && (data & 0x80) && keyon_enable) {
						o.playing = 1; o.ramp = 0; o.position = o.start; o.signal = o.loop_signal = 0; o.step = o.loop_step = 0x7f; o.loop_count = 0;
					} else if (o.keyon && !(data & 0x80)) { o.playing = 0; o.ramp = 0; }
					o.keyon = data >> 7;
					break;
				case 0x02: o.level = data; break;
				case 0x03: o.pan = data & 15; break;
				case 0x20: o.start = (o.start & (0xffff << 1)) | (data << 17); break;
				case 0x21: o.loop_start = (o.loop_start & (0xffff << 1)) | (data << 17); break;
				case 0x22: o.loop_end = (o.loop_end & (0xffff << 1)) | (data << 17); break;
				case 0x23: o.stop = (o.stop & (0xffff << 1)) | (data << 17); break;
				case 0x40: o.start = (o.start & (0xff00ff << 1)) | (data << 9); break;
				case 0x41: o.loop_start = (o.loop_start & (0xff00ff << 1)) | (data << 9); break;
				case 0x42: o.loop_end = (o.loop_end & (0xff00ff << 1)) | (data << 9); break;
				case 0x43: o.stop = (o.stop & (0xff00ff << 1)) | (data << 9); break;
				case 0x60: o.start = (o.start & (0xffff00 << 1)) | (data << 1); break;
				case 0x61: o.loop_start = (o.loop_start & (0xffff00 << 1)) | (data << 1); break;
				case 0x62: o.loop_end = (o.loop_end & (0xffff00 << 1)) | (data << 1); break;
				case 0x63: o.stop = (o.stop & (0xffff00 << 1)) | (data << 1); break;
				default: break;
			}
		} else if (cur == 0xff) {
			ext_enable = (data >> 6) & 1;
			if (keyon_enable && !(data & 0x80)) { for (auto &o : v) { o.playing = 0; o.ramp = 0; } }
			else if (!keyon_enable && (data & 0x80)) { for (auto &o : v) if (o.keyon && o.looping) o.playing = 1; }
			keyon_enable = data >> 7;
		}
	}
	static int decay(int t) { return t < 0 ? -((-t * 15) >> 4) : t > 0 ? (t * 15) >> 4 : 0; }
	int next(Voice &o, int &status_bit) {
		int s = 0;
		if (o.playing && o.mode) {
			if (o.mode == 1) {
				int val = rd(o.position / 2) >> ((~o.position & 1) << 2);
				int n = val & 15, m = (n & 7) * 2 + 1;
				o.signal += (o.step * (n & 8 ? -m : m)) / 8;
				if (o.signal > 32767) o.signal = 32767; else if (o.signal < -32768) o.signal = -32768;
				o.step = (o.step * index_scale[val & 7]) >> 8;
				if (o.step > 0x6000) o.step = 0x6000; else if (o.step < 0x7f) o.step = 0x7f;
				s = o.signal;
				o.position++;
				if (o.looping) {
					if (o.position == o.loop_start && o.loop_count == 0) { o.loop_signal = o.signal; o.loop_step = o.step; }
					if (o.position >= o.loop_end && o.keyon) { o.position = o.loop_start; o.signal = o.loop_signal; o.step = o.loop_step; o.loop_count++; }
				}
			} else if (o.mode == 2) {
				s = int8_t(rd(o.position / 2)) * 256;
				o.position += 2;
				if (o.looping && o.position >= o.loop_end && o.keyon) o.position = o.loop_start;
			} else {
				s = int16_t((rd(o.position / 2 + 1) << 8) + rd(o.position / 2));
				o.position += 4;
				if (o.looping && o.position >= o.loop_end && o.keyon) o.position = o.loop_start;
			}
			if (o.position >= o.stop) { o.playing = 0; o.ramp = 1; status_bit = 1; }
		} else if (o.ramp) {
			s = decay(o.curr);
			if (s == 0) o.ramp = 0;
		}
		return s;
	}
	void emit(Voice &o, int64_t &l, int64_t &r) {
		int in = (o.last * (512 - o.output_pos) + o.curr * o.output_pos) >> 9;
		l += in * o.lvol() / 2;
		r += in * o.rvol() / 2;
		o.output_pos += o.ostep();
	}
	void round(int64_t &l, int64_t &r) {
		l = r = 0;
		for (int i = 0; i < 8; i++) {
			Voice &o = v[i];
			if (!o.playing && o.curr == 0 && o.last == 0) { o.output_pos = 512; continue; }
			bool em = false;
			if (o.output_pos < 512) { emit(o, l, r); em = true; }
			if (o.output_pos >= 512) {
				o.output_pos -= 512;
				int sb = 0;
				int s = next(o, sb);
				o.last = o.curr; o.curr = s;
				if (!em) {
					emit(o, l, r);
					if (o.output_pos >= 512) { o.output_pos -= 512; s = next(o, sb); o.last = o.curr; o.curr = s; }
				}
				if (sb) status |= 1u << i;
			}
		}
	}
};

struct Ev { uint64_t tick; int kind, val; };

int main(int argc, char **argv)
{
	if (argc < 2) { fprintf(stderr, "tb_ymz rom [seed] [ticks] [trace]\n"); return 2; }
	FILE *f = fopen(argv[1], "rb");
	if (!f) { perror(argv[1]); return 2; }
	rom.resize(0x400000);
	if (fread(rom.data(), 1, rom.size(), f) != rom.size()) { fprintf(stderr, "short ROM\n"); return 2; }
	fclose(f);
	unsigned seed = argc > 2 ? strtoul(argv[2], 0, 0) : 1;
	uint64_t ticks = argc > 3 ? strtoull(argv[3], 0, 0) : 500000;
	std::vector<Ev> tr;
	if (argc > 4) {
		FILE *t = fopen(argv[4], "r");
		if (!t) { perror(argv[4]); return 2; }
		Ev e;
		while (fscanf(t, "%lu %d %i", &e.tick, &e.kind, &e.val) == 3) tr.push_back(e);
		fclose(t);
		printf("trace: %zu writes, to tick %lu\n", tr.size(), tr.empty() ? 0ul : tr.back().tick);
	}

	std::mt19937 rng(seed);
	Vm2_ymz280b d;
	Model m;
	d.clk = 0; d.rst = 1; d.tick = 0; d.sel_we = 0; d.dat_we = 0; d.ext_rd = 0; d.st_rd = 0; d.m_busy = 0; d.m_ready = 0;
	struct Pend { int when; uint64_t data; };
	std::deque<Pend> reads;
	uint64_t cyc = 0, rd_taken = 0;
	auto clock = [&]() {
		d.m_ready = 0;
		if (!reads.empty() && reads.front().when <= 0) { d.m_ready = 1; d.m_dout = reads.front().data; reads.pop_front(); }
		for (auto &p : reads) p.when--;
		d.m_busy = (rng() % 4) == 0;
		d.clk = 0; d.eval();
		bool take = d.m_rd && !d.m_busy;
		uint32_t a = uint32_t(d.m_a) << 3;
		d.clk = 1; d.eval();
		if (take) {
			uint64_t w = 0;
			for (int i = 0; i < 8; i++) w |= uint64_t(rd(a + i)) << (8 * i);
			reads.push_back({ 4 + int(rng() % 40), w });
			rd_taken++;
		}
		cyc++;
	};
	for (int i = 0; i < 20; i++) clock();
	d.rst = 0;
	for (int i = 0; i < 20; i++) clock();

	auto put = [&](int reg, int val) {
		d.sel_we = 1; d.sel_d = reg; clock(); d.sel_we = 0;
		d.dat_we = 1; d.dat_d = val; clock(); d.dat_we = 0;
		m.cur = reg; m.write(val);
	};
	if (tr.empty()) put(0xff, 0x80);

	auto random_voice = [&]() {
		int v = rng() % 8, b = v << 2;
		uint32_t len = 16 + rng() % ((rng() % 4) ? 2000 : 60000);
		uint32_t st = rng() % (0x400000 - len - 16);
		uint32_t ls = st + rng() % len, le = ls + 1 + rng() % (st + len - ls);
		uint32_t en = (rng() % 3) ? st + len : le + rng() % 64;
		int mode = (rng() % 8) ? 1 : 2 + rng() % 2;
		put(0x20 + b, st >> 16); put(0x40 + b, (st >> 8) & 255); put(0x60 + b, st & 255);
		put(0x21 + b, ls >> 16); put(0x41 + b, (ls >> 8) & 255); put(0x61 + b, ls & 255);
		put(0x22 + b, le >> 16); put(0x42 + b, (le >> 8) & 255); put(0x62 + b, le & 255);
		put(0x23 + b, en >> 16); put(0x43 + b, (en >> 8) & 255); put(0x63 + b, en & 255);
		int fn = (rng() % 3) ? rng() % 256 : rng() % 512;
		put(0x00 + b, fn & 255);
		put(0x02 + b, rng() % 256);
		put(0x03 + b, rng() % 16);
		put(0x01 + b, ((fn >> 8) & 1) | (mode << 5) | ((rng() % 3 == 0) << 4));       // (key off first, so the next is a key-on)
		put(0x01 + b, ((fn >> 8) & 1) | (mode << 5) | ((rng() % 2) << 4) | 0x80);
	};

	size_t k = 0;
	uint64_t worst = 0, errs = 0, nz = 0, late = 0;
	for (uint64_t t = 0; t < ticks; t++) {
		if (!tr.empty()) {
			while (k < tr.size() && tr[k].tick <= t) {
				if (tr[k].kind == 0) { d.sel_we = 1; d.sel_d = tr[k].val; clock(); d.sel_we = 0; m.cur = tr[k].val; }
				else { d.dat_we = 1; d.dat_d = tr[k].val; clock(); d.dat_we = 0; m.write(tr[k].val); }
				k++;
			}
		} else {
			unsigned r = rng() % 400;
			if (r < 2) random_voice();
			else if (r == 2) { int b = (rng() % 8) << 2; put(0x01 + b, 0x20); }
			else if (r == 3) { int b = (rng() % 8) << 2; put(0x02 + b, rng() % 256); }
			else if (r == 4) { int b = (rng() % 8) << 2; put(0x03 + b, rng() % 16); }
			else if (r == 5) { int b = (rng() % 8) << 2; put(0x00 + b, rng() % 256); }
			else if (r == 6 && rng() % 40 == 0) { put(0xff, 0x00); put(0xff, 0x80); }
		}
		int64_t ml, mr;
		m.round(ml, mr);
		d.tick = 1; clock(); d.tick = 0;
		uint64_t c0 = cyc;
		while (!d.rnd_done) {
			clock();
			if (cyc - c0 > 200000) { printf("FAIL: a round never ended, tick %lu\n", t); return 1; }
		}
		uint64_t c = cyc - c0;
		if (c > worst) worst = c;
		if (c > 756) late++;
		int64_t l = (int32_t(d.rnd_l) << 5) >> 5, r = (int32_t(d.rnd_r) << 5) >> 5;
		if (ml || mr) nz++;
		if (l != ml || r != mr) {
			if (errs < 20) {
				printf("tick %lu: RTL %ld %ld MAME %ld %ld\n", t, l, r, ml, mr);
				for (int i = 0; i < 8; i++) { Voice &o = m.v[i]; if (o.playing || o.curr || o.last) printf("   v%d play %d pos %x sig %d step %d opos %d last %d curr %d mode %d loop %d start %x ls %x le %x stop %x\n", i, o.playing, o.position, o.signal, o.step, o.output_pos, o.last, o.curr, o.mode, o.looping, o.start, o.loop_start, o.loop_end, o.stop); }
			}
			errs++;
			if (errs >= 20) break;
		}
		for (int i = 0; i < 2; i++) clock();
		if ((d.st_q & 0xff) != (m.status & 0xff) && errs < 20) { printf("tick %lu: status RTL %02x MAME %02x\n", t, d.st_q, m.status); errs++; }
		if (t % 1000 == 0) { d.st_rd = 1; clock(); d.st_rd = 0; m.status = 0; }
	}
	printf("%s: %lu ticks, %lu with sound, %lu errors, %lu DDR3 reads, worst round %lu clocks, %lu over 756\n", errs ? "FAIL" : "PASS", ticks, nz, errs, rd_taken, worst, late);
	return errs ? 1 : 0;
}
