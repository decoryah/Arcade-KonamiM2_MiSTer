//============================================================================
//
//  Konami M2 (MAME's konami/konamim2.cpp) for MiSTer -- work in progress.
//
//  The board: two PowerPC 602s at 66.67 MHz, the 3DO M2 BDA (memory controller, triangle engine, video, the DSP that makes
//  the sound, MPEG), the CDE (the CD drive's ATAPI bus) and Konami's I/O; the game on a CD. First target: Tobe! Polystars.
//  For now this is the CPU bring-up (rtl/m2_boot.sv): ppc1 runs the boot ROM (downloaded by the MRA into DDR3) at
//  66.67 MHz, with main RAM in DDR3 and the board's registers as stubs, and the picture's shown
//  in a raster near the NTSC timing MAME gives the board (rtl/m2_vtiming.sv). The rest of the machine comes in as its
//  parts pass their benches (docs/design.md).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 3 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

wire [15:0] audio_l, audio_r;
assign AUDIO_S   = 1;
assign AUDIO_MIX = 0;
assign AUDIO_L   = audio_l;
assign AUDIO_R   = audio_r;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;

// DDR3: the bring-up's ROM and RAM (below). The SDRAM: the Triangle Engine's Z buffer with Z_SDRAM (rtl/m2_zmem.sv, below), else idle
`ifndef Z_SDRAM
assign SDRAM_DQ   = 'Z;
assign SDRAM_A    = 13'd0;
assign SDRAM_BA   = 2'd0;
assign {SDRAM_DQML, SDRAM_DQMH} = 2'b11;
assign {SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS} = 4'b1111;
assign SDRAM_CKE  = 1'b0;
assign SDRAM_CLK  = 1'b0;
`endif

assign DDRAM_CLK      = clk_cpu;

//////////////////////////////////////////////////////////////////

wire [127:0] status;
wire   [1:0] buttons;
wire         forced_scandoubler;
wire         direct_video;
wire  [21:0] gamma_bus;

wire  [1:0] ar = status[122:121];
reg   [2:0] scale_sel;
always @* case (status[34:32])
	3'd1:    scale_sel = 3'd1;
	3'd2:    scale_sel = 3'd4;
	3'd3:    scale_sel = 3'd2;
	3'd4:    scale_sel = 3'd3;
	default: scale_sel = 3'd0;
endcase
wire        fs_int = (ar == 2'd1) && (scale_sel != 3'd0) && (HDMI_WIDTH != 12'd0) && (HDMI_HEIGHT != 12'd0);

`include "build_id.v"
localparam CONF_STR = {
	"A.KONAMIM2;;",
	"SC0,BIN,CD audio image;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[34:32],Scale,Normal,V-Integer,HV-Integer,Narrower HV-Integer,HV-Integer+;",
	"-;",
	"H1O[36:35],P1 Stick,Auto,Aim,D-pad;",
	"H1O[38:37],P2 Stick,Auto,Aim,D-pad;",
	"H2O[40:39],P3 Stick,Auto,Aim,D-pad;",
	"H1O[42:41],Mouse,Player 1,Player 2,Player 3,Off;",
	"H1O[45:43],Crosshair,Off,Player 1,Player 2,Player 3,P1+P2,All;",
	"H1-;",
	"O[3],Service mode,Off,On;",
`ifndef PPC_CACHE_KB
	"O[6:5],CPU caches (at reset),32 KB,16 KB,8 KB,4 KB as the 602;",  // (each side: rtl/ppc_cache.sv's size; a build that sets PPC_CACHE_KB has its own)
`endif
`ifdef Z_SDRAM
	"O[4],SDRAM read timing,Normal,Late;",  // (the Z buffer's: its read data a clock later, for a module that answers slowly)
`endif
	"DIP;",
	"R0,Reset;",
	"J1,Button 1,Button 2,Button 3,Start,Coin;",
	"V,v",`BUILD_DATE
};

////////////////////   CLOCKS   ///////////////////

wire clk_sys;           // 66.67 MHz: the CPUs and the BDA (M2_CLOCK); the pixels are a fractional clock enable on it
wire clk_mem;           // 133.33 MHz: memory
wire clk_sdram;         // 133.33 MHz, shifted: the SDRAM chip's clock
wire clk_cpu = clk_sys; // the bring-up's CPU and DDR3 port
wire pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_mem),
	.outclk_2(clk_sdram),
	.locked(pll_locked)
);

`ifdef Z_SDRAM
wire [15:0] sd_dq_o;
wire        sd_dq_oe;
assign SDRAM_DQ  = sd_dq_oe ? sd_dq_o : 16'bZ;
assign SDRAM_nCS = 1'b0;
assign SDRAM_CKE = 1'b1;
assign SDRAM_CLK = clk_sdram;           // (as the Gaelco 3D core: the PLL's shifted output straight to the pin)
`endif

///////////////////////////////////////////////////

wire         ioctl_download;
wire         ioctl_wr;
wire  [15:0] ioctl_index;
wire  [26:0] ioctl_addr;
wire   [7:0] ioctl_dout;
wire         ioctl_wait;
wire   [7:0] ee_ud;         // the EEPROM, for Main to save (the MRA's nvram, index 2): it asks with ioctl_addr and takes the byte a while later
wire         ee_chg;

wire  [31:0] joystick_0, joystick_1, joystick_2;
wire  [15:0] joystick_l_analog_0, joystick_l_analog_1, joystick_l_analog_2;
wire  [24:0] ps2_mouse;

wire         img_mounted;
wire  [63:0] img_size;
wire  [31:0] sd_lba;
wire         sd_rd, sd_ack, sd_buff_wr;
wire   [7:0] sd_buff_dout;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),

	.buttons(buttons),
	.status(status),
	.status_menumask({13'd0, ~gun_game | board[2], ~gun_game, direct_video}),
	.forced_scandoubler(forced_scandoubler),
	.direct_video(direct_video),
	.gamma_bus(gamma_bus),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),
	.ioctl_upload(),
	.ioctl_upload_req(ee_chg),      // (Main saves on the OSD's opening only when asked)
	.ioctl_upload_index(8'd2),
	.ioctl_din(ee_ud),
	.ioctl_rd(),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_2(joystick_2),
	.joystick_l_analog_0(joystick_l_analog_0),
	.joystick_l_analog_1(joystick_l_analog_1),
	.joystick_l_analog_2(joystick_l_analog_2),
	.ps2_mouse(ps2_mouse),

	.img_mounted(img_mounted),
	.img_size(img_size),
	.sd_lba('{sd_lba}),
	.sd_blk_cnt('{6'd7}),
	.sd_rd(sd_rd),
	.sd_wr(1'b0),
	.sd_ack(sd_ack),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din('{8'd0}),
	.sd_buff_wr(sd_buff_wr)
);

// the board's byte (the MRA, index 3, after the M48T58's 8 KB): bit 0 RAM 2 x 8 MB (m2_boot), bit 1 the guns and their inputs, bit 2 Total Vice's two players, who reload by shooting off the screen
reg   [7:0] board = 8'h00;
wire        gun_game = board[1];
always @(posedge clk_sys) if (ioctl_wr && ioctl_download && ioctl_index == 16'd3 && ioctl_addr == 27'h2000) board <= ioctl_dout;

// the DIP switches (the MRA's <switches>, ioctl index 254): byte 0 is IO1 2, MAME's P2: bit 0 the sound, 1 mono, bit 1 the screen, 0 flipped;
// stereo by default
reg   [7:0] dsw = 8'hfe;
always @(posedge clk_sys) if (ioctl_wr && ioctl_download && ioctl_index[7:0] == 8'd254 && ioctl_addr == 27'd0) dsw <= ioctl_dout;

reg cd_mounted = 1'b0;
always @(posedge clk_sys) if (img_mounted) cd_mounted <= |img_size;

wire        reset_sw = RESET | status[0] | buttons[1];
reg         core_rst = 1'b1;
always @(posedge clk_sys) core_rst <= reset_sw | ioctl_download | ~pll_locked;

///////////////////////   THE BRING-UP   ///////////////////////

// The download (index 0 the boot ROM, 1 the CD image, 2 the EEPROM, 3 the M48T58 and the board) into clk_cpu: each byte a toggle of ld_req, held (ioctl_wait) until the CPU side
// has given it to m2_boot and toggled ld_ack back.
// Fast load (the MRA's address=, as the owner's other cores): Main_MiSTer copies a ROM straight to its place in the DDR3 and ends a download that
// has no bytes, only a start address, the length. Those places are where the bytes would go anyway, so only the status page's sizes need it.
reg         ld_req = 1'b0, ld_ack = 1'b0;
reg  [26:0] ld_a;
reg   [2:0] ld_sel;
reg   [7:0] ld_d;
reg   [1:0] ack_s;
always @(posedge clk_sys) begin
	ack_s <= {ack_s[0], ld_ack};
	if (ioctl_wr && ioctl_download && ioctl_index <= 16'd4) begin
		ld_req <= ~ld_req;
		ld_a <= ioctl_addr;
		ld_sel <= ioctl_index[2:0];
		ld_d <= ioctl_dout;
	end
end
assign ioctl_wait = ld_req != ack_s[1];

reg   [1:0] req_s, cpu_rst_s;
reg   [1:0] lst;
reg         ld_wr_c;
wire        ld_wait_c;
always @(posedge clk_cpu) begin
	req_s <= {req_s[0], ld_req};
	cpu_rst_s <= {cpu_rst_s[0], core_rst};
	ld_wr_c <= 1'b0;
	case (lst)
		2'd0: if (req_s[1] != ld_ack) begin ld_wr_c <= 1'b1; lst <= 2'd1; end
		2'd1: lst <= 2'd2;
		default: if (!ld_wait_c) begin ld_ack <= req_s[1]; lst <= 2'd0; end
	endcase
end

// the gun games' 2P Start, and P1's Button 3 while the OSD's Service mode is on: Total Vice's test menu opens an item only with 2P Start
wire        p2_start = joystick_1[7] | (status[3] & joystick_0[6]);

wire  [9:0] gun_x [0:2];
wire  [7:0] gun_y [0:2];
wire [15:0] gun_p5;
wire  [9:0] hpos;
wire  [8:0] vpos;
wire [23:0] vdu_rgb;
wire        vdu_on;
m2_boot #(.TICK(8)) u_boot
(
	.clk(clk_cpu), .rst(cpu_rst_s[1]),
	.ld_wr(ld_wr_c), .ld_sel(ld_sel), .ld_addr(ld_a[25:0]), .ld_data(ld_d), .ld_wait(ld_wait_c),
	.ee_ua(ioctl_addr[6:0]), .ee_ud(ee_ud), .ee_chg(ee_chg),
	.in_p1({6'b111111, ~joystick_1[8], ~joystick_0[8]}),  // (the service coin not on a button: Coin does as much)
	.in_dsw(dsw),
	.hpos(hpos), .vpos(vpos), .rgb(vdu_rgb), .vdu_on(vdu_on), .audio_l(audio_l), .audio_r(audio_r),
	.cd_mounted(cd_mounted), .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack), .sd_wr(sd_buff_wr), .sd_d(sd_buff_dout),
	.in_p4(gun_game ? {~p2_start, 7'h7f, ~joystick_0[7], 3'b111, ~joystick_2[8], ~joystick_2[7], 2'b11}
	               : ~{joystick_1[7:4], joystick_1[2], joystick_1[3], joystick_1[0], joystick_1[1],
	                   joystick_0[7:4], joystick_0[2], joystick_0[3], joystick_0[0], joystick_0[1]}),
	.in_p5(gun_game ? gun_p5 : 16'hffff), .gun_x(gun_x), .gun_y(gun_y),
	.in_p6({13'h1fff, ~status[3], 2'b11}),
`ifndef PPC_CACHE_KB
	.cache_size(status[6:5]),
`else
	.cache_size(2'd0),
`endif
	.ddr_busy(DDRAM_BUSY), .ddr_burstcnt(DDRAM_BURSTCNT), .ddr_addr(DDRAM_ADDR), .ddr_dout(DDRAM_DOUT),
	.ddr_dout_ready(DDRAM_DOUT_READY), .ddr_rd(DDRAM_RD), .ddr_din(DDRAM_DIN), .ddr_be(DDRAM_BE), .ddr_we(DDRAM_WE),
`ifdef Z_SDRAM
	.clk_mem(clk_mem), .sd_late(status[4]), .sd_a(SDRAM_A), .sd_ba(SDRAM_BA), .sd_dqm({SDRAM_DQMH, SDRAM_DQML}),
	.sd_nras(SDRAM_nRAS), .sd_ncas(SDRAM_nCAS), .sd_nwe(SDRAM_nWE), .sd_dq_o(sd_dq_o), .sd_dq_oe(sd_dq_oe), .sd_dq_i(SDRAM_DQ),
`endif
	.st_pc(), .st_count(), .st_exc(), .st_nexc(), .st_dev_a(), .st_dev_d(), .st_dev_w(), .st_ndev(),
	.retire(), .retire2(), .ipc0_o(), .ipc_o(), .p2_retire(), .p2_retire2(), .p2_ipc0_o(), .p2_ipc_o()
);

///////////////////////   VIDEO   ///////////////////////

// The raster: 857 x 262 at 59.39 Hz, 640 x 240 shown (near MAME's set_ntsc(); rtl/m2_vtiming.sv)
wire        ce_pix, hblank, vblank, hsync, vsync;
m2_vtiming u_vtiming
(
	.clk(clk_sys), .rst(~pll_locked),
	.ce_pix(ce_pix), .hpos(hpos), .vpos(vpos), .hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync)
);

wire [23:0] rgb_game = vdu_on ? vdu_rgb : 24'h0;
wire [23:0] rgb;

// Evil Night's guns (rtl/m2_guns.sv); Button 1 the trigger, Button 2 the reload
wire [31:0] gun_joy [0:2] = '{joystick_0, joystick_1, joystick_2};
wire [15:0] gun_ana [0:2] = '{joystick_l_analog_0, joystick_l_analog_1, joystick_l_analog_2};
wire  [1:0] gun_mode [0:2] = '{status[36:35], status[38:37], status[40:39]};
wire  [2:0] gun_show = !gun_game ? 3'b000 : status[45:43] == 3'd1 ? 3'b001 : status[45:43] == 3'd2 ? 3'b010 : status[45:43] == 3'd3 ? 3'b100 :
                       status[45:43] == 3'd4 ? 3'b011 : status[45:43] == 3'd5 ? 3'b111 : 3'b000;
wire  [9:0] gun_x_o [0:2];
wire  [7:0] gun_y_o [0:2];
m2_guns u_guns
(
	.clk(clk_sys), .rst(core_rst | ~gun_game), .vblank(vblank),
	.joy(gun_joy), .ana(gun_ana), .mouse(ps2_mouse), .mode(gun_mode), .ms_who(status[42:41]), .off_fire(board[2]),
	.gun_x(gun_x_o), .gun_y(gun_y_o), .p5(gun_p5),
	.show(gun_show), .hpos(hpos), .vpos(vpos), .rgb_in(rgb_game), .rgb_out(rgb)
);
generate
	genvar g;
	for (g = 0; g < 3; g = g + 1)
	begin : gun_out
		assign gun_x[g] = gun_game ? gun_x_o[g] : 10'd0;
		assign gun_y[g] = gun_game ? gun_y_o[g] : 8'd0;
	end
endgenerate

wire        vga_de_mix;

arcade_video #(.WIDTH(640), .DW(24)) arcade_video
(
	.*,
	.clk_video(clk_sys),
	.ce_pix(ce_pix),
	.RGB_in(rgb),
	.HBlank(hblank),
	.VBlank(vblank),
	.HSync(hsync),
	.VSync(vsync),
	.fx(3'd0),
	.forced_scandoubler(1'b0),
	.VGA_DE(vga_de_mix)
);

video_freak video_freak
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),
	.VGA_DE_IN(vga_de_mix),
	.ARX(fs_int ? HDMI_WIDTH  : (ar == 2'd0) ? 12'd4 : {10'd0, ar - 2'd1}),
	.ARY(fs_int ? HDMI_HEIGHT : (ar == 2'd0) ? 12'd3 : 12'd0),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE(scale_sel)
);

///////////////////////   LED   ///////////////////////

assign LED_USER = core_rst;

endmodule
