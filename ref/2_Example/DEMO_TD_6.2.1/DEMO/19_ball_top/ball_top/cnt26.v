module cnt26(CLK,Q);

output [5:0] Q;
input CLK;
reg [5:0] Q;

always @(posedge CLK)
	Q <= Q+1;
endmodule
