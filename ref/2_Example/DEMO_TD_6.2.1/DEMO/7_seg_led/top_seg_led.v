module top_seg_led(
    //global clock
    input            CLOCK  ,       // 全局时钟信号
    input            rst,       // 复位信号（低有效）

    //seg_led interface
    output    [7:0]    SEL  ,       // 数码管位选信号
    output    [7:0]   DIG       // 数码管段选信号
);

//wire define
wire    [19:0]  data;                 // 数码管显示的数值
wire    [ 5:0]  point;                // 数码管小数点的位置
wire            en;                   // 数码管显示使能信号
wire            sign;                 // 数码管显示数据的符号位

assign SEL[7:6] = 2'b11;
//计数器模块，产生数码管需要显示的数据
count u_count(
    .clk           (CLOCK  ),       // 时钟信号
    .rst_n         (rst),       // 复位信号

    .data          (data     ),       // 6位数码管要显示的数值
    .point         (point    ),       // 小数点具体显示的位置,高电平有效
    .en            (en       ),       // 数码管使能信号
    .sign          (sign     )        // 符号位
);

//数码管动态显示模块
seg_led u_seg_led(
    .clk           (CLOCK  ),       // 时钟信号
    .rst_n         (rst),       // 复位信号

    .data          (data     ),       // 显示的数值
    .point         (point    ),       // 小数点具体显示的位置,高电平有效
    .en            (en       ),       // 数码管使能信号
    .sign          (sign     ),       // 符号位，高电平显示负号(-)
    
    .seg_sel       (SEL[5:0]  ),       // 位选
    .seg_led       (DIG  )        // 段选
);

endmodule