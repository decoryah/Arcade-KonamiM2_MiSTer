// m2mpegd_core: the daemon's side of PROTOCOL.md, on any mapping of the block and of game RAM (the board's /dev/mem, or a
// bench's memory). m2mpegd.cpp (the daemon) and the core's sim/mpeg/tb_mpeg_hps.cpp (the RTL's bench) both run mpegd_session.
#ifndef M2MPEGD_CORE_H
#define M2MPEGD_CORE_H

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <functional>

struct mpegd_options
{
	std::atomic<bool> *stop = nullptr;  // set: leave cleanly (present's magic cleared)
	std::atomic<bool> *die = nullptr;   // set: stop at once, as a killed process would (nothing cleared; benches only)
	bool from_newest = true;            // start after the newest entry (attaching to a running core); false: from entry 0
	double pace_ms = 0;                 // > 0: a picture's pixels are stored this long after its end entry was seen (or as soon
	                                    // after as they are ready), so the store falls at one place in the game's frame
	int threads = 1;                    // 2: a picture's work on two threads (m2mpeg_unit::decode_format); the pixels are the same
	int slow_picture = -1;              // benches only: before writing this picture's pixels (counted from 0)...
	int slow_ms = 0;                    // ...sleep this long (the late path)
	FILE *log = nullptr;                // messages (nullptr: none)
	std::function<void()> drain;        // set: called after a picture's stores, before its done word (the board with game
	                                    // RAM write-combined through m2_mem_wc: the L2 controller's store buffer drained)
};

struct mpegd_stats
{
	uint64_t pictures = 0;              // pictures decoded and written
	uint64_t late = 0;                  // written after the FPGA's time-out
	uint64_t resyncs = 0;               // lost the log (FPGA reset, or a lap behind)
	uint64_t errors = 0;                // decoder errors (the picture is still written, as the emulator does)
	uint64_t entries = 0;               // log entries taken
	uint64_t unpaced = 0;               // with pace_ms: pictures not ready at their time (stored late, at no fixed place)
	uint64_t slow = 0;                  // pictures over SLOW_MS (a 30-a-second movie's slot is 33 ms: those may show torn)
	double worst_ms = 0;                // slowest picture, entry to done
	double total_ms = 0;
};

enum class mpegd_end { stopped, died, beat_stopped, header_gone };

// Runs until told to stop or the core goes; the block at 'block' (BLOCK_SIZE bytes), game RAM at 'ram' (RAM_BYTES)
mpegd_end mpegd_session(volatile uint8_t *block, volatile uint8_t *ram, const mpegd_options &opt, mpegd_stats &st);

#endif
