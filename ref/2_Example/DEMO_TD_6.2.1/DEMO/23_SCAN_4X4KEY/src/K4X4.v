module K4X4 (CLK,A,B,R);
  
 input CLK;
 input [3:0] A;
 output [3:0] B;
output [3:0] R;
      reg [1:0] C ;       reg [3:0] R,B ;  
     always @ (posedge CLK) begin
       C<=C+1;
        case(C)
      0: B=4'B0111; 1: B=4'B1011; 2: B=4'B1101; 3: B=4'B1110;
        endcase 
        case({B,A} ) 
      8'B0111_1110 : R=4'H0;   8'B0111_1101 : R=4'H1;
      8'B0111_1011 : R=4'H2;   8'B0111_0111 : R=4'H3;
      8'B1110_1110 : R=4'H4;   8'B1110_1101 : R=4'H5;
      8'B1110_1011 : R=4'H6;   8'B1110_0111 : R=4'H7;
      8'B1101_1110 : R=4'H8;   8'B1101_1101 : R=4'H9;
      8'B1101_1011 : R=4'HA;   8'B1101_0111 : R=4'HB;
    	8'B1011_1110 : R=4'HC;   8'B1011_1101 : R=4'HD;
      8'B1011_1011 : R=4'HE;   8'B1011_0111 : R=4'HF;
   endcase   end   endmodule
