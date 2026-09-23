module SCAN_4X4KEY(SCLK,HA,LB,dataout,en);
     input SCLK;
     input [3:0] HA;
     output [3:0] LB;
     output [6:0] dataout;
     output [7:0] en;
     wire [3:0] RR;
     wire clk4k;
     
     clkdiv u0(  //∑÷∆µ∆˜
     .clkin(SCLK),
     .clk4k(clk4k)
     );  
     
     K4X4 u1(     //æÿ’Ûº¸≈Ã…®√Ë≥Ã–Ú
     .CLK(clk4k),
     .A(HA),
     .B(LB),
     .R(RR)
     );
     
     DECL7S u2 (  //∂ØÃ¨…®√Ë“Î¬Î
     .A(RR),
     .LED7S(dataout),
     .B(en)
     );
 endmodule 