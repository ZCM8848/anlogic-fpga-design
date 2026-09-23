module cnt10b( DIN, DOUT);//16进制数转换成10进制数
   input   [31:0]   DIN;
   output [31:0] DOUT;
  wire [31:0]    DOUT;
  wire  [31:0]   DIN1;
  
assign DIN1 = DIN;
wire    [3:0]              data0    ;        // 个位数
wire    [3:0]              data1    ;        // 十位数
wire    [3:0]              data2    ;        // 百位数
wire    [3:0]              data3    ;        // 千位数
wire    [3:0]              data4    ;        // 万位数
wire    [3:0]              data5    ;        // 十万位数
wire    [3:0]              data6    ;        // 百万位数
wire    [3:0]              data7    ;        // 千万位数
assign  DOUT = {data7,data6,data5,data4,data3,data2,data1,data0};

 

//*****************************************************
//**                    main code
//*****************************************************
assign  data7 = DIN1 / 32'd10000000;           // 千万位数
assign  data6 = DIN1/ 32'd1000000%4'd10;      // 百万位数
assign  data5 = DIN1 / 32'd100000%4'd10;      // 十万位数
assign  data4 = DIN1 / 32'd10000 % 4'd10;      // 万位数
assign  data3 = DIN1 / 32'd1000 % 4'd10 ;    // 千位数
assign  data2 = DIN1 /  32'd100 % 4'd10  ;    // 百位数
assign  data1 = DIN1 /  32'd10 % 4'd10   ;    // 十位数
assign  data0 = DIN1 %  32'd10;               // 个位数
endmodule 
