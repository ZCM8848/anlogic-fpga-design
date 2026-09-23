module CNT( CLK,EN ,CLR ,COUT ,DIN 

   );
 input CLK, EN;
 input CLR;
 output reg [31:0] DIN;
 output  reg COUT;
 always@(posedge CLK or posedge CLR)
 begin 
  if(CLR) DIN <= 32'h0;
  else if (EN) begin 
    if (DIN<32'hFFFFFFFF)
          DIN <= DIN + 1;
     else DIN <= 32'h0 ;end
 end
 always @(COUT)
 if (DIN==32'HFFFFFFFF) COUT = 1'b1; else COUT = 1'b0; 
endmodule
