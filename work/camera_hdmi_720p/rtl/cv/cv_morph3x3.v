`timescale 1ns / 1ps
//=============================================================================
// cv_morph3x3.v — 3x3 形态学（窗口 min/max），1bit 腐蚀/膨胀
//   对应 Python: Python/impl_hw/hw_ops.{erode, dilate}
//   MODE=0 -> 腐蚀(erode, 9 位与)；MODE=1 -> 膨胀(dilate, 9 位或)
//   用法：开 = 腐蚀->膨胀；闭 = 膨胀->腐蚀；级联两次 ≈ 5x5。
//   存储：2 行缓存 (IMG_W x 1bit) + 列延迟链（分布式）。
//=============================================================================
module cv_morph3x3 #(
    parameter IMG_W = 1280,
    parameter MODE  = 0            // 0=erode, 1=dilate
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_de,
    input  wire        I_vs,
    input  wire        I_pix,
    output reg         O_de,
    output reg         O_vs,
    output reg         O_pix
);
    // ---------- x/y ----------
    reg [11:0] r_x, r_y;
    reg        r_vs_d;
    wire       vs_rise = I_vs & ~r_vs_d;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin r_x <= 0; r_y <= 0; r_vs_d <= 0; end
        else begin
            r_vs_d <= I_vs;
            if (vs_rise) begin r_x <= 0; r_y <= 0; end
            else if (I_de) begin
                if (r_x == IMG_W - 1) begin r_x <= 0; r_y <= r_y + 1'b1; end
                else r_x <= r_x + 1'b1;
            end
        end
    end

    // ---------- 2 行缓存 ----------
    (* ram_style="block" *) reg r_l1 [0:IMG_W-1];   // 行 y-1
    (* ram_style="block" *) reg r_l2 [0:IMG_W-1];   // 行 y-2
    wire w_mid = r_l1[r_x];
    wire w_top = r_l2[r_x];

    reg t_p1, t_p2, m_p1, m_p2, b_p1, b_p2;
    always @(posedge I_clk) begin
        if (I_de) begin
            r_l1[r_x] <= I_pix;
            r_l2[r_x] <= w_mid;
            t_p2 <= t_p1; t_p1 <= w_top;
            m_p2 <= m_p1; m_p1 <= w_mid;
            b_p2 <= b_p1; b_p1 <= I_pix;
        end
    end

    wire [8:0] w_win = {t_p2, t_p1, w_top,
                        m_p2, m_p1, w_mid,
                        b_p2, b_p1, I_pix};
    wire       w_out = (MODE != 0) ? (|w_win) : (&w_win);

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin O_de <= 0; O_vs <= 0; O_pix <= 0; end
        else begin
            O_de  <= I_de;
            O_vs  <= I_vs;
            O_pix <= w_out;
        end
    end
endmodule
