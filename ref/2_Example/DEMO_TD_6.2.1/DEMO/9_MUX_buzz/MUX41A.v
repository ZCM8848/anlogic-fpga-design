//仿真以及下载用的程序，加入了一个复位信号以及复位操作
module MUX41A(a,b,c,d,s1,s0,y,reset_n);
	input a,b,c,d;
	input reset_n;
	input s1,s0;
	output y;
	
	reg y;
	
	always @(a or b or c or d or s1 or s0 or reset_n)
		if (reset_n == 0)
			y <= 0;
		else
			begin	:	MUX41//block start
				case({s1,s0})
					2'b00 : y<=a;
					2'b01 : y<=b;
					2'b10 : y<=c;
					2'b11 : y<=d;
				endcase
			end
		
endmodule	