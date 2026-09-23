module top(clk,
			  reset_n,
			  tft_wrx,
			  tft_rdx,
			  tft_csx,
			  tft_dcx,
			  tft_reset_n,
			  tft_d_inout,
			  tft_bl,
           SEL,
   	     DIG);



	input clk,reset_n;
	output tft_wrx,tft_dcx,tft_rdx,tft_csx;
	output  tft_bl;
	inout[15:0]tft_d_inout;
	output  tft_reset_n;
   output 		   [7:0]       SEL;
   output 		   [7:0]     	DIG;
	
	
	
	
 LCD_On_FPGA u22  (
						.clk(clk),
						.reset_n(reset_n),
						.tft_wrx(tft_wrx),
						.tft_rdx(tft_rdx),
						.tft_csx(tft_csx),
						.tft_dcx(tft_dcx),
						.tft_reset_n(tft_reset_n),
						.tft_d_inout(tft_d_inout),
						.tft_bl(tft_bl),
                  .SEL(SEL),
   	            .DIG(DIG)
);





endmodule
