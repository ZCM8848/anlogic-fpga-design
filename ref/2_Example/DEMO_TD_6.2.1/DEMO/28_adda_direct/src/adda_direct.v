// Create Date: 2021/03/18 10:28:48
// Design Name: adda??
// Module Name: adda_direct
module adda_direct( clk_50m,reset_n,ad_dat,da_dat,da_clk,ad_clk,clk_out,lock	
                   );
	input 			clk_50m;
	input 			reset_n;
	input [11:0]	ad_dat;
	output 			da_clk;
	output 			ad_clk;
//	input        CLK_1k; 
	output       clk_out;
	output[11:0]	da_dat;
    
    output        lock;
    
	reg	[11:0]	da_dat;
	wire 				clk_50m;
assign da_clk = ~clk_50m;
assign ad_clk = ~clk_50m;


always @ (posedge clk_50m or negedge reset_n)
begin
	if(!reset_n)
	begin
		da_dat <= 12'b0;
	end
	else
		da_dat <= ad_dat;
end

PLL25 U1(
  .refclk(clk_50m),
  .reset(reset),
  .extlock(lock),
  .clk0_out(clk_out) 
);


endmodule
