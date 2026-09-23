module clkdiv(clkin,clk1KHz);  //分频器
input clkin;  //输入时钟频率50MHz
output clk1KHz; //分频为1KHz
reg clk1KHz;
reg [15:0]cnt1;

always@(posedge clkin)
  if(cnt1==24999)  //50000分频
    begin
      clk1KHz<=~clk1KHz;
      cnt1<=0;
    end 
  else   cnt1<=cnt1+1; 
endmodule
