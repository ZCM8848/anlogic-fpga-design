// Create Date: 2021/03/10 15:58:07
// Design Name: À¯œ‡ª∑≤‚ ‘
// Module Name: PLL_TEST
module PLL_TEST(
     input clk50mhz,
     input rst,
     output clk6mhz,
     output clk25mhz,
     output clk70mhz,
     output lock
    );
      PLL u1
   (
    // Clock out ports
    .clk0_out(clk6mhz),     // output clk_out1
    .clk1_out(clk25mhz),     // output clk_out2
    .clk2_out(clk70mhz),     // output clk_out3
    // Status and control signals
    .reset(~rst), // input reset
    .extlock(lock),       // output locked
   // Clock in ports
    .refclk(clk50mhz));      // input clk_in1
endmodule

