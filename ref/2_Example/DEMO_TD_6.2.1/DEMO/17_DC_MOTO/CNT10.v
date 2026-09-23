module CNT10(clk,rst,en,count,dout );
 input clk;
 input rst;
 input en;
 output reg count;
 output [3:0] dout;
 reg [3:0] q1;
 assign dout = q1 ;
 always@(posedge clk or negedge rst)
   begin 
    if (!rst) q1 <= 0;
   else if (en) begin 
    if(q1<9) 
    q1 <= q1+1;end
    else 
    q1 <= 4'b0000;end
    always@(q1)
    if(q1==4'h9) count = 1'b1; else count = 1'b0;  
endmodule
