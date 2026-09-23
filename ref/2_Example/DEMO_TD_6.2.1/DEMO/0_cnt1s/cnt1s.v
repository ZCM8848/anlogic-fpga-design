module cnt1s(
input CLOCK,
input rst_n,
output reg [3:0] LED);
localparam T1S=27'd24999999;
//localparam T1S=27'd5;//ทยีๆ

reg [26:0] cnt_value;
 always @(posedge CLOCK or negedge rst_n)begin
if(!rst_n)
cnt_value<=0;
else if(cnt_value == T1S)
cnt_value<=0;
else
cnt_value <= cnt_value + 1'b1;
end
 always @(posedge CLOCK or negedge rst_n)begin
 if(!rst_n)
 LED<=4'HF;
 else if(cnt_value == T1S)
 LED <= ~LED;
 end
endmodule
