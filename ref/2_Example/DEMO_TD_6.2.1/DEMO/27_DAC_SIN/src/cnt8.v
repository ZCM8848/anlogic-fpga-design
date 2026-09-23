module cnt8
( input clk,
  output [8:0] cnt_out
);
reg [8:0] cnt_out_a;
always@(posedge clk)
 if (cnt_out_a < 9'b111111111)
   cnt_out_a= cnt_out_a + 1;
else cnt_out_a  = 9'b000000000;	
assign cnt_out = cnt_out_a;
endmodule 