module seg70(clk, rst, dataout, en);
   input         clk;          //50MHz晶振
   input         rst;           //复位信号
   output [15:0]  dataout;       //16位行扫描信号
   output [15:0] en;              //16位列扫描信号
   reg [15:0]    cnt_scan;        //16位分频计数器寄存器信号
   reg [3:0]     data4;              
   reg [15:0]     dataout_xhdl1;  //16位行扫描信号寄存器
	   reg [15:0]    en_xhdl;
   assign dataout = dataout_xhdl1;
   assign en = en_xhdl;
	reg   [1:0] cnt_word;
	reg[24:0] cnt_clk_n;
	always @(posedge clk)         //分频生成汉字显示切换时钟
	begin  cnt_clk_n = cnt_clk_n +1'b1;   //计数
			 if(cnt_clk_n==25'd9999999)
			cnt_word <= cnt_word + 1'b1;
			end 
   
   always @(posedge clk or negedge rst)
      if (rst == 1'b0)
         cnt_scan <= 16'd0;
      else 
         cnt_scan <= cnt_scan + 1'b1;
   
   always @(cnt_scan[15:12])    //扫描程序
      case (cnt_scan[15:12])
         4'b0000 :
            en_xhdl <= 16'b1111111111111110;
         4'b0001 :
            en_xhdl <= 16'b1111111111111101;
         4'b0010 :
            en_xhdl <= 16'b1111111111111011;
         4'b0011 :
            en_xhdl <= 16'b1111111111110111;
         4'b0100 :
            en_xhdl <= 16'b1111111111101111;
         4'b0101 :
            en_xhdl <= 16'b1111111111011111;
         4'b0110 :
            en_xhdl <= 16'b1111111110111111;
         4'b0111 :
            en_xhdl <= 16'b1111111101111111;
         4'b1000 :
            en_xhdl <= 16'b1111111011111111;
         4'b1001 :
            en_xhdl <= 16'b1111110111111111;
         4'b1010 :
            en_xhdl <= 16'b1111101111111111;
         4'b1011 :
            en_xhdl <= 16'b1111011111111111;
         4'b1100 :
            en_xhdl <= 16'b1110111111111111;
         4'b1101 :
            en_xhdl <= 16'b1101111111111111;
         4'b1110 :
            en_xhdl <= 16'b1011111111111111;
         4'b1111 :
            en_xhdl <= 16'b0111111111111111;
         default :
            en_xhdl <= 16'b1111111111111111;
      endcase
   
   always @(en_xhdl)
      case (en_xhdl)
         16'b1111111111111110 :
            data4 <= 4'b0000;
         16'b1111111111111101 :
            data4 <= 4'b0001;
         16'b1111111111111011 :
            data4 <= 4'b0010;
         16'b1111111111110111 :
            data4 <= 4'b0011;
         16'b1111111111101111 :
            data4 <= 4'b0100;
         16'b1111111111011111 :
            data4 <= 4'b0101;
         16'b1111111110111111 :
            data4 <= 4'b0110;
         16'b1111111101111111 :
            data4 <= 4'b0111;
         16'b1111111011111111 :
            data4 <= 4'b1000;
         16'b1111110111111111 :
            data4 <= 4'b1001;
         16'b1111101111111111 :
            data4 <= 4'b1010;
         16'b1111011111111111 :
            data4 <= 4'b1011;
         16'b1110111111111111 :
            data4 <= 4'b1100;
         16'b1101111111111111 :
            data4 <= 4'b1101;
         16'b1011111111111111 :
            data4 <= 4'b1110;
         16'b0111111111111111 :
            data4 <= 4'b1111;
         
         default :
            data4 <= 4'b1111;
      endcase
		
		 always @(data4,cnt_word)
		 if(cnt_word==2'd0)
      case (data4)                    
		//汉字16X16-杭  软件把字转化成一组数据
         4'b0000 :
            dataout_xhdl1 <= 16'h0410;
         4'b0001 :
            dataout_xhdl1 <= 16'h0310;
         4'b0010 :
            dataout_xhdl1 <= 16'h00d0;
         4'b0011 :
            dataout_xhdl1 <= 16'hffff;
         4'b0100 :
            dataout_xhdl1 <= 16'h0090;
         4'b0101 :
            dataout_xhdl1 <= 16'h8310;
         4'b0110 :
            dataout_xhdl1 <= 16'h6008;
         4'b0111 :
            dataout_xhdl1 <= 16'h1fc8;
         4'b1000 :
            dataout_xhdl1 <= 16'h0049;
         4'b1001 :
            dataout_xhdl1 <= 16'h004e;
         4'b1010 :
            dataout_xhdl1 <= 16'h0048;
         4'b1011 :
            dataout_xhdl1 <= 16'h3fc8;
         4'b1100 :
            dataout_xhdl1 <= 16'h4008;
         4'b1101 :
            dataout_xhdl1 <= 16'h4008;
         4'b1110 :
            dataout_xhdl1 <= 16'h7800;
         4'b1111 :
            dataout_xhdl1 <= 16'h0000;
         
         default :
            dataout_xhdl1 <= 16'h0001;
      endcase
		
		 else  if (cnt_word==2'd1)
      case (data4)                      //汉字16X16-州
         4'b0000 :
            dataout_xhdl1 <= 16'h8100;
         4'b0001 :
            dataout_xhdl1 <= 16'h40e0;
         4'b0010 :
            dataout_xhdl1 <= 16'h3000;
         4'b0011 :
            dataout_xhdl1 <= 16'h0fff;
         4'b0100 :
            dataout_xhdl1 <= 16'h0000;
         4'b0101 :
            dataout_xhdl1 <= 16'h0020;
         4'b0110 :
            dataout_xhdl1 <= 16'h00c0;
         4'b0111 :
            dataout_xhdl1 <= 16'h0000;
         4'b1000 :
            dataout_xhdl1 <= 16'h3ffe;
         4'b1001 :
            dataout_xhdl1 <= 16'h0000;
         4'b1010 :
            dataout_xhdl1 <= 16'h0020;
         4'b1011 :
            dataout_xhdl1 <= 16'h00c0;
         4'b1100 :
            dataout_xhdl1 <= 16'h0000;
         4'b1101 :
            dataout_xhdl1 <= 16'hffff;
         4'b1110 :
            dataout_xhdl1 <= 16'h0000;
         4'b1111 :
            dataout_xhdl1 <= 16'h0000;
         
         default :
            dataout_xhdl1 <= 16'h0001;
      endcase
   

		 else  if (cnt_word==2'd2)
      case (data4)                    //汉字16X16-康
         4'b0000 :
            dataout_xhdl1 <= 16'h4000;
         4'b0001 :
            dataout_xhdl1 <= 16'h3000;
         4'b0010 :
            dataout_xhdl1 <= 16'h0ffc;
         4'b0011 :
            dataout_xhdl1 <= 16'h4044;
         4'b0100 :
            dataout_xhdl1 <= 16'h2354;
         4'b0101 :
            dataout_xhdl1 <= 16'h5415;
         4'b0110 :
            dataout_xhdl1 <= 16'h4954;
         4'b0111 :
            dataout_xhdl1 <= 16'h8155;
         4'b1000 :
            dataout_xhdl1 <= 16'h7ffe;
         4'b1001 :
            dataout_xhdl1 <= 16'h0554;
         4'b1010 :
            dataout_xhdl1 <= 16'h0954;
         4'b1011 :
            dataout_xhdl1 <= 16'h1154;
         4'b1100 :
            dataout_xhdl1 <= 16'h29f4;
         4'b1101 :
            dataout_xhdl1 <= 16'h4444;
         4'b1110 :
            dataout_xhdl1 <= 16'h4044;
         4'b1111 :
            dataout_xhdl1 <= 16'h0000;
         
         default :
            dataout_xhdl1 <= 16'h0001;
      endcase
		  else   if (cnt_word==2'd3)
      case (data4)            //汉字16X16-芯
         4'b0000 :
            dataout_xhdl1 <= 16'h1004;
         4'b0001 :
            dataout_xhdl1 <= 16'h0804;
         4'b0010 :
            dataout_xhdl1 <= 16'h0604;
         4'b0011 :
            dataout_xhdl1 <= 16'h0004;
         4'b0100 :
            dataout_xhdl1 <= 16'h001f;
         4'b0101 :
            dataout_xhdl1 <= 16'h3f04;
         4'b0110 :
            dataout_xhdl1 <= 16'h4024;
         4'b0111 :
            dataout_xhdl1 <= 16'h4044;
         4'b1000 :
            dataout_xhdl1 <= 16'h4084;
         4'b1001 :
            dataout_xhdl1 <= 16'h4004;
         4'b1010 :
            dataout_xhdl1 <= 16'h401f;
         4'b1011 :
            dataout_xhdl1 <= 16'h7004;
         4'b1100 :
            dataout_xhdl1 <= 16'h0104;
         4'b1101 :
            dataout_xhdl1 <= 16'h0204;
         4'b1110 :
            dataout_xhdl1 <= 16'h0c04;
         4'b1111 :
            dataout_xhdl1 <= 16'h0000;
         
         default :
            dataout_xhdl1 <= 16'h0001;
      endcase	 
endmodule
