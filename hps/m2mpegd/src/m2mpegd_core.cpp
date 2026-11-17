// m2mpegd_core: see m2mpegd_core.h and PROTOCOL.md ("The daemon's rules").
#include "m2mpegd_core.h"
#include "m2mpeg_protocol.h"
#include "m2mpeg_unit.h"

#include <algorithm>
#include <chrono>
#include <thread>
#include <vector>

using namespace m2p;

namespace {

double now_ms()
{
	return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

void sleep_us(int us)
{
	std::this_thread::sleep_for(std::chrono::microseconds(us));
}

// The entry number after the newest one written (0 if none): the newest is the one whose next slot doesn't hold the
// next number
uint32_t after_newest(volatile uint8_t *b)
{
	bool any = false;
	uint32_t next = 0;
	for (uint32_t i = 0; i < LOG_ENTRIES; ++i)
	{
		const uint32_t hi = ld32(b, OFF_LOG + 8 * i + 4);
		if (!hi_valid(hi))
			continue;
		any = true;
		const uint32_t s = hi_seq(hi);
		const uint32_t nh = ld32(b, OFF_LOG + 8 * ((i + 1) & (LOG_ENTRIES - 1)) + 4);
		if (!hi_valid(nh) || hi_seq(nh) != ((s + 1) & SEQ_MASK))
			next = (s + 1) & SEQ_MASK;
	}
	return any ? next : 0;
}

void msg(const mpegd_options &opt, const char *fmt, uint32_t a = 0, uint32_t b = 0)
{
	if (opt.log)
	{
		fprintf(opt.log, fmt, a, b);
		fputc('\n', opt.log);
		fflush(opt.log);
	}
}

} // anonymous namespace


mpegd_end mpegd_session(volatile uint8_t *block, volatile uint8_t *ram, const mpegd_options &opt, mpegd_stats &st)
{
	if (ld32(block, OFF_HEADER + 4) != MAGIC_HEADER || (ld32(block, OFF_HEADER) >> 16) != VERSION)
		return mpegd_end::header_gone;

	m2mpeg_unit unit(RAM_M2_BASE, RAM_M2_BASE + RAM_BYTES - 1);
	m2mpeg_regs regs;
	m2mpeg_output out;
	std::vector<uint8_t> pic;

	// Present, and the heartbeat from a thread of its own (it must move while a picture decodes)
	std::atomic<bool> beating{true};
	auto dying = [&] { return opt.die && opt.die->load(); };
	uint32_t hb = ld32(block, OFF_PRESENT);
	st32(block, OFF_PRESENT, ++hb);
	st32(block, OFF_PRESENT + 4, MAGIC_PRESENT);
	std::thread heart([&, hb] () mutable {
		while (beating && !dying())
		{
			std::this_thread::sleep_for(std::chrono::milliseconds(HEARTBEAT_MS));
			if (beating && !dying())
				st32(block, OFF_PRESENT, ++hb);
		}
	});

	uint32_t e = opt.from_newest ? after_newest(block) : 0;
	uint32_t last_beat = ld32(block, OFF_BEAT);
	double beat_seen = now_ms();
	int picture_index = 0;
	mpegd_end end = mpegd_end::stopped;
	msg(opt, "m2mpegd: attached, starting at entry %u", e);

	while (true)
	{
		if (dying())
		{
			end = mpegd_end::died;
			break;
		}
		if (opt.stop && opt.stop->load())
			break;

		const uint32_t slot = e & (LOG_ENTRIES - 1);
		const uint32_t hi = ld32(block, OFF_LOG + 8 * slot + 4);
		if (hi_valid(hi) && hi_seq(hi) == e)
		{
			const uint32_t lo = ld32(block, OFF_LOG + 8 * slot);
			++st.entries;
			if (hi_kind(hi) == KIND_WRITE)
				regs.write((hi & 0xff) << 2, lo);
			else if (hi_kind(hi) == KIND_PICTURE_END)
			{
				const double t0 = now_ms();
				const uint32_t len = ((hi & 0xffff) << 8) | (lo >> 24);
				const uint32_t first = ((lo & POS_MASK) - len) & POS_MASK & (RING_BYTES - 1);
				pic.resize(len);
				const uint32_t n1 = std::min(len, RING_BYTES - first);
				copy_from_device(pic.data(), block + OFF_RING + first, n1);
				if (len > n1)
					copy_from_device(pic.data() + n1, block + OFF_RING, len - n1);

				// the formatted picture into game RAM (with two threads: from the second, while the first still decodes)
				auto store = [&] (const m2mpeg_output &o) {
					if (picture_index == opt.slow_picture)
						std::this_thread::sleep_for(std::chrono::milliseconds(opt.slow_ms));
					if (o.present)
					{
						const uint32_t rb = o.row_bytes();
						size_t b = 0;
						for (size_t r = 0; r < o.written.size(); ++r)
							if (o.written[r])
							{
								const uint32_t addr = regs.format_output + uint32_t(r) * o.stride;
								copy_to_device(ram + ((addr - RAM_M2_BASE) & (RAM_BYTES - 1)), o.bytes.data() + b, rb);
								b += rb;
							}
						// (on the thread that stored: a dsb waits only for its own core's stores; then opt.drain)
						full_barrier();
					}
				};
				if (opt.pace_ms > 0)
				{
					// (the game draws the movie from its block every frame, whenever the MPEG unit is done or not, and starts
					// a picture at one place in its frame: a store a fixed time after that falls at one place in the frame too,
					// which can be chosen outside the frame's read of the block. So: decode and format, wait, then store)
					if (opt.threads >= 2 ? unit.decode_format(regs, pic.data(), len, out, opt.threads, nullptr) : unit.decode(regs, pic.data(), len))
						++st.errors;
					if (opt.threads < 2)
						unit.format(regs, out);
					const double left = t0 + opt.pace_ms - now_ms();
					if (left > 0)
						std::this_thread::sleep_for(std::chrono::microseconds(int64_t(left * 1000)));
					else
						++st.unpaced;
					store(out);
				}
				else if (opt.threads >= 2)
				{
					if (unit.decode_format(regs, pic.data(), len, out, opt.threads, store))
						++st.errors;
				}
				else
				{
					if (unit.decode(regs, pic.data(), len))
						++st.errors;
					unit.format(regs, out);
					store(out);
				}
				if (opt.drain)
					opt.drain();
				full_barrier();
				st32(block, OFF_DONE, DONE_VALID | e);

				const double dt = now_ms() - t0;
				++st.pictures;
				if (dt > TIMEOUT_MS)
				{
					++st.late;
					msg(opt, "m2mpegd: picture at entry %u late (%u ms)", e, uint32_t(dt));
				}
				else if (dt > SLOW_MS)
				{
					// (a 30-a-second movie's slot is 33 ms: a picture this slow may be copied while the game shows its
					// block, a tear on the screen. Its number in the stream and its time, to match against what's seen)
					++st.slow;
					msg(opt, "m2mpegd: slow picture %u (%u ms)", uint32_t(picture_index), uint32_t(dt));
				}
				st.worst_ms = std::max(st.worst_ms, dt);
				st.total_ms += dt;
				++picture_index;
				st32(block, OFF_STATS + 0, uint32_t(st.pictures));
				st32(block, OFF_STATS + 4, uint32_t(st.late));
				st32(block, OFF_STATS + 8, uint32_t(st.resyncs));
				st32(block, OFF_STATS + 12, uint32_t(st.errors));
				st32(block, OFF_STATS + 16, uint32_t(st.worst_ms * 1000));
				st32(block, OFF_STATS + 20, uint32_t(st.slow));
				st32(block, OFF_STATS + 24, uint32_t(st.unpaced));
			}
			e = (e + 1) & SEQ_MASK;
			continue;
		}

		if (!hi_valid(hi) || hi_seq(hi) == ((e - LOG_ENTRIES) & SEQ_MASK))
		{
			// Nothing new: watch the core, then wait a little
			const uint32_t beat = ld32(block, OFF_BEAT);
			const double t = now_ms();
			// (a reset is also seen by our present word: the FPGA's reset clears the line we write, which nothing
			// else does. That catches a reset the count can't show: one while the count was still 0, or one after
			// which the count passed its old value before we looked)
			const bool cleared = ld32(block, OFF_PRESENT + 4) != MAGIC_PRESENT;
			if (beat != last_beat || cleared)
			{
				if (beat < last_beat || cleared)
				{
					// The FPGA was reset: its log starts again at entry 0, and it cleared the line we write
					if (cleared)
						msg(opt, "m2mpegd: core reset (present word cleared; beat %u -> %u)", last_beat, beat);
					else
						msg(opt, "m2mpegd: core reset (beat %u -> %u)", last_beat, beat);
					++st.resyncs;
					e = 0;
					unit.reset();
					regs = m2mpeg_regs();
					// (the FPGA's reset clears the line before it writes the count again: give it 1 ms to
					// finish, so the count it starts from isn't taken for a second reset)
					if (cleared)
						sleep_us(1000);
					st32(block, OFF_PRESENT + 4, MAGIC_PRESENT);
				}
				last_beat = cleared ? ld32(block, OFF_BEAT) : beat;
				beat_seen = t;
			}
			else if (t - beat_seen > BEAT_STOPPED_MS)
			{
				end = mpegd_end::beat_stopped;
				break;
			}
			if (ld32(block, OFF_HEADER + 4) != MAGIC_HEADER)
			{
				end = mpegd_end::header_gone;
				break;
			}
			sleep_us(100);
			continue;
		}

		// A number that isn't the next one or the lap before's: lost (a lap behind, or a reset we didn't see)
		msg(opt, "m2mpegd: lost the log at entry %u (found %u), resynchronizing", e, hi_seq(hi));
		++st.resyncs;
		e = after_newest(block);
		unit.reset();
	}

	beating = false;
	heart.join();
	if (end != mpegd_end::died)
		st32(block, OFF_PRESENT + 4, 0);   // leaving: the FPGA stops holding pictures at once
	msg(opt, "m2mpegd: left (%u pictures)", uint32_t(st.pictures));
	return end;
}
