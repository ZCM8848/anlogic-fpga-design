module DFF(
	CLK,
	D,
	Q
);
	input CLK;
	input D;
	output Q;
	reg Q;
	always @(posedge CLK)
		Q <= D;
endmodule