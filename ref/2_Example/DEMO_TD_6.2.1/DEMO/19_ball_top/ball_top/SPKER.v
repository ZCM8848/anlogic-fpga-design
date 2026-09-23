module SPKER (CLK, TN, FOUT);
  input CLK;
  input[10:0] TN;
  output reg FOUT;
  reg CNT2;
  reg SPKS;
    reg[10:0] CNT11;
  always @ (posedge CLK)  begin : CNT11B_LOAD
      if (CNT11==11'h7FF) begin CNT11=TN;
        SPKS<=1'b1;  end
        else begin  CNT11=CNT11+1; SPKS<=1'b0;
        end 
  end
  always@(posedge SPKS)
    begin CNT2=~CNT2;
    if(CNT2==1'b1) 
    FOUT<=1'b1;
    else FOUT<=1'b0;
    end
       
endmodule 
