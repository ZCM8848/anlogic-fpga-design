module TESTCTL(CLK, TSTEN, CLR_CNT, Load);
   input   CLK;
   output  TSTEN;
   output  CLR_CNT;
   reg     CLR_CNT;
   output  Load;
   reg     Div2CLK;
   
   always @(posedge CLK)
      
         Div2CLK <= (~Div2CLK);
   
   always @(CLK or Div2CLK)
      if (CLK == 1'b0 & Div2CLK == 1'b0)
         CLR_CNT <= 1'b1;
      else
         CLR_CNT <= 1'b0;
   assign Load = (~Div2CLK);
   assign TSTEN = Div2CLK;
   
endmodule 