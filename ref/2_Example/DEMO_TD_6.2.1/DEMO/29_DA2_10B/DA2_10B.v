// Create Date: 2021/03/18 12:59:22
// Design Name: 双通道10bitDA（jp1）
// Module Name: DA2_10B
module DA2_10B( input clk50mhz,output da1_clk,output da2_clk,
                output [9:0] da1_dat,output [9:0] da2_dat
                );
                
      wire  [8:0] address;
      wire clk5;  
      wire locked; 
   clock_50 clock_50_name
   (
    // Clock out ports
    .clk0_out(da1_clk),     // output clk_out1
    .clk1_out(da2_clk),     // output clk_out2
    .clk2_out(clk5),     // output clk_out3
    // Status and control signals
    .reset(1'b0), // input reset
    .extlock(locked),       // output locked
   // Clock in ports
    .refclk(clk50mhz));      // input clk_in1    
        
     count9b count9b_name( .clk(clk5), .q(address));    
            
            
   da1_sina da1_sinaour_instance_name (
  .clka(clk5),    // input wire clka
  .addra(address),  // input wire [8 : 0] addra
  .doa(da1_dat)  // output wire [9 : 0] douta
);


    
da2_sawtooth da2_sawtooth_name (
  .clka(clk5),    // input wire clka
  .addra(address),  // input wire [8 : 0] addra
  .doa(da2_dat)  // output wire [9 : 0] douta
);  
endmodule
