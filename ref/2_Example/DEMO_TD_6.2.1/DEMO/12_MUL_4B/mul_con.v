module mul_con(
	input clk,
	input reset_n,
	input mul1_key,
	input mul2_key,
	output reg [7:0] mul1,
	output reg [7:0] mul2
);

	reg [7:0] mul1_buf, mul2_buf;
	
	always @ (negedge mul1_key or negedge reset_n)
		if(!reset_n)
			begin
				mul1_buf <= 0;
			end
		else if (!mul1_key)
			mul1_buf <= mul1_buf + 1'b1;
			
	always @ (negedge mul2_key or negedge reset_n)
		if(!reset_n)
			begin
				mul2_buf <= 0;
			end
		else if (!mul2_key)
			mul2_buf <= mul2_buf + 1'b1;
			
	always @(mul1_buf or mul2_buf)
		begin
			mul1 <= mul1_buf;
			mul2 <= mul2_buf;
		end
endmodule 