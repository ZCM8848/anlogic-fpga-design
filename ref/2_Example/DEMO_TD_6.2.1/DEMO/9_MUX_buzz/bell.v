module bell 
(
	input clkin,
	input reset_n,
	output reg buz
);
	parameter PreDiv =16'h1;
	wire ClkBell;
	defparam Gen_ClkBell.divdWIDTH=2,Gen_ClkBell.divdFACTOR=2;//4分频
	gen_divd Gen_ClkBell(.reset_n(reset_n), .clkin(clkin), .clkout(ClkBell));	

	//reg [15:0] PreDiv;//分频系数
	reg [15:0] Cnt;
	
	always @ (posedge ClkBell or negedge reset_n)
		if (!reset_n)
			begin
				Cnt <= 0;
				buz <= 0;
			end
		else
			begin
				Cnt <= Cnt + 1'b1;
				if (Cnt >= PreDiv)
					begin
						Cnt <= 0;
						buz <= ~buz;
					end
			end 
endmodule 