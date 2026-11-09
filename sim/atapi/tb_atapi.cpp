// tb_atapi.cpp: the CD drive's data sectors (rtl/m2_atapi.sv), from memory (the image tools/cdimage.py makes) and streamed from the mounted raw
// image (2352 bytes a sector, the data at 16 in): READ(10) and READ(12) of random sectors and counts, read through the data port, must give
// the disc's sectors either way, as must the answers that aren't sectors (the TOC).
//
//   tb_atapi [commands] [seed]
#include "Vm2_atapi.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>

static Vm2_atapi *t;
static uint32_t rnd = 1;
static uint32_t rn() { rnd = rnd * 1103515245 + 12345; return rnd >> 8; }
static const uint32_t IMAGE = 0x50000000, SECTORS = 600;
static std::vector<uint8_t> image, raw;  // memory's (2048 bytes of answers, then the sectors), the mounted one

static int m_wait = -1, m_beat;
static uint32_t m_addr;
static int s_state, s_wait;              // the SD port: 0 idle, 1 ack coming, 2 bytes
static uint32_t s_pos, s_n;
static uint64_t sd_reads;
static void clock1()
{
	t->m_busy = (rn() & 3) == 0;
	t->m_ready = 0;
	if (m_wait > 0) m_wait--;
	else if (m_wait == 0)
	{
		uint64_t v = 0;
		for (int i = 0; i < 8; i++) v |= uint64_t(image[(m_addr - IMAGE + m_beat * 8 + i) % image.size()]) << (8 * i);
		t->m_dout = v; t->m_ready = 1;
		if (++m_beat == 4) m_wait = -1;
	}
	// MiSTer's SD: after a while, ack, the 4 KB a byte at a time with gaps, then ack drops
	t->sd_wr = 0;
	if (s_state == 1 && --s_wait <= 0) { t->sd_ack = 1; s_state = 2; s_n = 0; }
	else if (s_state == 2)
	{
		if (s_n < 4096) { if (rn() & 1) { t->sd_wr = 1; t->sd_d = s_pos + s_n < raw.size() ? raw[s_pos + s_n] : 0; s_n++; } }
		else { t->sd_ack = 0; s_state = 0; }
	}
	t->clk = 0; t->eval();
	if (t->m_rd && !t->m_busy && m_wait < 0) { m_addr = uint32_t(t->m_a) << 3; m_beat = 0; m_wait = 6 + (rn() & 7); }
	if (t->sd_rd && s_state == 0) { s_state = 1; s_wait = 50 + rn() % 200; s_pos = uint32_t(t->sd_lba) * 512; sd_reads++; }
	t->clk = 1; t->eval();
	t->we = 0; t->re = 0;
}
static void wr(int a, uint16_t d) { t->a = a; t->wd = d; t->we = 1; clock1(); }
static uint16_t rd(int a) { t->a = a; t->re = 1; t->eval(); uint16_t v = t->rd; clock1(); clock1(); return v; }   // (a CPU's reads are clocks apart)

int main(int argc, char **argv)
{
	int cmds = argc > 1 ? atoi(argv[1]) : 3000;     // (a seek in the clock a read-ahead fetch starts took about a thousand to show)
	rnd = argc > 2 ? uint32_t(atoi(argv[2])) : 1;
	image.resize(2048 + SECTORS * 2048);
	raw.resize(SECTORS * 2352);
	for (auto &b : image) b = uint8_t(rn());
	for (uint32_t s = 0; s < SECTORS; s++)
		for (int i = 0; i < 2352; i++)
			raw[s * 2352 + i] = i >= 16 && i < 16 + 2048 ? image[2048 + s * 2048 + i - 16] : uint8_t(rn());
	t = new Vm2_atapi;
	int bad = 0;
	for (int stream = 0; stream < 2; stream++)
	{
		t->stream = stream; t->sd_ack = 0;
		t->rst = 1; for (int i = 0; i < 4; i++) clock1(); t->rst = 0;
		uint64_t words = 0, c0 = 0;
		for (int k = 0; k < cmds; k++)
		{
			// a READ, or now and then a READ TOC (an answer from the image's first 2048 bytes, either way)
			uint8_t pk[12] = { 0 };
			// (half the time the next sectors, one a command, as Battle Tryst streams: the drive's read-ahead's case)
			static uint32_t next_lba = 0;
			bool seq = rn() % 2 == 0 && next_lba < SECTORS - 20;
			uint32_t lba = seq ? next_lba : rn() % (SECTORS - 20), n = seq ? 1 : 1 + rn() % 4, expect_bytes;
			next_lba = lba + n;
			bool toc = rn() % 8 == 0;
			if (toc) { pk[0] = 0x43; pk[6] = 1 + rn() % 3; pk[8] = 12; expect_bytes = 12; }
			else if (rn() & 1) { pk[0] = 0x28; pk[2] = lba >> 24; pk[3] = lba >> 16; pk[4] = lba >> 8; pk[5] = lba; pk[7] = n >> 8; pk[8] = n; expect_bytes = n * 2048; }
			else { pk[0] = 0xa8; pk[2] = lba >> 24; pk[3] = lba >> 16; pk[4] = lba >> 8; pk[5] = lba; pk[9] = n; expect_bytes = n * 2048; }
			wr(7, 0xa000);
			for (int i = 0; i < 12; i += 2) wr(0, uint16_t(pk[i] << 8 | pk[i + 1]));
			uint32_t got = 0;
			while (got < expect_bytes)
			{
				int guard = 0;
				while (!(rd(7) & 0x0800) && ++guard < 100000) ;
				if (guard >= 100000) { if (bad++ < 10) printf("stream %d cmd %d: no DRQ after %u bytes\n", stream, k, got); break; }
				uint32_t chunk = toc ? 12 : 2048;
				for (uint32_t i = 0; i < chunk; i += 2)
				{
					uint16_t w = rd(0);
					uint32_t at = toc ? 0x400 + 16 * pk[6] + i : 2048 + (lba + got / 2048) * 2048 + i;
					uint16_t e = uint16_t(image[at] << 8 | image[at + 1]);
					if (w != e && bad++ < 10) printf("stream %d cmd %d (%02x lba %u n %u): byte %u core %04x image %04x\n", stream, k, pk[0], lba, n, got + i, w, e);
					words++;
				}
				got += chunk;
			}
			for (int i = 0; i < 20; i++) clock1();
			(void)c0;
		}
		printf("%s: %d commands, %llu words read, %llu SD reads\n", stream ? "streamed" : "memory  ", cmds, (unsigned long long)words, (unsigned long long)sd_reads);
	}
	printf(bad ? "DIFFERENT\n" : "ALL SAME\n");
	return bad ? 1 : 0;
}
