// Create Date: 2021/03/17 15:02:36
// Design Name: 12λDAC(JP6)
// Module Name: DAC_SIN_12B
module DAC_SIN_12B( input clk50mhz,output da_clk,
                           output [11:0] da_data
                  );
                  wire locked;
                  wire clk5;
                  wire [8:0] cnt_out; 
  
PLL u1(
        .clk0_out(da_clk), //output clkout
        .extlock(locked), //output lock
        .reset(1'B0),
        .clk1_out(clk5), //output clkoutd
        .refclk(clk50mhz) //input clkin
    );

    cnt8 u2
      (.clk(clk5),
       .cnt_out(cnt_out)
      );
    

ROM u3(
        .doa(da_data), //output [11:0] dout
        .clka(clk5), //input clk
        .ocea(1'b1), //input oce
       // .ce(1'b1), //input ce
        .rsta(1'b0), //input reset
        .addra(cnt_out) //input [8:0] ad
    );



endmodule
