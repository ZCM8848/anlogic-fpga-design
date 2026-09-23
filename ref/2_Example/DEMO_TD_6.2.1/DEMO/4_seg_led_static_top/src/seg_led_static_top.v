module seg_led_static_top (
    input               sys_clk  ,       // 系统时钟
    input               sys_rst_n,       // 系统复位信号（低有效）

    output    [7:0]     seg_sel  ,       // 数码管位选
    output    [7:0]     seg_led          // 数码管段选

);

//parameter define
parameter  TIME_SHOW = 25'd25000_000;    // 数码管变化的时间间隔0.5s

//wire define
wire       add_flag;                     // 数码管变化的通知信号

//*****************************************************
//**                    main code
//*****************************************************

//每隔0.5s产生一个时钟周期的脉冲信号
time_count #(
    .MAX_NUM    (TIME_SHOW)
) u_time_count(
    .clk        (sys_clk  ),
    .rst_n      (sys_rst_n),
    
    .flag       (add_flag )
);

//每当脉冲信号到达时，使数码管显示的数值加1
seg_led_static u_seg_led_static (
    .clk        (sys_clk  ), 
    .rst_n      (sys_rst_n),

    .add_flag    (add_flag ), 
    .seg_sel     (seg_sel   ),
    .seg_led     (seg_led  )
);

endmodule 