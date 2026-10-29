/*******************************MILIANKE*******************************
* Company : MiLianKe Electronic Technology Co., Ltd.
* WebSite : https://www.milianke.com
* Description: manual AE/AG setpoint, now controlled by the MCU.
*
* AE (exposure) is in half-line units, valid 2..1991 for 720p60.
* AG (gain) is the sensor gain code, valid 16..176.
* The old N2/J14 button adjustment is retired; MCU writes CAM_AE/CAM_AG.
*********************************************************************/
`timescale 1ns / 1ps

module ae_set
(
    input  wire        I_clk,           // 24 MHz camera config clock
    input  wire        I_rst,
    input  wire [15:0] I_ae_set,        // target exposure, half-lines
    input  wire [15:0] I_ag_set,        // target gain code
    input  wire        I_ae_cfg_done,
    input  wire        I_cam_cfg_done,
    output reg         O_ae_req,
    output wire [15:0] O_ae,
    output wire [15:0] O_ag
);

    // Clamp targets to the sensor's legal range.
    wire [15:0] w_ae = (I_ae_set < 16'd2)    ? 16'd2    :
                       (I_ae_set > 16'd1991) ? 16'd1991 : I_ae_set;
    wire [15:0] w_ag = (I_ag_set < 16'd16)   ? 16'd16   :
                       (I_ag_set > 16'd176)  ? 16'd176  : I_ag_set;

    reg [15:0] r_ae;
    reg [15:0] r_ag;

    assign O_ae = r_ae;
    assign O_ag = r_ag;

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            O_ae_req <= 1'b0;
            r_ae     <= 16'hFFFF;       // force a write after camera config
            r_ag     <= 16'hFFFF;
        end else if (O_ae_req) begin
            O_ae_req <= 1'b0;
        end else if ((r_ae != w_ae || r_ag != w_ag) &&
                     I_cam_cfg_done && I_ae_cfg_done) begin
            r_ae     <= w_ae;
            r_ag     <= w_ag;
            O_ae_req <= 1'b1;
        end
    end

endmodule
