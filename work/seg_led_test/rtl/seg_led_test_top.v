/*******************************************************************************
 * seg_led_test_top — 8 位数码管（共阳）测试
 *
 * 硬件：HX1P35A / PH1P35MDG324-3
 *   - 数码管：2 组 4 位一体，共 8 位，单排 4+4 排列（板手册 §11）
 *   - 段选 O_seg[7:0] = {DP, g, f, e, d, c, b, a}，低电平点亮
 *   - 位选 O_sel[7:0]：低电平选中（原理图 Q1~Q8 为 PNP9012）
 *       O_sel[7] = 最左位 … O_sel[0] = 最右位（与厂商 7_seg_led 例程的
 *       SEL[7:0] 端口顺序一致；注意板手册表格里的网络名 SEL0 是最左位）
 *   - SW6 必须拨到“数码管”一侧（拨上），否则 16 根复用脚会驱动双色 LED
 *
 * 模式（SW1，拨上=1）：
 *   SW1=0：从左到右静态显示 0 1 2 3 4 5 6 7
 *   SW1=1：显示 8 位同值计数；每按一次 K1 前进一步
 *          00000000 -> 11111111 -> … -> 99999999 -> 00000000 …
 *          K1 做 20ms 消抖，按住只算一次。
 *
 * 时钟：板载 50MHz（C4），不使用 PLL。
 * 复位：上电计数器产生内部复位；板卡没有独立复位按键。
 ******************************************************************************/
`timescale 1ns / 1ps

module seg_led_test_top #(
    parameter integer CLK_HZ      = 50_000_000, // 输入时钟
    parameter integer SCAN_HZ     = 1_000,      // 每位刷新节拍（8 位整帧 125Hz）
    parameter integer DEBOUNCE_MS = 20,         // K1 消抖时间
    parameter integer POR_CYCLES  = 65_535      // 上电复位等待周期
) (
    input  wire       I_sys_clk,  // C4，50MHz
    input  wire       I_sw1,      // A4，拨上=1
    input  wire       I_key1,     // D5，按下=0
    output reg  [7:0] O_seg,      // C9/C11/B11/E7/E6/B6/B7/E5，低有效
    output reg  [7:0] O_sel       // A14/B15/A15/B16/A18/A17/G14/G15，低有效
);

    // ------------------------------------------------------------------ 参数
    localparam [31:0] POR_MAX      = POR_CYCLES;
    localparam [31:0] SCAN_MAX     = CLK_HZ / SCAN_HZ;
    localparam [31:0] DEBOUNCE_MAX = (CLK_HZ / 1000) * DEBOUNCE_MS;

    // 位选极性：原理图为 PNP9012 驱动，低电平选中。
    // 若实测发现位选相反，把这里改成 1'b0 即可（段选仍保持低有效）。
    localparam SEL_ACTIVE_LOW = 1'b1;

    // ------------------------------------------------------------------ 上电复位
    reg [31:0] por_cnt;
    reg        rst_n;

    // 仅用于仿真时给上电计数器一个确定初值；FPGA 配置后寄存器同样从 0 开始。
    initial begin
        por_cnt = 32'd0;
        rst_n   = 1'b0;
    end

    always @(posedge I_sys_clk) begin
        if (por_cnt < POR_MAX) begin
            por_cnt <= por_cnt + 32'd1;
            rst_n   <= 1'b0;
        end else begin
            rst_n   <= 1'b1;
        end
    end

    // ------------------------------------------------------------------ 输入同步
    reg [2:0] sw1_sync;
    reg [2:0] key_sync;

    always @(posedge I_sys_clk) begin
        if (!rst_n) begin
            sw1_sync <= 3'b000;
            key_sync <= 3'b111;   // 按键松开=1
        end else begin
            sw1_sync <= {sw1_sync[1:0], I_sw1};
            key_sync <= {key_sync[1:0], I_key1};
        end
    end

    wire sw1_mode = sw1_sync[2];
    wire key_raw  = key_sync[2];

    // ------------------------------------------------------------------ K1 消抖
    // 电平稳定 DEBOUNCE_MS 后才更新 key_stable；key_stable 的下降沿表示一次按下。
    reg [31:0] db_cnt;
    reg        key_stable;
    reg        key_stable_d;

    always @(posedge I_sys_clk) begin
        if (!rst_n) begin
            db_cnt       <= 32'd0;
            key_stable   <= 1'b1;
            key_stable_d <= 1'b1;
        end else begin
            key_stable_d <= key_stable;

            if (key_raw != key_stable) begin
                if (db_cnt >= DEBOUNCE_MAX - 1) begin
                    db_cnt     <= 32'd0;
                    key_stable <= key_raw;
                end else begin
                    db_cnt <= db_cnt + 32'd1;
                end
            end else begin
                db_cnt <= 32'd0;
            end
        end
    end

    wire key_press = key_stable_d & ~key_stable;  // 下降沿，单拍

    // ------------------------------------------------------------------ 计数
    // SW1=1 时，每检测到一次 K1 下降沿就前进一步；0..9 循环。
    reg [3:0] count_val;

    always @(posedge I_sys_clk) begin
        if (!rst_n) begin
            count_val <= 4'd0;
        end else if (!sw1_mode) begin
            // SW1=0：静态图形模式，同时复位计数，保证切回 SW1=1 时从 0 开始
            count_val <= 4'd0;
        end else if (key_press) begin
            if (count_val == 4'd9)
                count_val <= 4'd0;
            else
                count_val <= count_val + 4'd1;
        end
    end

    // ------------------------------------------------------------------ 扫描
    reg [31:0] scan_cnt;
    reg [2:0]  scan_idx;

    always @(posedge I_sys_clk) begin
        if (!rst_n) begin
            scan_cnt <= 32'd0;
            scan_idx <= 3'd0;
        end else if (scan_cnt >= SCAN_MAX - 1) begin
            scan_cnt <= 32'd0;
            scan_idx <= scan_idx + 3'd1;
        end else begin
            scan_cnt <= scan_cnt + 32'd1;
        end
    end

    // 静态模式：scan_idx=0 选中 O_sel[0]（最右位），该位显示 7；
    //           scan_idx=7 选中 O_sel[7]（最左位），该位显示 0。
    // 计数模式：8 位都显示同一个 count_val。
    wire [3:0] disp_val = sw1_mode ? count_val : (4'd7 - {1'b0, scan_idx});

    // 共阳数码管段码，1=灭、0=亮；bit7=DP，bit6..0=g..a
    function [7:0] seg_decode;
        input [3:0] val;
        begin
            case (val)
                4'h0: seg_decode = 8'hC0;
                4'h1: seg_decode = 8'hF9;
                4'h2: seg_decode = 8'hA4;
                4'h3: seg_decode = 8'hB0;
                4'h4: seg_decode = 8'h99;
                4'h5: seg_decode = 8'h92;
                4'h6: seg_decode = 8'h82;
                4'h7: seg_decode = 8'hF8;
                4'h8: seg_decode = 8'h80;
                4'h9: seg_decode = 8'h90;
                default: seg_decode = 8'hFF;  // 全灭
            endcase
        end
    endfunction

    always @(posedge I_sys_clk) begin
        if (!rst_n) begin
            O_seg <= 8'hFF;
            O_sel <= 8'hFF;
        end else begin
            O_seg <= seg_decode(disp_val);
            if (SEL_ACTIVE_LOW)
                O_sel <= ~(8'h01 << scan_idx);
            else
                O_sel <=  (8'h01 << scan_idx);
        end
    end

endmodule
