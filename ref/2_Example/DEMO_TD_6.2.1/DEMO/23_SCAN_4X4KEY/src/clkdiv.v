module clkdiv(clkin,clk4k);  //分频器
input clkin;  //输入时钟频率50MHz
output clk4k; //4khz
reg clk4k;
reg [19:0]cnt1;

always@(posedge clkin)
  if(cnt1==62499)  //125000分频
    begin
      clk4k<=~clk4k;
      cnt1<=0;
    end 
  else   cnt1<=cnt1+1; 
   
endmodule
