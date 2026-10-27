// cam_raw10_rx.v — SC520CS 摄像头前端：MIPI D-PHY → CSI-2 → RAW10 → 字节流
//
// 数据通路：
//   MIPI 2lane(828Mbps)
//     → D-PHY IP（硬核 pad，DPHY0）
//     → csi_unpacket_2lane        (16bit 双 lane → 32bit CSI 字)
//     → raw10_unpacket_2lane      (40bit = 4 × 10bit 像素)
//     → async_fifo 41bit×1024     (写 csi_rx_clk ~103.5MHz / 读 clk_sys 125MHz)
//     → 2 级预取展开器             (40bit → 5 字节，持续 1 字节/周期)
//
// 为什么 FIFO 要 40bit：MIPI 突发 207 MB/s，8bit@103.5MHz 只有 103 MB/s。
//
// 字节打包（MIPI RAW10 标准，4 像素 → 5 字节）：
//   b0 = P0[9:2] , b1 = P1[9:2] , b2 = P2[9:2] , b3 = P3[9:2]
//   b4 = { P3[1:0], P2[1:0], P1[1:0], P0[1:0] }
//   （raw10_unpacket 的 40bit 里 P0 在最高位：[39:30]=P0 … [9:0]=P3）
//
`timescale 1ns/1ps

module cam_raw10_rx (
    input  wire        I_clk_24m,        // PLL C1 = 23.81MHz（XCLK + I2C）
    input  wire        I_rst_n_24m,
    input  wire        I_clk_sys,        // PLL C0 = 125MHz（LP clk / FIFO 读 / 展开）
    input  wire        I_rst_n_sys,

    // ---- 摄像头控制 ----
    output wire        O_cam_xclk,       // L3
    output wire        O_cam_pwdnb,      // L2（高=工作）
    output wire        O_cam_scl,        // K3
    inout  wire        IO_cam_sda,       // J3

    // ---- MIPI 硬核 pad ----
    inout  wire        IO_rx_clk_pad_p,  // V16
    inout  wire        IO_rx_clk_pad_n,  // U16
    inout  wire [3:0]  IO_rx_data_pad_p, // V14/V15/V17/U18
    inout  wire [3:0]  IO_rx_data_pad_n, // U14/U15/U17/V18

    // ---- 字节流输出（I_clk_sys 域，1 字节/周期）----
    output wire [7:0]  O_byte,
    output wire        O_byte_v,         // 本拍有有效字节
    input  wire        I_byte_rd,        // 消费一个字节（必须，否则会重复输出）
    output wire        O_frame_start,    // 与某字节同拍
    output wire [10:0] O_avail_words,    // FIFO 中可用字数（×5 = 字节数，偏小保守）
    output wire [15:0] O_frame_cnt,      // 收到的 RAW10 帧数

    // ---- 状态 ----
    output wire        O_cfg_done,
    output wire        O_sensor_ok,
    output wire [15:0] O_sensor_id,
    output wire        O_ovf,            // FIFO 溢出（粘滞）
    output wire        O_lane_err
);

    // ==================================================================
    // 摄像头上电时序：PWDNB 低 ≥1ms，释放后再等 ≥5ms 才开始 I2C
    // ==================================================================
    localparam integer PWDNB_LOW_CYCLES = 23810;     // 1ms  @23.81MHz
    localparam integer I2C_START_CYCLES = 142857;    // 6ms  @23.81MHz

    reg [17:0] pwr_cnt;
    reg        cam_pwdnb;
    reg        cam_i2c_ready;

    always @(posedge I_clk_24m or negedge I_rst_n_24m) begin
        if (!I_rst_n_24m) begin
            pwr_cnt       <= 18'd0;
            cam_pwdnb     <= 1'b0;
            cam_i2c_ready <= 1'b0;
        end else begin
            if (pwr_cnt < I2C_START_CYCLES)
                pwr_cnt <= pwr_cnt + 1'b1;
            if (pwr_cnt >= PWDNB_LOW_CYCLES)
                cam_pwdnb <= 1'b1;
            if (pwr_cnt >= I2C_START_CYCLES - 1)
                cam_i2c_ready <= 1'b1;
        end
    end

    assign O_cam_xclk  = I_clk_24m;
    assign O_cam_pwdnb = cam_pwdnb;

    // ==================================================================
    // I2C 配置（SC520CS 720p60 RAW10 2lane）
    // ==================================================================
    wire [15:0] cfg_sensor_id;
    wire        cfg_done, cfg_id_ok, cfg_iic_err;

    uicfgcs520 #(
        .CLK_DIV ( 23809524 / 100000 - 1 )      // 100 kHz @23.81MHz
    ) u_cfg (
        .I_clk          ( I_clk_24m      ),
        .I_rst_n        ( cam_i2c_ready  ),
        .I_ae_req       ( 1'b0           ),
        .I_ae           ( 16'd0          ),
        .I_ag           ( 16'd0          ),
        .O_cam_scl      ( O_cam_scl      ),
        .IO_cam_sda     ( IO_cam_sda     ),
        .O_cfg_done     ( cfg_done       ),
        .O_ae_cfg_done  (                ),
        .O_sensor_id    ( cfg_sensor_id  ),
        .O_sensor_id_ok ( cfg_id_ok      ),
        .O_iic_error    ( cfg_iic_err    )
    );

    assign O_cfg_done  = cfg_done;
    assign O_sensor_ok = cfg_id_ok;
    assign O_sensor_id = cfg_sensor_id;

    // ==================================================================
    // MIPI D-PHY（DPHY0，2 lane，3dB 均衡 / 8dB 增益，与 camera_hdmi 一致）
    // ==================================================================
    wire        csi_rx_clk;
    wire [15:0] hs_rx_data;
    wire        hs_rx_valid;
    wire [1:0]  lane_error;

    mipi_dphy_rx_ph1p_mipiio_wrapper #(
        .DPHY_RX_LOCATION ( "DPHY0" ),
        .HS_EQUALIZER     ( "3dB"   ),
        .HS_VGA_GAIN      ( "8dB"   ),
        .LANE_NUM         ( 2       ),
        .BYTE_NUM         ( 1       )
    ) u_dphy (
        .I_lp_clk              ( I_clk_sys       ),
        .I_rst                 ( ~I_rst_n_sys    ),
        .I_clk_lane_in_delay   ( 6'd0            ),
        .I_data_lane0_in_delay ( 6'd0            ),
        .I_data_lane1_in_delay ( 6'd0            ),
        .I_data_lane2_in_delay ( 6'd0            ),
        .I_data_lane3_in_delay ( 6'd0            ),
        .I_lane_invert         ( 4'b0000         ),
        .O_hs_rx_clk           ( csi_rx_clk      ),
        .O_hs_rx_valid         ( hs_rx_valid     ),
        .O_hs_rx_data          ( hs_rx_data      ),
        .O_lp_rx_lane0_p       (                 ),
        .O_lp_rx_lane0_n       (                 ),
        .I_lp_tx_en            ( 1'b0            ),
        .I_lp_tx_lane0_p       ( 1'b1            ),
        .I_lp_tx_lane0_n       ( 1'b1            ),
        .O_lane_match_error    (                 ),
        .O_lane_error          ( lane_error      ),
        .IO_rx_clk_pad_n       ( IO_rx_clk_pad_n ),
        .IO_rx_clk_pad_p       ( IO_rx_clk_pad_p ),
        .IO_rx_data_pad_n      ( IO_rx_data_pad_n),
        .IO_rx_data_pad_p      ( IO_rx_data_pad_p)
    );

    assign O_lane_err = |lane_error;

    // csi_rx_clk 域复位：由 sys 复位同步过来（HS 停时该域会冻结，属正常）
    reg [1:0] rx_rst_sync;
    always @(posedge csi_rx_clk or negedge I_rst_n_sys) begin
        if (!I_rst_n_sys) rx_rst_sync <= 2'b00;
        else              rx_rst_sync <= {rx_rst_sync[0], 1'b1};
    end
    wire rst_n_rx = rx_rst_sync[1];

    // ==================================================================
    // CSI-2 解包 → RAW10
    // ==================================================================
    wire        csi_fs, csi_fe, csi_valid;
    wire [31:0] csi_data;

    csi_unpacket_2lane u_csi (
        .I_clk             ( csi_rx_clk   ),
        .I_rst_n           ( rst_n_rx     ),
        .I_hs_valid        ( hs_rx_valid  ),
        .I_hs_data         ( hs_rx_data   ),
        .O_csi_frame_start ( csi_fs       ),
        .O_csi_frame_end   ( csi_fe       ),
        .O_csi_valid       ( csi_valid    ),
        .O_csi_hs          (              ),
        .O_csi_data        ( csi_data     )
    );

    wire        raw_fs, raw_fe, raw_valid;
    wire [39:0] raw_data;

    raw10_unpacket_2lane u_raw10 (
        .I_clk                ( csi_rx_clk ),
        .I_rst_n              ( rst_n_rx   ),
        .I_csi_frame_start    ( csi_fs     ),
        .I_csi_frame_end      ( csi_fe     ),
        .I_csi_valid          ( csi_valid  ),
        .I_csi_data           ( csi_data   ),
        .I_camera_black_level ( 10'd0      ),
        .O_raw10_frame_start  ( raw_fs     ),
        .O_raw10_frame_end    ( raw_fe     ),
        .O_raw10_valid        ( raw_valid  ),
        .O_raw10_data         ( raw_data   )
    );

    // 帧计数（csi 域）
    reg [15:0] cam_frame_cnt;
    always @(posedge csi_rx_clk or negedge rst_n_rx) begin
        if (!rst_n_rx) cam_frame_cnt <= 16'd0;
        else if (raw_fs) cam_frame_cnt <= cam_frame_cnt + 16'd1;
    end

    // ==================================================================
    // 40bit 异步 FIFO（+1 bit 帧起始标记）
    // ==================================================================
    wire [40:0] fifo_dout;
    wire        fifo_empty;
    wire        fifo_full;
    wire [10:0] fifo_used;
    wire        fifo_rinc;

    async_fifo #(
        .DW ( 41 ),
        .AW ( 10 )
    ) u_fifo (
        .wclk   ( csi_rx_clk            ),
        .wrst_n ( rst_n_rx              ),
        .winc   ( raw_valid             ),
        .wdata  ( { raw_fs, raw_data }  ),
        .wfull  ( fifo_full             ),
        .rclk   ( I_clk_sys             ),
        .rrst_n ( I_rst_n_sys           ),
        .rinc   ( fifo_rinc             ),
        .rdata  ( fifo_dout             ),
        .rempty ( fifo_empty            ),
        .rused  ( fifo_used             )
    );

    // 溢出检测：fifo_full 是写域电平，跨到读域后做粘滞（避免在 D-PHY 恢复时钟域里
    // 写带使能的寄存器——TD 6.2 对这种结构会报 SYN-8613）
    reg [1:0] full_sync;
    always @(posedge I_clk_sys or negedge I_rst_n_sys) begin
        if (!I_rst_n_sys) full_sync <= 2'b00;
        else              full_sync <= {full_sync[0], fifo_full};
    end

    // ==================================================================
    // 展开器：40bit → 5 字节，持续 1 字节/周期（2 级预取填平 FIFO 读延迟）
    // ==================================================================
    reg [39:0] b0, b1;
    reg        fs0, fs1;
    reg        v0, v1;
    reg [2:0]  bi;

    wire [40:0] rdata = fifo_dout;

    // 只有在“上一字节已被消费”时才推进
    wire byte_done = v0 & (bi == 3'd4) & I_byte_rd;
    wire take_b1   = v1 & (~v0 | byte_done);
    wire adv       = v0 & I_byte_rd & (bi != 3'd4);

    assign fifo_rinc = ~fifo_empty & ~v1;

    always @(posedge I_clk_sys or negedge I_rst_n_sys) begin
        if (!I_rst_n_sys) begin
            b0 <= 40'd0; b1 <= 40'd0;
            fs0 <= 1'b0; fs1 <= 1'b0;
            v0  <= 1'b0; v1  <= 1'b0;
            bi  <= 3'd0;
        end else begin
            // b1 预取
            if (fifo_rinc) begin
                b1  <= rdata[39:0];
                fs1 <= rdata[40];
                v1  <= 1'b1;
            end else if (take_b1) begin
                v1  <= 1'b0;
            end

            // b0 消耗
            if (take_b1) begin
                b0  <= b1;
                fs0 <= fs1;
                v0  <= 1'b1;
                bi  <= 3'd0;
            end else if (byte_done) begin
                v0 <= 1'b0;
                bi <= 3'd0;
            end else if (adv) begin
                bi <= bi + 3'd1;
            end
        end
    end

    // 字节选择（P0 在最高位）
    reg [7:0] byte_mux;
    always @(*) begin
        case (bi)
            3'd0: byte_mux = b0[39:32];                                     // P0[9:2]
            3'd1: byte_mux = b0[29:22];                                     // P1[9:2]
            3'd2: byte_mux = b0[19:12];                                     // P2[9:2]
            3'd3: byte_mux = b0[9:2];                                       // P3[9:2]
            3'd4: byte_mux = { b0[1:0], b0[11:10], b0[21:20], b0[31:30] };  // 低 2bit
            default: byte_mux = 8'h00;
        endcase
    end

    assign O_byte        = byte_mux;
    assign O_byte_v      = v0;
    assign O_frame_start = v0 & fs0 & (bi == 3'd0) & I_byte_rd;
    assign O_avail_words = fifo_used;      // 已用字数（0..1024），×5 = 字节数
    assign O_frame_cnt   = cam_frame_cnt;

    // 溢出标志跨到 sys 域（调试用）
    reg       ovf_sticky;
    always @(posedge I_clk_sys or negedge I_rst_n_sys) begin
        if (!I_rst_n_sys) ovf_sticky <= 1'b0;
        else              ovf_sticky <= ovf_sticky | full_sync[1];
    end
    assign O_ovf = ovf_sticky;

endmodule
