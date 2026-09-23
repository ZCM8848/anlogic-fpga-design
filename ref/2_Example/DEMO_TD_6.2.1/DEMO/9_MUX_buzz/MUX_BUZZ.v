module MUX_BUZZ (
	s1, s0,
	clk,
	buzz,
	reset_n
);
input s1,s0;
input clk;
input reset_n;
output buzz;
wire buzz;

wire a, b, c, d, s1, s0;

MUX41A  mux(
	.a(a),
	.b(b),
	.c(c),
	.d(d),
	.reset_n(reset_n),
	.s1(s1),
	.s0(s0),
	.y(buzz)
);
defparam bell_a.PreDiv=16'h5997;
bell bell_a(
	.clkin(clk),
	.buz(a),
	.reset_n(reset_n)
);

defparam bell_b.PreDiv=16'h4FCD;
bell bell_b(
	.clkin(clk),
	.buz(b),
	.reset_n(reset_n)
);

defparam bell_c.PreDiv=16'h471B;
bell bell_c(
	.clkin(clk),
	.buz(c),
	.reset_n(reset_n)
);

defparam bell_d.PreDiv=16'h431E;
bell bell_d(
	.clkin(clk),
	.buz(d),
	.reset_n(reset_n)
);
endmodule 