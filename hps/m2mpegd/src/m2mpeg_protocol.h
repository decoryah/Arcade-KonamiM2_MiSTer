// m2mpeg_protocol.h: the DDR3 block between the core's MPEG unit and the ARM daemon (PROTOCOL.md, version 1).
// Control words are 64-bit, little-endian in memory (bits 7:0 at the lowest address), read and written here as two 32-bit
// halves: the low half at +0, the high half at +4. M2 data (ring bytes, pixels) are in M2 byte order.
#ifndef M2MPEG_PROTOCOL_H
#define M2MPEG_PROTOCOL_H

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace m2p {

constexpr uint32_t BLOCK_SIZE    = 0x50000;
constexpr uint32_t OFF_HEADER    = 0x00000;
constexpr uint32_t OFF_BEAT      = 0x00008;
constexpr uint32_t OFF_PRESENT   = 0x00040;     // low: heartbeat, high: magic
constexpr uint32_t OFF_DONE      = 0x00048;
constexpr uint32_t OFF_STATS     = 0x00080;     // 8 x 32-bit, diagnostic
constexpr uint32_t OFF_LOG       = 0x01000;
constexpr uint32_t OFF_RING      = 0x10000;

constexpr uint32_t MAGIC_HEADER  = 0x4D324D50;  // "M2MP"
constexpr uint32_t MAGIC_PRESENT = 0x4D504744;  // "MPGD"
constexpr uint32_t VERSION       = 1;
constexpr uint32_t LOG_BITS      = 12;
constexpr uint32_t LOG_ENTRIES   = 1u << LOG_BITS;
constexpr uint32_t RING_BITS     = 18;
constexpr uint32_t RING_BYTES    = 1u << RING_BITS;
constexpr uint32_t SEQ_MASK      = 0x1fff;      // entry numbers mod 8192
constexpr uint32_t POS_MASK      = 0xffffff;    // stream positions mod 2^24
constexpr uint32_t DONE_VALID    = 0x80000000;

// The FPGA's timing rules (PROTOCOL.md "The FPGA's rules")
constexpr int HOLD_POLL_US       = 250;         // 2^14 clocks
constexpr int DEAD_MS            = 50;          // heartbeat unchanged this long: no daemon
constexpr int TIMEOUT_MS         = 120;         // a held picture is released after this
constexpr int SLOW_MS            = 29;          // the daemon counts and logs pictures slower than this (statistics word 5)
constexpr int BEAT_MS            = 16;          // 2^20 clocks
// The daemon's
constexpr int HEARTBEAT_MS       = 5;
constexpr int BEAT_STOPPED_MS    = 200;

// M2 main RAM as the core keeps it in DDR3
constexpr uint32_t RAM_M2_BASE   = 0x40000000;
constexpr uint32_t RAM_DDR3      = 0x31000000;
constexpr uint32_t RAM_BYTES     = 0x01000000;

// Log entry high half (bits 63:32): [31] valid, [30:29] kind, [28:16] sequence, [15:0] bits 47:32 of the payload
constexpr uint32_t entry_hi(uint32_t kind, uint32_t seq, uint32_t payload_hi16)
{
	return 0x80000000u | (kind << 29) | ((seq & SEQ_MASK) << 16) | (payload_hi16 & 0xffff);
}
inline bool hi_valid(uint32_t hi) { return hi >> 31; }
inline uint32_t hi_kind(uint32_t hi) { return (hi >> 29) & 3; }
inline uint32_t hi_seq(uint32_t hi) { return (hi >> 16) & SEQ_MASK; }

enum : uint32_t { KIND_WRITE = 0, KIND_PICTURE_END = 1 };

// Block access: 32-bit loads and stores with ordering (acquire / release), on a mapping of the block (a bench's
// memory, or /dev/mem's strongly ordered mapping on the board, where they are plain ldr / str with barriers)
inline uint32_t ld32(volatile uint8_t *b, uint32_t off)
{
	return __atomic_load_n(reinterpret_cast<volatile uint32_t *>(b + off), __ATOMIC_ACQUIRE);
}
inline void st32(volatile uint8_t *b, uint32_t off, uint32_t v)
{
	__atomic_store_n(reinterpret_cast<volatile uint32_t *>(b + off), v, __ATOMIC_RELEASE);
}
inline void full_barrier()
{
#if defined(__arm__)
	__asm__ volatile("dsb sy" ::: "memory");
#else
	__atomic_thread_fence(__ATOMIC_SEQ_CST);
#endif
}

// Copy n bytes from a device mapping (aligned 32-bit loads only: strongly ordered memory takes no unaligned access)
inline void copy_from_device(uint8_t *dst, volatile uint8_t *src, size_t n)
{
	size_t i = 0;
	const uintptr_t mis = reinterpret_cast<uintptr_t>(src) & 3;
	if (mis)
	{
		const uint32_t w = *reinterpret_cast<volatile uint32_t *>(src - mis);
		for (size_t k = mis; k < 4 && i < n; ++k)
			dst[i++] = uint8_t(w >> (8 * k));
	}
	for ( ; i + 4 <= n; i += 4)
	{
		const uint32_t w = *reinterpret_cast<volatile uint32_t *>(src + i);
		memcpy(dst + i, &w, 4);
	}
	if (i < n)
	{
		const uint32_t w = *reinterpret_cast<volatile uint32_t *>(src + i);
		for (size_t k = 0; i < n; ++k)
			dst[i++] = uint8_t(w >> (8 * k));
	}
}

// Copy n bytes to a device mapping: bytes up to an 8-byte boundary, 64-byte NEON block stores (the fastest measured on a
// DE10-Nano: 121 MB/s), 8-byte stores, then bytes
inline void copy_to_device(volatile uint8_t *dst, const uint8_t *src, size_t n)
{
	size_t i = 0;
	while (i < n && (reinterpret_cast<uintptr_t>(dst + i) & 7))
	{
		dst[i] = src[i];
		++i;
	}
#if defined(__arm__) && defined(__ARM_NEON)
	for ( ; i + 64 <= n; i += 64)
	{
		const uint8_t *s = src + i;
		__asm__ volatile("vld1.8 {d16-d19}, [%1]!\n\tvld1.8 {d20-d23}, [%1]\n\tvstm %2, {d16-d23}"
				: "=r"(s) : "0"(s), "r"(dst + i)
				: "d16", "d17", "d18", "d19", "d20", "d21", "d22", "d23", "memory");
	}
#endif
	for ( ; i + 8 <= n; i += 8)
	{
		uint64_t w;
		memcpy(&w, src + i, 8);
		*reinterpret_cast<volatile uint64_t *>(dst + i) = w;
	}
	for ( ; i < n; ++i)
		dst[i] = src[i];
}

} // namespace m2p

#endif
