// Create Date: 2021/03/04 09:36:28
// Design Name: 10进制频率计
// Module Name: FREQTEST
module FREQTEST( 
 input clk,
 input FSIN,
 output  cout,
 output  [31:0] dout
);
//wire clk1hz;
wire load;
wire clk_en;
wire clr_cnt;
wire [31:0] din;
wire [31:0] dout_n;

TESTCTL u2(
.CLK(clk),
.TSTEN(clk_en), 
.CLR_CNT(clr_cnt),
 .Load(load));
 
CNT u3 (
  .CLK(FSIN),       
  .EN(clk_en),          
  .CLR(clr_cnt),       
  .COUT(cout),  
  .DIN(din)              
);
REG8B u4(
 .Load(load),
 .DIN(din), 
 .DOUT(dout_n)); 
 
cnt10b u5(
 .DIN(dout_n), 
 .DOUT(dout));
 endmodule