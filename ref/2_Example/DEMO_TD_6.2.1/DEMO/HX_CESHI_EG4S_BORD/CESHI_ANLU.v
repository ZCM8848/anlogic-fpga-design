module CESHI_ANLU( input clk50mhz,
  //                  output [3:0] LED,
 //                   output high,
                    output spk,
  //                  input rst,
//----------------------静态数码管实验-------------//
    //                input sys_clk, 
     //               input sys_rst_n,      
                    output    [7:0]     seg_sel,
                    output    [7:0]     seg_led,
//--------------------按键测试LED-----------//
                    input        [7:0]  key,

                    output       [3:0]  lcd,
//-----------------io------------------//
 //                   input        clk50,
        //            input           k1,
                    output  [35:0] P1IO,
                    output  [35:0] P3IO
//-----------------------拨码测试-----------//
  



                            );



SONG SONG_u1(
        .clk50mhz(clk50mhz),
        .LED(LED),
        .high(high),
        .spk(spk),
        .rst(1'b1));

seg_led_static_top seg_led_static_top_u2(
                        .sys_clk(clk50mhz),    
                        .sys_rst_n(1'b1), 
                        .seg_sel(seg_sel), 
                        .seg_led(seg_led)); 


key_lcd key_lcd_u3(
                    .sys_clk(clk50mhz),  
                    .sys_rst_n(1'b1),
                    .key(key), 
                    .lcd(lcd)     
                    );

IO_led IO_led_u4(
                    .clk50(clk50mhz),
                    .k1(key),
                    .P1IO(P1IO),
                    .P3IO(P3IO)
                );














endmodule