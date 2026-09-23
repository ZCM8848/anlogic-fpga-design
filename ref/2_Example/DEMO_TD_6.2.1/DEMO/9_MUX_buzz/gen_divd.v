module gen_divd(reset_n,clkin,clkout);
	input reset_n,clkin;
	output clkout;
	parameter divdWIDTH=1;
	parameter divdFACTOR=1;
	reg clkout;
	reg [divdWIDTH:0] cnt;
	
	
	always @ (negedge reset_n or posedge clkin)
		if(!reset_n)
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
