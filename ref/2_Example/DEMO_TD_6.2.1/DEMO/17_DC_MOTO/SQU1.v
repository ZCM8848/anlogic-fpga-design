
module SQU1 (CIN, ADR, OT);
   input[7:0] CIN,ADR;   output OT; 
   reg OT;
   always @(CIN or ADR)   begin
      if (ADR < CIN)  OT <= 1'b0 ;
      else   OT <= 1'b1 ;  end 
endmodule
