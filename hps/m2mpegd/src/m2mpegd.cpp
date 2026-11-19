// m2mpegd: the MPEG daemon on the MiSTer's ARM (PROTOCOL.md). Waits for a core it serves (/tmp/CORENAME), maps the block
// through /dev/mem and game RAM through /dev/m2_mem_wc (write-combined, kernel/m2_mem_wc) or /dev/mem, and runs
// mpegd_session (m2mpegd_core.cpp) until the core goes; then waits again.
//   m2mpegd --base HEX [--cores name,name] [--log FILE] [--check]
//     --base     the block's physical address (PROTOCOL.md; no default: scripts/m2mpegd_service.sh gives 30400000)
//     --cores    /tmp/CORENAME values served (default btltryst)
//     --log      messages (default /tmp/m2mpegd.log)
//     --check    print what it would do and exit (maps nothing)
//     --threads  1 or 2 (default 2)
//     --pace MS  each picture stored MS after its end entry was seen (default 0: as soon as it's ready)
//     --wc       auto (default): game RAM through /dev/m2_mem_wc if the module is loaded, else /dev/mem; on: the module
//                or nothing; off: /dev/mem (a picture's copy: about 0.3 ms write-combined, 3.7 ms through /dev/mem)
// While no served core runs it sleeps, at normal priority, and reads /tmp/CORENAME once a second (the boot service:
// scripts/m2mpegd_autostart_on.sh). While it serves a core it runs at raised priority (nice -20). It leaves cleanly on
// SIGTERM / SIGINT (present's magic cleared).
// Not to be run against a core without the MPEG block: it writes the block's present / done words, and game RAM.
#include "m2mpeg_protocol.h"
#include "m2mpegd_core.h"

#include <atomic>
#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

using namespace m2p;

namespace {

// kernel/m2_mem_wc's ioctl: wmb() (the L2 controller's store buffer drained)
constexpr unsigned long M2_MEM_WC_SYNC = _IO('M', 0x32);

std::atomic<bool> g_stop{false};
void on_signal(int) { g_stop = true; }

std::string core_name()
{
	char buf[64] = {};
	FILE *f = fopen("/tmp/CORENAME", "r");
	if (!f)
		return std::string();
	const size_t n = fread(buf, 1, sizeof(buf) - 1, f);
	fclose(f);
	buf[n] = 0;
	buf[strcspn(buf, "\r\n")] = 0;
	return buf;
}

// One sleep, not a wake-up every few ms: a stop signal ends it early (nanosleep returns on a handled signal, SA_RESTART
// or not)
void sleep_ms(int ms)
{
	if (g_stop)
		return;
	struct timespec ts = { ms / 1000, (ms % 1000) * 1000000L };
	nanosleep(&ts, nullptr);
}

} // anonymous namespace

int main(int argc, char **argv)
{
	unsigned long base = 0;
	std::vector<std::string> cores = { "btltryst" };
	const char *log_path = "/tmp/m2mpegd.log";
	bool check = false;
	int threads = 2;   // a picture's work on both ARM cores (with one, the worst picture tears on a board)
	double pace = 0;   // --pace MS: each picture stored MS after its end entry was seen (0: as soon as it's ready)
	enum { WC_AUTO, WC_ON, WC_OFF } wc = WC_AUTO;
	for (int i = 1; i < argc; ++i)
	{
		if (!strcmp(argv[i], "--base") && i + 1 < argc) base = strtoul(argv[++i], nullptr, 16);
		else if (!strcmp(argv[i], "--cores") && i + 1 < argc)
		{
			cores.clear();
			std::string s = argv[++i];
			for (size_t a = 0, c; a <= s.size(); a = c + 1)
			{
				c = s.find(',', a);
				if (c == std::string::npos) c = s.size();
				if (c > a) cores.push_back(s.substr(a, c - a));
			}
		}
		else if (!strcmp(argv[i], "--log") && i + 1 < argc) log_path = argv[++i];
		else if (!strcmp(argv[i], "--check")) check = true;
		else if (!strcmp(argv[i], "--threads") && i + 1 < argc) threads = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--pace") && i + 1 < argc) pace = atof(argv[++i]);
		else if (!strcmp(argv[i], "--wc") && i + 1 < argc && !strcmp(argv[i + 1], "auto")) { wc = WC_AUTO; ++i; }
		else if (!strcmp(argv[i], "--wc") && i + 1 < argc && !strcmp(argv[i + 1], "on")) { wc = WC_ON; ++i; }
		else if (!strcmp(argv[i], "--wc") && i + 1 < argc && !strcmp(argv[i + 1], "off")) { wc = WC_OFF; ++i; }
		else
		{
			fprintf(stderr, "usage: m2mpegd --base HEX [--cores name,name] [--log FILE] [--check] [--threads 1|2] [--pace MS] [--wc auto|on|off]\n");
			return 2;
		}
	}
	if (!base || (base & 0x7ffff) || base < 0x30000000 || base + BLOCK_SIZE > 0x40000000)
	{
		fprintf(stderr, "m2mpegd: --base must be a 512 KB-aligned address in the core's DDR3 window (0x30000000-0x3FFFFFFF)\n");
		return 2;
	}
	printf("m2mpegd: block 0x%08lx (%u bytes), game RAM 0x%08x (%u bytes), cores:", base, BLOCK_SIZE, RAM_DDR3, RAM_BYTES);
	for (auto &c : cores)
		printf(" %s", c.c_str());
	printf(", log %s\n", log_path);
	if (check)
		return 0;

	FILE *log = fopen(log_path, "a");
	if (!log)
		log = stderr;
	setvbuf(log, nullptr, _IOLBF, 0);
	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);
	fprintf(log, "m2mpegd: started\n");

	while (!g_stop)
	{
		const std::string name = core_name();
		bool served = false;
		for (auto &c : cores)
			served |= name == c;
		if (!served)
		{
			sleep_ms(1000);
			continue;
		}

		const int fd = open("/dev/mem", O_RDWR | O_SYNC);
		if (fd < 0)
		{
			fprintf(log, "m2mpegd: /dev/mem: %s\n", strerror(errno));
			return 1;
		}
		void *bm = mmap(nullptr, BLOCK_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, off_t(base));
		if (bm == MAP_FAILED)
		{
			fprintf(log, "m2mpegd: can't map the block\n");
			close(fd);
			return 1;
		}
		volatile uint8_t *block = static_cast<volatile uint8_t *>(bm);

		// Attach only to a live block: the header right, and the beat moving
		const uint32_t b0 = ld32(block, OFF_BEAT);
		sleep_ms(60);
		const bool live = ld32(block, OFF_HEADER + 4) == MAGIC_HEADER && (ld32(block, OFF_HEADER) >> 16) == VERSION &&
				ld32(block, OFF_BEAT) != b0;
		if (live)
		{
			// game RAM: write-combined through the module if it's there (never also through /dev/mem: kernel/m2_mem_wc)
			const int wfd = wc == WC_OFF ? -1 : open("/dev/m2_mem_wc", O_RDWR | O_SYNC);
			if (wfd < 0 && wc == WC_ON)
			{
				fprintf(log, "m2mpegd: --wc on, but /dev/m2_mem_wc: %s\n", strerror(errno));
				munmap(bm, BLOCK_SIZE);
				close(fd);
				return 1;
			}
			void *rm = mmap(nullptr, RAM_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED, wfd >= 0 ? wfd : fd, off_t(RAM_DDR3));
			fprintf(log, "m2mpegd: game RAM through %s%s\n", wfd >= 0 ? "/dev/m2_mem_wc (write-combined)" : "/dev/mem",
					rm == MAP_FAILED ? ": can't map it" : "");
			if (rm != MAP_FAILED)
			{
				mpegd_options o;
				o.stop = &g_stop;
				o.log = log;
				o.threads = threads;
				o.pace_ms = pace;
				if (wfd >= 0)
					o.drain = [wfd] { ioctl(wfd, M2_MEM_WC_SYNC); };
				mpegd_stats st;
				// raised priority for the session only (its threads, made in it, take this thread's): back to normal after
				if (setpriority(PRIO_PROCESS, 0, -20))
					fprintf(log, "m2mpegd: can't raise priority (run as root)\n");
				const mpegd_end end = mpegd_session(block, static_cast<volatile uint8_t *>(rm), o, st);
				setpriority(PRIO_PROCESS, 0, 0);
				fprintf(log, "m2mpegd: session ended (%d): %llu pictures, %llu late, %llu resyncs, %llu errors, worst %.1f ms\n",
						int(end), (unsigned long long)st.pictures, (unsigned long long)st.late, (unsigned long long)st.resyncs,
						(unsigned long long)st.errors, st.worst_ms);
				munmap(rm, RAM_BYTES);
			}
			if (wfd >= 0)
				close(wfd);
		}
		munmap(bm, BLOCK_SIZE);
		close(fd);
		// Wait for the core to change or come back
		const std::string was = name;
		while (!g_stop && core_name() == was && !live)
			sleep_ms(1000);
		sleep_ms(1000);
	}
	fprintf(log, "m2mpegd: stopped\n");
	return 0;
}
