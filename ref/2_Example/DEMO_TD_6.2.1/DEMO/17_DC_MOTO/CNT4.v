module CNT4(CLK,Q);
input CLK;  //计数时钟
output [3:0] Q;  //计数结果输出
reg [3:0] Q1;
always @(posedge CLK )
  Q1 =Q1+1;
 assign Q = Q1;
endmodule
