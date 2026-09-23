// Create Date: 2021/03/18 16:25:53
// Design Name: PS2¼üÅÌµç×ÓÇÙ
// Module Name: ps2_piano
module ps2_piano(
	CLK,
	PS2DATA,
	PS2CLK,
	RST,
	SPK,
	code
);
input CLK;
input PS2CLK;
input PS2DATA;
input RST;
output SPK;
output [3:0] code;
wire [3:0] code;

wire c0;
clk_div clk_div_inst(.clk(CLK),.clk1mhz(c0));

wire [7:0] ps2DOUT;
PIANO piano(
	.reset(!RST),
	.clk(CLK),
	.ps2_clk(PS2CLK),
	.ps2_data(PS2DATA),
	.ps2_data1(ps2DOUT)
);

wire [3:0] key;
CODE3 code3 (
	.DIN(ps2DOUT),
	.KEY(key)
);

wire H;
wire [10:0] TO;
F_CODE f_code (
	.INX(key),
	.CODE(code),
	.H(H),
	.TO(TO)
);

wire SPKS;
SPKER spker(
	.CLK(c0),
	.TN(TO),
	.SPKS(SPKS)
);

wire Q;
DFF dff (
	.CLK(SPKS),
	.D(!Q),
	.Q(Q)
);
assign SPK = Q;
endmodule 
