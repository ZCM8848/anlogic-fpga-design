// Copyright (C) 2017  Intel Corporation. All rights reserved.
// Your use of Intel Corporation's design tools, logic functions 
// and other software and tools, and its AMPP partner logic 
// functions, and any output files from any of the foregoing 
// (including device programming or simulation files), and any 
// associated documentation or information are expressly subject 
// to the terms and conditions of the Intel Program License 
// Subscription Agreement, the Intel Quartus Prime License Agreement,
// the Intel FPGA IP License Agreement, or other applicable license
// agreement, including, without limitation, that your use is for
// the sole purpose of programming logic devices manufactured by
// Intel and sold by Intel or its authorized distributors.  Please
// refer to the applicable agreement for further details.

// PROGRAM		"Quartus Prime"
// VERSION		"Version 17.1.0 Build 590 10/25/2017 SJ Standard Edition"
// CREATED		"Mon Jul 24 14:11:41 2023"

module Block1(
	CLK,
	ps2clk,
	ps2date,
	rst,
	HS,
	VS,
	R,
	G,
	B
);


input wire	CLK;
input wire	ps2clk;
input wire	ps2date;
input wire	rst;
output wire	HS;
output wire	VS;
output wire	R;
output wire	G;
output wire	B;

wire	SYNTHESIZED_WIRE_7;
wire	[7:0] SYNTHESIZED_WIRE_1;
wire	[7:0] SYNTHESIZED_WIRE_2;
wire	SYNTHESIZED_WIRE_4;
wire	SYNTHESIZED_WIRE_5;
wire	[9:0] SYNTHESIZED_WIRE_6;





VGA	b2v_inst(
	.CLK(SYNTHESIZED_WIRE_7),
	.rst(rst),
	.date(SYNTHESIZED_WIRE_1),
	.key_signal(SYNTHESIZED_WIRE_2),
	.HS(HS),
	.VS(VS),
	.R(R),
	.G(G),
	.B(B),
	.ting_flag(SYNTHESIZED_WIRE_4),
	.add(SYNTHESIZED_WIRE_6));


key	b2v_inst1(
	.sysclk(SYNTHESIZED_WIRE_7),
	.ps2k_clk(ps2clk),
	.ps2k_data(ps2date),
	.ting_flag(SYNTHESIZED_WIRE_4),
	.ps2_out(SYNTHESIZED_WIRE_2));

ROM b2v_inst2(
        .doa(SYNTHESIZED_WIRE_1), //output [7:0] dout
        .clka(SYNTHESIZED_WIRE_5), //input clk
        .ocea(1'b1), //input oce
    //    .ce(1'b1), //input ce
        .rsta(1'b0), //input reset
        .addra(SYNTHESIZED_WIRE_6) //input [9:0] ad
    );
    

PLL b2v_inst3(
        .clk0_out(SYNTHESIZED_WIRE_7), //output clkout
        .clk1_out(SYNTHESIZED_WIRE_5), //output clkout
        .reset(1'B0),
        .refclk(CLK) //input clkin
    );



endmodule
