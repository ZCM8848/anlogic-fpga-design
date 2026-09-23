module LED7S_SCAN(
	bit_o,
	seg_o,
	clk,
	reset_n,
	mul1,
	mul2,
	result
);
	input reset_n;
	input clk;
	input [7:0] mul1, mul2;
	input [15:0] result;
	output [7:0] bit_o;	//位码输出
	output [6:0] seg_o;	//解码后的7位段码输出
	
	reg [7:0] bit_o;
	reg [6:0] seg_o;
	
	reg [7:0] seg_o_buf; //8位位码暂存

	wire clk50hz;//实验用分频
	defparam div_clk.divdFACTOR = 50000,div_clk.divdWIDTH = 19;
	gen_divd div_clk(.reset(!reset_n),.clkin(clk),.clkout(clk50hz));

/*仿真用分频
	wire clk50hz;
	defparam div_clk.divdFACTOR = 5,div_clk.divdWIDTH = 19;
	gen_divd div_clk(.reset(!reset_n),.clkin(clk),.clkout(clk50hz));
*/

	always @ (seg_o_buf)	//解码ok
		case (seg_o_buf)
				8'b0000_0000	:	seg_o	<=	7'b1000_000;//7'b0111_111;注释掉的为高电平驱动，从右到左分别为a-g段
				8'b0000_0001	:	seg_o	<=	7'b1111_001;//7'b0000_110;
				8'b0000_0010	:	seg_o	<=	7'b0100_100;//7'b1011_011;
				8'b0000_0011	:	seg_o	<=	7'b0110_000;//7'b1001_111;
				8'b0000_0100	:	seg_o	<=	7'b0011_001;//7'b1100_110;
				8'b0000_0101	:	seg_o	<=	7'b0010_010;//7'b1101_101;
				8'b0000_0110	:	seg_o	<=   7'b0000_010;//7'b1111_101;
				8'b0000_0111	:	seg_o	<=	7'b1111_000;//7'b0000_111;
				8'b0000_1000	:	seg_o	<=	7'b0000_000;//7'b1111_111;
				8'b0000_1001	:	seg_o	<=	7'b0010_000;//7'b1101_111;
				8'b0000_1010	:	seg_o	<=	7'b0001_000;//7'b1110_111;
				8'b0000_1011	:	seg_o	<=	7'b0000_011;//7'b1111_100;
				8'b0000_1100	:	seg_o	<=	7'b1000_110;//7'b0111_001;
				8'b0000_1101	:	seg_o	<=	7'b0100_001;//7'b1011_110;
				8'b0000_1110	:	seg_o	<=	7'b0000_110;//7'b1111_001;
				8'b0000_1111	:	seg_o	<=	7'b0001_110;//7'b1110_001;
				default	:	seg_o	<=	7'b1111_111;//全灭
		endcase
	
	reg [7:0] mul1_buf, mul2_buf;
	always @(mul1 or mul2)
		begin
			mul1_buf <= mul1;		
			mul2_buf <= mul2;
		end
	always @ (bit_o)
		begin
			case (bit_o)
				8'b1111_1110 :	seg_o_buf <= mul1_buf;
				8'b1111_1101 :	seg_o_buf <= 8'b1111_1111;
				8'b1111_1011 :	seg_o_buf <= mul2_buf;
				8'b1111_0111 :	seg_o_buf <= 8'b1111_1111;
				8'b1110_1111 :	seg_o_buf <= 8'b1111_1111;
				8'b1101_1111 :	seg_o_buf <= 8'b1111_1111;		
				8'b1011_1111 :	seg_o_buf <={4'b0000,result[3:0]};				
				8'b0111_1111 :	seg_o_buf <={4'b0000,result[7:4]};				
				default : seg_o_buf <= 0;
			endcase
		end
		
	integer i;
	always @ (posedge clk50hz or negedge reset_n)		//扫描ok
		if (!reset_n)
			begin
				bit_o <= 8'b0111_1111;	//位初始化亮最左边
			end
		else													//循环右移
			begin
				for(i=7;i>0;i=i-1)
					begin
						bit_o[i-1]<=bit_o[i];
						bit_o[7]<=bit_o[0];
					end
			end
					
endmodule 
