module REG8B(Load, DIN, DOUT);
   input         Load;
   input [7:0]  DIN;
   output [7:0] DOUT;
   reg [7:0]    DOUT;
   
   always @(posedge Load)
      
         DOUT <= DIN;
   
endmodule
