module SPKER (CLK, TN, SPKS);
		input CLK;
		input [10:0]	TN;
		output SPKS;
		reg SPKS;
		reg [10:0]	CNT11;
		always @(posedge CLK)//复位信号高电平有效
				begin	:	CNT11B_LOAD//11位可预置寄存器
						if (CNT11 == 11'h7FF)
								begin
										CNT11	= TN;
										SPKS <= 1'b1;
								end
						else
								begin
										CNT11 = CNT11 + 1;
										SPKS <= 1'b0;
								end
				end
endmodule 

/*仿真用代码
module SPKER (CLK, TN, SPKS,reset_n,CNT11);
		input CLK;
		input [10:0]	TN;
		input reset_n;
		output SPKS;
		output [10:0] CNT11;
		reg SPKS;
		reg [10:0]	CNT11;
		always @(posedge CLK or negedge reset_n)//复位信号高电平有效
				if(!reset_n)
						begin
								CNT11 <=	0;
								SPKS	<=	0;
						end
				else
						begin	:	CNT11B_LOAD//11位可预置寄存器
								if (CNT11 == 11'h7FF)
										begin
												CNT11	= TN;
												SPKS <= 1'b1;
										end
								else
										begin
												CNT11 = CNT11 + 1;
												SPKS <= 1'B0;
										end
						end
endmodule 
*/