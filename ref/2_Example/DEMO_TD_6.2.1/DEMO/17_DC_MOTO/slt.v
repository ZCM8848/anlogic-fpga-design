module SLT(SL, M, M0, M1);
   input   SL;
   input   M;
   output reg  M0;
   output  reg  M1;
   
   always @(SL or M)
         if (SL == 1'b1)
           begin  M0 <= M;
         M1 <= 1'b0;
      end
      else begin
         M0 <= 1'b0;
         M1 <= M;end
endmodule
