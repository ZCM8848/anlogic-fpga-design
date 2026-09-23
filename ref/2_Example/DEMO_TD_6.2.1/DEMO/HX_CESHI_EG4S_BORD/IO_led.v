module IO_led(clk50,k1,P1IO,P3IO);
      input        clk50;  
		input           k1;
		output reg [35:0] P1IO; 
		output reg [35:0] P3IO;

		wire clk;
		ERZP ERZP_inst
(
	.CLK(clk50) ,	// input  CLK_sig
	.KIN(k1) ,	// input  KIN_sig
	.KOUT(clk) 	// output  KOUT_sig
);
  always@(posedge clk)
	  P1IO = ~P1IO;
	always@(posedge clk)
	  P3IO = ~P3IO;

endmodule 