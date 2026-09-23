module count(CLK,Q);

output [23:0] Q;
input CLK;
reg [23:0] Q;

always @(posedge CLK)
	Q <= Q+1;
endmodule
