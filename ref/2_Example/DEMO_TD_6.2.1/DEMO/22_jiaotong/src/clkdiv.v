module clkdiv(clkin,clk1KHz,clk10Hz,clk1Hz);  //分出3个频率的分频器
input clkin;  //输入时钟频率50MHz
output clk1KHz,clk10Hz,clk1Hz; //分频为1KHz、10Hz和1Hz
reg clk1KHz,clk10Hz,clk1Hz;
reg [15:0]cnt1;
reg [5:0]cnt2;
reg[2:0] cnt3;

always@(posedge clkin)
  if(cnt1==16'd24999)  //50000分频
    begin
      clk1KHz<=~clk1KHz;
      cnt1<=16'd0;
    end 
  else   cnt1<=cnt1+1'b1; 

always@(posedge clk1KHz)  //在分频1ms的时钟基础上再分频
  if(cnt2==6'd49)  //1000Hz分频分至10Hz
    begin
      clk10Hz<=~clk10Hz;
      cnt2<=6'd0;
    end 
  else  cnt2<=cnt2+1'b1;    

always@(posedge clk10Hz)//10Hz分频分至1Hz
  if(cnt3==3'd4) 
    begin
      clk1Hz<=~clk1Hz; cnt3<=3'd0;
    end
  else cnt3<=cnt3+1'b1; 
   
endmodule
