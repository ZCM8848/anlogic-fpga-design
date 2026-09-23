module clkdiv(clkin,clk1MHz,clk4KHz,clk8Hz); 
input clkin; 
output clk1MHz,clk4KHz,clk8Hz; 
reg clk1MHz,clk4KHz,clk8Hz;
reg [4:0]cnt1;
reg [6:0]cnt2;
reg[8:0] cnt3;

always@(posedge clkin)
  if(cnt1==24)  //50·ÖÆµ
    begin
      clk1MHz<=~clk1MHz;
      cnt1<=0;
    end 
  else   cnt1<=cnt1+1; 

always@(posedge clk1MHz) 
  if(cnt2==124)  
    begin
      clk4KHz<=~clk4KHz;
      cnt2<=0;
    end 
  else  cnt2<=cnt2+1;    

always@(posedge clk4KHz)
  if(cnt3==249) 
    begin
      clk8Hz<=~clk8Hz; cnt3<=0;
    end
  else cnt3<=cnt3+1;    
endmodule
