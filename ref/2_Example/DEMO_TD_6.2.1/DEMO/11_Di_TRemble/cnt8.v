module cnt8(CLK,Q);

input CLK;  

output [7:0] Q;  
reg [7:0] Q1;

always @(posedge CLK)
   
 Q1 <= Q1+1;
 assign Q = Q1;

endmodule
