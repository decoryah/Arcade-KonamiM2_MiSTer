// m2_tk: the boards' M48T58 timekeeper: 8 KB of battery-backed RAM whose last eight bytes are a clock (ST's M48T58 data sheet;
// MAME 0.289's timekpr.cpp). As the games use it: the control register at 0x1FF8 (bit 7 W: the clock's bytes are being written; bit 6
// R: they hold still, to be read), then seconds, minutes, hours (24 h), the day of the week (1-7), the date, the month and the year (two
// digits), all BCD, at 0x1FF9-0x1FFF. Battle Tryst keeps its coin books in the RAM and counts them by the day; Heat of Eleven lights
// its matches by the time of day.
//
// The clock starts from the MiSTer's RTC (hps_io's: local time, sent once as the core starts; its day of the week 0-6, Sunday 0, is
// the chip's 1-7) and counts the seconds. Its bytes read as the counters, but hold still while R or W is set; the CPU's writes to them
// are kept, and clearing W sets the counters from them. The control register reads as written. The other bytes are memory, loaded
// from the MRA or the saved file. The CPU's writes to 0x0000-0x1FF7 pulse chg, for Main to save the 8 KB (the control register and the
// clock are left out: the games write them on every reading of the time).
//
// One read port, shared: the CPU's reads first (cpu_rd: the address coming up, ra, is the chip's), the save's (ua) otherwise. The
// CPU's byte is rd a clock after its address; the save's, ud, a clock after that.
`default_nettype none
module m2_tk #(
	parameter int HZ = 66666667         // clk's frequency: the seconds
) (
	input  logic        clk,
	// verilator lint_off UNUSEDSIGNAL
	input  logic [64:0] rtc,            // hps_io's RTC: BCD seconds [7:0], minutes, hours, date, month, year [47:40], the day [55:48]; [64] toggles
	// verilator lint_on UNUSEDSIGNAL

	input  logic        ld_we,          // the download (the MRA's image, the saved file)
	input  logic [12:0] ld_a,
	input  logic [7:0]  ld_d,

	input  logic        we,             // the CPU
	input  logic [12:0] wa,
	input  logic [7:0]  wd,
	input  logic        cpu_rd,
	input  logic [12:0] ra,
	output logic [7:0]  rd,

	input  logic [12:0] ua,             // the save (Main's upload)
	output logic [7:0]  ud,
	output logic        chg
);
	// the memory
	logic [7:0]  ram_q;
	ppc_ram #(.W(8), .AW(13)) ram
	(
		.clk, .we(ld_we || we), .wa(ld_we ? ld_a : wa), .wd(ld_we ? ld_d : wd), .ra(cpu_rd ? ra : ua), .rd(ram_q)
	);
	logic        up_l;
	always_ff @(posedge clk)
	begin
		up_l <= !cpu_rd;
		if (up_l) ud <= ram_q;
	end
	assign chg = we && wa < 13'h1ff8;

	// the clock: the counters, and the bytes as they read (sh: seconds .. year; ctl the control register)
	logic [7:0]  c_sec, c_min, c_hour, c_day, c_date, c_mon, c_year;
	logic [7:0]  sh [0:6];
	logic [7:0]  ctl;
	logic [26:0] div;
	logic        rtc_t;
	// (before the RTC comes: 2000-01-01, a Saturday, 00:00:00)
	initial
	begin
		c_sec = 8'h00; c_min = 8'h00; c_hour = 8'h00; c_day = 8'h07; c_date = 8'h01; c_mon = 8'h01; c_year = 8'h00;
		ctl = 8'h00; div = '0; rtc_t = 1'b0;
		for (int i = 0; i < 7; i++) sh[i] = 8'h00;
	end
	wire         tick = div == 27'(HZ - 1);

	function automatic logic [7:0] bcd_inc(input logic [7:0] v);
		return v[3:0] == 4'd9 ? {v[7:4] + 4'd1, 4'd0} : {v[7:4], v[3:0] + 4'd1};
	endfunction

	// the month's last date (2000-2099: a leap year is one the 4 divides; mod 4 the year is its units plus twice its tens, 10 being 2
	// mod 4, so the units' low two bits plus the tens' low bit, twice)
	wire [1:0]   yr4 = c_year[1:0] + {c_year[4], 1'b0};
	wire [7:0]   last = c_mon == 8'h02 ? (yr4 == 2'd0 ? 8'h29 : 8'h28) :
	                    (c_mon == 8'h04 || c_mon == 8'h06 || c_mon == 8'h09 || c_mon == 8'h11) ? 8'h30 : 8'h31;

	// (always, not always_ff: these registers have power-up values, above, and no reset)
	always @(posedge clk)
	begin
		div <= tick ? '0 : div + 27'd1;
		rtc_t <= rtc[64];
		if (rtc[64] != rtc_t)
		begin
			c_sec <= rtc[7:0]; c_min <= rtc[15:8]; c_hour <= rtc[23:16];
			c_date <= rtc[31:24]; c_mon <= rtc[39:32]; c_year <= rtc[47:40];
			c_day <= {5'd0, rtc[50:48]} + 8'd1;
			div <= '0;
		end
		else if (we && wa == 13'h1ff8 && ctl[7] && !wd[7])
		begin
			// W cleared: the clock from its bytes (without the chip's flag bits: ST, FT, CEB / CB)
			c_sec <= sh[0] & 8'h7f; c_min <= sh[1] & 8'h7f; c_hour <= sh[2] & 8'h3f; c_day <= sh[3] & 8'h07;
			c_date <= sh[4] & 8'h3f; c_mon <= sh[5] & 8'h1f; c_year <= sh[6];
			div <= '0;
		end
		else if (tick)
		begin
			if (c_sec != 8'h59) c_sec <= bcd_inc(c_sec);
			else
			begin
				c_sec <= 8'h00;
				if (c_min != 8'h59) c_min <= bcd_inc(c_min);
				else
				begin
					c_min <= 8'h00;
					if (c_hour != 8'h23) c_hour <= bcd_inc(c_hour);
					else
					begin
						c_hour <= 8'h00;
						c_day <= c_day == 8'h07 ? 8'h01 : c_day + 8'd1;
						if (c_date != last) c_date <= bcd_inc(c_date);
						else
						begin
							c_date <= 8'h01;
							if (c_mon != 8'h12) c_mon <= bcd_inc(c_mon);
							else
							begin
								c_mon <= 8'h01;
								c_year <= c_year == 8'h99 ? 8'h00 : bcd_inc(c_year);
							end
						end
					end
				end
			end
		end

		if (we && wa == 13'h1ff8) ctl <= wd;
		if (we && wa > 13'h1ff8) sh[wa[2:0] - 3'd1] <= wd;
		else if (!ctl[6] && !ctl[7])
		begin
			sh[0] <= c_sec; sh[1] <= c_min; sh[2] <= c_hour; sh[3] <= c_day;
			sh[4] <= c_date; sh[5] <= c_mon; sh[6] <= c_year;
		end
	end

	// the CPU's byte: the clock's (the control register, the clock's bytes) or the memory's
	logic        rk;
	logic [7:0]  rk_d;
	always_ff @(posedge clk)
	begin
		rk <= ra >= 13'h1ff8;
		rk_d <= ra[2:0] == 3'd0 ? ctl : sh[ra[2:0] - 3'd1];
	end
	assign rd = rk ? rk_d : ram_q;
endmodule
`default_nettype wire
