// Create Date: 2021/03/10 14:50:03
// Design Name: 按键消抖动实验
// Module Name: DI_TRemble
module DI_TRemble( input pclk,input s,
output [7:0] EN,input clk50mhz,output [6:0] LED7S
 );
 wire y2;
 wire y1;
 wire kout;
 wire [7:0] q1,q2;
 wire [7:0] B;
 wire clk1khz;
 clkdiv u1(.clkin(clk50mhz),.clk1KHz(clk1khz));  //消抖动工作时钟
 
 MUX21B  u2(.A(pclk),.S(s),.Y1(y1),.Y2(y2));   //是否消抖选择
 
 ERZP  u3(.CLK(clk1khz),.KIN(y2),.KOUT(kout)); //消抖动模块
 
 cnt8 u4 (                       //8位计数器
  .CLK(y1),  // input wire CLK
  .Q(q1)      // output wire [7 : 0] Q
);
cnt8 u5 (               //8位计数器
  .CLK(kout),  // input wire CLK
  .Q(q2)      // output wire [7 : 0] Q
);
MUX21a u6(.A(q1),.B(q2),.S(s),.Y(B));  //二选一计数输出
sm_scnt u7(
	.clk(clk50mhz),
	.rst(1'b1),
	.datain(B),
	.dataout(LED7S),
	.en(EN)
	);
endmodule
