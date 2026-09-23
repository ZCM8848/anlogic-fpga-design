module MUL8B (
	input clk,
	input reset_n,
	input mul1_key,
	input mul2_key,
	output wire [7:0] SEL,
	output wire [6:0] DIG
);

wire [7:0] mul1,mul2;//³Ë·¨ÖµÊä³ö
mul_con mul_num(
	.clk(clk),
	.reset_n(reset_n),
	.mul1_key(mul1_key),
	.mul2_key(mul2_key),
	.mul1(mul1),
	.mul2(mul2)
);

wire [15:0] result;
M8B m8b(
	.R(result),
	.A(mul1),
	.B(mul2)
);

LED7S_SCAN led7s(
	.bit_o(SEL),
	.seg_o(DIG),
	.clk(clk),
	.reset_n(reset_n),
	.mul1(mul1),
	.mul2(mul2),
	.result(result)
);

endmodule 