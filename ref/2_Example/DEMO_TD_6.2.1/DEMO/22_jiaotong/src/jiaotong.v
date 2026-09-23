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
// CREATED		"Thu Jul 20 15:42:02 2023"

module jiaotong(
	clk,
	NR,
	NY,
	NG,
	SR,
	SY,
	WR,
	WY,
	WG,
	ER,
	EY,
	EG,
	SG
);


input wire	clk;
output wire	NR;
output wire	NY;
output wire	NG;
output wire	SR;
output wire	SY;
output wire	WR;
output wire	WY;
output wire	WG;
output wire	ER;
output wire	EY;
output wire	EG;
output wire	SG;

wire	SYNTHESIZED_WIRE_0;
wire	SYNTHESIZED_WIRE_1;
wire	SYNTHESIZED_WIRE_2;
wire	SYNTHESIZED_WIRE_3;
wire	SYNTHESIZED_WIRE_4;
wire	SYNTHESIZED_WIRE_5;
wire	SYNTHESIZED_WIRE_6;
wire	SYNTHESIZED_WIRE_7;
wire	SYNTHESIZED_WIRE_8;
wire	SYNTHESIZED_WIRE_9;
wire	SYNTHESIZED_WIRE_10;
wire	SYNTHESIZED_WIRE_11;
wire	SYNTHESIZED_WIRE_12;

assign	NR = SYNTHESIZED_WIRE_7;
assign	NY = SYNTHESIZED_WIRE_8;
assign	NG = SYNTHESIZED_WIRE_12;
assign	SR = SYNTHESIZED_WIRE_7;
assign	SY = SYNTHESIZED_WIRE_8;
assign	WR = SYNTHESIZED_WIRE_9;
assign	WY = SYNTHESIZED_WIRE_10;
assign	WG = SYNTHESIZED_WIRE_11;
assign	ER = SYNTHESIZED_WIRE_9;
assign	EY = SYNTHESIZED_WIRE_10;
assign	EG = SYNTHESIZED_WIRE_11;
assign	SG = SYNTHESIZED_WIRE_12;




traffic	b2v_inst(
	.clk(SYNTHESIZED_WIRE_0),
	.r1(SYNTHESIZED_WIRE_1),
	.y1(SYNTHESIZED_WIRE_2),
	.g1(SYNTHESIZED_WIRE_3),
	.r2(SYNTHESIZED_WIRE_4),
	.y2(SYNTHESIZED_WIRE_5),
	.g2(SYNTHESIZED_WIRE_6));

assign	SYNTHESIZED_WIRE_7 =  ~SYNTHESIZED_WIRE_1;

assign	SYNTHESIZED_WIRE_8 =  ~SYNTHESIZED_WIRE_2;

assign	SYNTHESIZED_WIRE_12 =  ~SYNTHESIZED_WIRE_3;

assign	SYNTHESIZED_WIRE_9 =  ~SYNTHESIZED_WIRE_4;

assign	SYNTHESIZED_WIRE_10 =  ~SYNTHESIZED_WIRE_5;

assign	SYNTHESIZED_WIRE_11 =  ~SYNTHESIZED_WIRE_6;


clkdiv	b2v_inst7(
	.clkin(clk),
	
	
	.clk1Hz(SYNTHESIZED_WIRE_0));


endmodule
