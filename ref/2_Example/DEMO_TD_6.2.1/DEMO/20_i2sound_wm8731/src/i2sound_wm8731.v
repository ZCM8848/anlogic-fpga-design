// Create Date: 2021/03/23 09:19:53
// Design Name: ¿¨À­OK_WM8731
// Module Name: i2sound_wm8731
module i2sound_wm8731( input clock_50,input [1:0] key,input aud_adcdat,input aud_bclk,
                       input aud_daclrck,input aud_adclrck,output aud_dacdat,output aud_xck,
                       inout i2c_dat,output i2c_sclk,output  keyon

    );
    
    wire sound;
    wire clk_1mhz;
    wire xck;
    wire END;
    wire [23:0] i2c_data;
    wire go;
    wire keyon_n;
     keytr keytr_inst(
				.key(key[0]),
				.key1(key[1]),
				.ON(),
				.clock(clk_1mhz),
				.KEYON(keyon_n),
				.counter()	
			 );
    CLOCK_500  CLK_500(
	              .CLOCK(clock_50),
 	              .CLOCK_500(clk_1mhz),
	              .DATA(i2c_data),
	              .END(END),
	              .RESET(keyon_n),
	              .GO(go),
	              .CLOCK_2(xck)
                );
                 i2c i2c_inst(
			 .CLOCK(clk_1mhz),
			 .I2C_SCLK(i2c_sclk),		//I2C CLOCK
			 .I2C_SDAT(i2c_dat),		//I2C DATA
			 .I2C_DATA(i2c_data),		//DATA:[SLAVE_ADDR,SUB_ADDR,DATA]
			 .GO(go),      		//GO transfor
			 .END(END),    	    //END transfor 
			 .W_R(),     		//W_R
			 .ACK(),     	    //ACK
			 .RESET(1'b1),
			 //TEST
			 .SD_COUNTER(),
			 .SDO()
		   	);
assign aud_xck = xck;
assign sound = aud_adcdat;
assign aud_dacdat = sound;
assign     keyon =  keyon_n;
endmodule
