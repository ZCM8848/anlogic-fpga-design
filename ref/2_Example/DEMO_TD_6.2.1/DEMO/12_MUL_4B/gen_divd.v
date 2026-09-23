module gen_divd(reset,clkin,clkout);
	input reset,clkin;
	output clkout;
	parameter divdWIDTH=1;
	parameter divdFACTOR=1;
	reg clkout;
	reg [divdWIDTH:0] cnt;
	
	
	always @ (posedge reset or posedge clkin)
		if(reset)
			begin
			cnt<=0;
			clkout<=0;
			end
		else
			begin
			cnt<=cnt+1'b1;
			if(cnt==(divdFACTOR-1))
				begin
				cnt<=0;
				clkout<=~clkout;
				end 
			end
endmodule