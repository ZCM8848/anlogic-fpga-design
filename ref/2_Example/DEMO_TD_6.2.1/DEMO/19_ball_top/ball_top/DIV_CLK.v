module DIV_CLK(clkin,clk1MHz,clk1KHz);  //分出3个频率的分频器
input clkin;  //输入时钟频率50MHz
output clk1MHz,clk1KHz; 
reg clk1MHz,clk1KHz;

reg [4:0]cnt2;
reg[8:0] cnt3;

always@(posedge clkin)  
  if(cnt2==24)  
    begin
      clk1MHz<=~clk1MHz;
      cnt2<=0;
    end 
  else  cnt2<=cnt2+1;    

always@(posedge clk1MHz)
  if(cnt3==249) 
    begin
      clk1KHz<=~clk1KHz; cnt3<=0;
    end
  else cnt3<=cnt3+1; 
   
endmodule
