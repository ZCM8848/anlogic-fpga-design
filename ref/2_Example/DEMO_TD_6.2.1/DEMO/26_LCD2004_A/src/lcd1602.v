module lcd1602(sys_clk ,  
 sys_rstn ,
 lcd_rs ,
 lcd_rw ,
 lcd_en ,
 lcd_data
 );
//输入输出信号定义
input sys_clk ;//系统时钟输入
input sys_rstn ;//系统复位信号，低电平有效
output lcd_rs ;//lcd的寄存器选择输出信号
output lcd_rw ;//lcd的读、写操作选择输出信号
output lcd_en ;//lcd使能信号
output [7:0] lcd_data ;//lcd的数据总线(不进行读操作，故为输出)
//寄存器定义
reg lcd_rs ;
reg clk_div ;
reg [17:0] delay_cnt ;
reg [7:0] lcd_data ;
reg [5:0] char_cnt ; 
reg [7:0] data_disp ;
reg [12:0] state ; 
parameter idle = 13'b0000000000000, //初始状态，下一个状态为CLEAR
 clear = 13'b0000000000001, //清屏
 set_function = 13'b0000000000010, //功能设置:8位数据接口/2行显示/5*8点阵字符
 switch_mode = 13'b0000000000100, //显示开关控制:开显示，光标和闪烁关闭
 set_mode = 13'b0000000001000, //输入方式设置:数据读写操作后，地址自动加一/画面不动
 shift = 13'b0000000010000, //光标、画面位移设置:光标向左平移一个字符位(光标显示是关闭的，所以实际上设置是看不出效果的)
 set_ddram1 = 13'b0000000100000, //设置DDRAM的地址:第一行起始为0x00(注意输出时DB7一定要为1)
 set_ddram2 = 13'b0000001000000, //设置DDRAM的地址:第二行为0x40(注意输出时DB7一定要为1)
 set_ddram3 = 13'b0000010000000, //设置DDRAM的地址:第三行为0x14(注意输出时DB7一定要为1)
 set_ddram4 = 13'b0000100000000, //设置DDRAM的地址:第四行为0x54(注意输出时DB7一定要为1)
 write_ram1 = 13'b0001000000000, //数据写入DDRAM相应的地址
 write_ram2 = 13'b0010000000000, //数据写入DDRAM相应的地址
 write_ram3 = 13'b0100000000000, //数据写入DDRAM相应的地址 
 write_ram4 = 13'b1000000000000; //数据写入DDRAM相应的地址 
assign lcd_rw = 1'b0; //没有读操作，R/W信号始终为低电平
assign lcd_en = clk_div; //E信号出现高电平以及下降沿的时刻与LCD时钟相同
//时钟分频
always@(posedge sys_clk or negedge sys_rstn)
begin 
 if(!sys_rstn)
 begin
 delay_cnt<=18'd0;
 clk_div<=1'b0;
 end
 else if(delay_cnt==18'd249999)
 begin
 delay_cnt<=18'd0;
 clk_div<=~clk_div;
end
 else
 begin
 delay_cnt<=delay_cnt+1'b1;
 clk_div<=clk_div;
 end
end
always@(posedge clk_div or negedge sys_rstn) //State Machine 
begin
 if(!sys_rstn)
 begin
 state <= idle;
 lcd_data <= 8'b0;
 char_cnt <= 5'd0; 
 lcd_rs<=1'b0;
 end
 else
 begin
 case(state)
 idle: begin //初始状态
 state <= clear;
 lcd_data <= 8'b0;
 end
 clear: begin //清屏
 state <= set_function;
 lcd_rs<=1'b0;
 lcd_data <= 8'b00000001; 
 end 
 set_function: //功能设置(38H):8位数据接口/2行显示/5*8点阵字符
 begin
 state <= switch_mode;
 lcd_rs<=1'b0;
 lcd_data <= 8'b00111000; 
 end
 switch_mode: //显示开关控制(0CH):开显示，光标和闪烁关闭
 begin
 state <= set_mode;
 lcd_rs<=1'b0;
 lcd_data <= 8'b00001110;
 end 
 set_mode:begin //输入方式设置(06H):数据读写操作后，地址自动加一/画面不动
 state <= shift; 
 lcd_rs<=1'b0;
 lcd_data <= 8'b00000110;
 end
 shift: begin //光标、画面位移设置(10H):光标向左平移一个字符位(光标显示是关闭的，所以实际上设置是看不出效果的)
 state <= set_ddram1;
 lcd_rs<=1'b0;
 lcd_data <= 8'b0001_0000; 
 end 
 set_ddram1: //设置DDRAM的地址:第一行起始为00H(注意输出时DB7一定要为1) 
 begin
 state <= write_ram1; 
 lcd_rs<=1'b0;
 lcd_data <= 8'b1000_0011;//Line1
 end
 set_ddram2: //设置DDRAM的地址:第二行为40H(注意输出时DB7一定要为1)
 begin
 state <= write_ram2;
 lcd_rs<=1'b0;
 lcd_data <= 8'b1100_0001;//Line2 
 end
  set_ddram3: //设置DDRAM的地址:第三行起始为14H(注意输出时DB7一定要为1) 
 begin
 state <= write_ram3; 
 lcd_rs<=1'b0;
 lcd_data <= 8'b1001_0100;//Line3
 end
 set_ddram4: //设置DDRAM的地址:第三行起始为54H(注意输出时DB7一定要为1) 
 begin
 state <= write_ram4; 
 lcd_rs<=1'b0;
 lcd_data <= 8'b1101_0111;//Line4
 end
 write_ram1: 
 begin 
 if(char_cnt <=6'd10)
 begin
 char_cnt <= char_cnt + 1'b1; 
 lcd_rs<=1'b1;
 lcd_data <= data_disp;
 state <= write_ram1;
 end
 else
 begin
 state <= set_ddram2; 
 end 
 end
 write_ram2: 
 begin 
 if(char_cnt <=6'd30)
 begin
 char_cnt <= char_cnt + 1'b1; 
 lcd_rs<=1'b1;
 lcd_data <= data_disp;
 state <= write_ram2;
 end
 else
 begin
 state <= set_ddram3; 
 end 
 end
  write_ram3: 
 begin 
 if(char_cnt <=6'd50)
 begin
 char_cnt <= char_cnt + 1'b1; 
 lcd_rs<=1'b1;
 lcd_data <= data_disp;
 state <= write_ram3;
 end
 else
 begin
 state <= set_ddram4; 
 end 
 end
  write_ram4: 
 begin 
 if(char_cnt <=6'd51)
 begin
 char_cnt <= char_cnt + 1'b1; 
 lcd_rs<=1'b1;
 lcd_data <= data_disp;
 state <= write_ram4;
 end
 else
 begin
 char_cnt <=5'd0;
 state <= shift; 
 end 
 end
 default: state <= idle;
 endcase
 end
end
always @(char_cnt) //输出的字符
begin
 case (char_cnt)
 6'd0: data_disp = "W"; 
 6'd1: data_disp = "e"; 
 6'd2: data_disp = "l"; 
 6'd3: data_disp = "c"; 
 6'd4: data_disp = "o"; 
 6'd5: data_disp = "m"; 
 6'd6: data_disp = "e"; 
 6'd7: data_disp = " "; 
 6'd8: data_disp = "t"; 
 6'd9: data_disp = "o"; 
 6'd10: data_disp = " "; 
 6'd11: data_disp = "D"; 
 6'd12: data_disp = "i"; 
 6'd13: data_disp = "g"; 
 6'd14: data_disp = "i"; 
 6'd15: data_disp = "t"; 
 6'd16: data_disp = "a"; 
 6'd17: data_disp = "l"; 
 6'd18: data_disp = " "; 
 6'd19: data_disp = "c"; 
 6'd20: data_disp = "h"; 
 6'd21: data_disp = "i"; 
 6'd22: data_disp = "p"; 
 6'd23: data_disp = " "; 
 6'd24: data_disp = "d";
 6'd25: data_disp = "e";
 6'd26: data_disp = "s";
 6'd27: data_disp = "i";
 6'd28: data_disp = "g";
 6'd29: data_disp = "n";
 6'd30: data_disp = " ";
 6'd31: data_disp = "a";
 6'd32: data_disp = "n";
 6'd33: data_disp = "d";
 6'd34: data_disp = " ";
 6'd35: data_disp = "A";
 6'd36: data_disp = "p";
 6'd37: data_disp = "p";
 6'd38: data_disp = "l";
 6'd39: data_disp = "i";
 6'd40: data_disp = "c";
 6'd41: data_disp = "a";
 6'd42: data_disp = "t";
 6'd43: data_disp = "i";
 6'd44: data_disp = "o";
 6'd45: data_disp = "n";
 6'd46: data_disp = " ";
 6'd47: data_disp = "L";
 6'd48: data_disp = "a";
 6'd49: data_disp = "b";
 6'd50: data_disp = " ";
 6'd51: data_disp = " ";
 default : data_disp =" "; 
 endcase
end
endmodule
