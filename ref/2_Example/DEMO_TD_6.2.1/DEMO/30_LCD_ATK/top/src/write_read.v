/*8080接口时序 DC为低电平写的为地址DC为高电平写的为数据
传送数据时CS = 0；数据传送模式为并行传送，先准备好数据在
WR的上升沿时数据传送

WR写周期最快66ns


*/

module write_read(
				clk,
				rstn,
				wrx,
				rdx,
				csx,
				dcx,
				write_d,
				read_d,
				write_done_sig,
				read_done_sig,
				write_data,
				read_data,
				wr_rd_sig,
				sig,
				write_read_stop
				);
				
	input 			clk,rstn;
	output 			wrx,dcx,rdx,csx;
	output[15:0]	write_d;    //管脚输出数据
	input [15:0]   read_d;    //管脚输入数据
	output 			write_done_sig,read_done_sig;//判断一次数据是否传送完毕
	input[15:0]		write_data;//需要传送的数据
	output [15:0] read_data;
	input[1:0]		sig;//sig=2'b10传送的为地址命令 sig=2’b01传送为为数据
   input wr_rd_sig;//wr_rd_sig=1 写 wr_rd_sig=0 读 
	input write_read_stop;  //write_read_stop=1 停止读写
	
	
	
	reg 			wr,dc,cs,rd;
	reg[15:0]		write_d_r;
	reg[15:0]		read_d_r;
	reg 			write_done_r;
	reg 			read_done_r;


	/*********************************************************************/
	reg[4:0]		state;

	always@(posedge clk or negedge rstn)
	if(!rstn)
	begin 
		wr <= 1'b1;rd <= 1'b1;cs <= 1'b1;dc <= 1'b1;state <= 5'd0;write_d_r <= 16'd0;read_d_r <= 16'd0;
		write_done_r <= 1'b0; read_done_r <= 1'b0;
	end
	else
	if(~write_read_stop)begin
			if(wr_rd_sig)begin   //写
				case(state)
					0:state <= state + 1'b1;//不能少 用于等待sig信号
					1:begin
						if( sig == 2'b10 )// dc = 0
						begin 
							cs <= 1'b0;
							dc <= 1'b0;
							rd <= 1'b1;
							write_d_r <= write_data;//准备好数据
							state <= state + 1'b1;
							wr <= 1'b0;
						end
						else if( sig == 2'b01 )
						begin 
							cs <= 1'b0;
							dc <= 1'b1;
							rd <= 1'b1;
							write_d_r <= write_data;//准备好数据
							state <= state + 1'b1;
							wr <= 1'b0;
						end
						else 
							state <= state;
					
					end
					//写的时候cs=0 到 wr=1 要25ns
					2:begin state <= state + 1'b1; end
					3:begin state <= state + 1'b1; end
					//wr由0变为1时把数据并行送出
					4:begin wr <= 1'b1;write_done_r <= 1'b1;state <= state + 1'b1;end
					5:begin cs <= 1'b1;dc <= 1'b1;write_done_r <= 1'b0;state <= 5'd0;end
					default state <= 5'd0;
				endcase
			end 
			else if(~wr_rd_sig)begin          //读
			
			//周期最少450ns,因为读显存最少450ns，即两次拉低rd至少间隔450ns
			//cs=0 到 rd=1之间最少355ns   rd保持高电平至少90ns   rd低电平至少355ns
			
				case(state)
					0:state <= state + 1'b1;//不能少 用于等待sig信号
					1:begin
						if( sig == 2'b10 )// dc = 0
						begin 
							cs <= 1'b0;
							dc <= 1'b0;
							rd <= 1'b0;
							state <= state + 1'b1;
							wr <= 1'b1;
						end
						else if( sig == 2'b01 )
						begin 
							cs <= 1'b0;
							dc <= 1'b1;
							rd <= 1'b0;
							state <= state + 1'b1;
							wr <= 1'b1;
						end
						else 
							state <= state;
					
					end
					
					
					//空跑18个state即360ns  建立时间最少355ns  满足保持rd=0至少355ns 
					2:begin state <= state + 1'b1; end
					3:begin state <= state + 1'b1; end
					4:begin state <= state + 1'b1; end
					5:begin state <= state + 1'b1; end
					6:begin state <= state + 1'b1; end
					7:begin state <= state + 1'b1; end
					8:begin state <= state + 1'b1; end
					9:begin state <= state + 1'b1; end
					10:begin state <= state + 1'b1; end
					11:begin state <= state + 1'b1; end
					12:begin state <= state + 1'b1; end
					13:begin state <= state + 1'b1; end
					14:begin state <= state + 1'b1; end
					15:begin state <= state + 1'b1; end
					16:begin state <= state + 1'b1; end
					17:begin state <= state + 1'b1; end
					18:begin state <= state + 1'b1; end
					19:begin state <= state + 1'b1; end
					20:begin state <= state + 1'b1; end
					
					//将数据读入
					21:begin state <= state + 1'b1; read_d_r <= read_d; end
					//rd由0变为1
					22: begin rd <= 1'b1;state <= state + 1'b1; end
				   
					//空跑5个state即60ns   保持rd=1至少90ns
					23:begin state <= state + 1'b1;  end
					24:begin state <= state + 1'b1;  end
					25:begin state <= state + 1'b1;  end
					26:begin state <= state + 1'b1;  end
					//
					27:begin state <= state + 1'b1; read_done_r <= 1'b1; end
					//重置信号   cs拉高后10ns，wr和rd信号才能拉低
					28:begin cs <= 1'b1;dc <= 1'b1;read_done_r <= 1'b0;state <= 5'd0; end
					default state <= 5'd0;
				endcase
			
			
			end

    end

	
	
	
	
	
	
	assign write_done_sig = write_done_r;
	assign read_done_sig = read_done_r;
	assign write_d = write_d_r;   //输出写的数据
	assign read_data = read_d_r; //输出读到数据
	assign wrx = wr;
	assign rdx = rd;
	assign dcx = dc;
	assign csx = cs;

endmodule
