`timescale 1ns / 1ps
//=============================================================================
// tb_ahb_status_slave.v — ahb_status_slave RTL 仿真（iverilog）
//   AHB-Lite 零等待 master 模型 + 寄存器读写校验。
//=============================================================================
module tb_ahb_status_slave;
    reg         hclk = 0;
    reg         hresetn = 0;
    reg  [1:0]  htrans = 2'b00;
    reg         hwrite = 0;
    reg  [30:0] haddr = 0;
    reg  [2:0]  hsize = 3'b010;   // word
    reg  [2:0]  hburst = 0;
    reg  [3:0]  hprot = 0;
    reg         hmastlock = 0;
    reg  [31:0] hwdata = 0;
    wire [31:0] hrdata;
    wire        hreadyout;
    wire [1:0]  hresp;

    // 状态输入
    reg [15:0] cam_id = 0; reg cam_id_ok=0, cam_i2c_err=0, cam_cfg_done=0;
    reg        ddr_rdy=0, sw4=0, sw3=0, sw2=0, sw1=0, cv_on=0;
    reg [5:0]  blob_cnt=0; reg [7:0] bin_thr=0; reg [10:0] run_cnt=0;
    reg        run_overflow=0;
    reg        vsync = 0;
    reg        key1_long = 0;
    reg [15:0] skip_roi_cnt = 0;
    reg [15:0] skip_len_cnt = 0;
    reg        ball_bg_ready = 0;
    reg        ball_capturing = 0;
    reg [31:0] run_rd_data = 0;
    wire [31:0] heartbeat, scratch, frame_cnt;

    integer npass = 0, nfail = 0;

    ahb_status_slave #(.VER(32'h4D435601)) DUT (
        .I_hclk(hclk), .I_hresetn(hresetn),
        .I_htrans(htrans), .I_hwrite(hwrite), .I_haddr(haddr),
        .I_hsize(hsize), .I_hburst(hburst), .I_hprot(hprot),
        .I_hmastlock(hmastlock), .I_hwdata(hwdata),
        .O_hrdata(hrdata), .O_hreadyout(hreadyout), .O_hresp(hresp),
        .I_cam_id(cam_id), .I_cam_id_ok(cam_id_ok), .I_cam_i2c_err(cam_i2c_err),
        .I_cam_cfg_done(cam_cfg_done), .I_ddr_rdy(ddr_rdy),
        .I_sw1(sw1), .I_sw2(sw2), .I_sw4(sw4), .I_sw3(sw3),
        .I_cv_on(cv_on), .I_blob_cnt(blob_cnt),
        .I_bin_thr(bin_thr), .I_run_cnt(run_cnt),
        .I_run_overflow(run_overflow),
        .I_vsync(vsync),
        .I_key1_long(key1_long),
        .I_skip_roi_cnt(skip_roi_cnt), .I_skip_len_cnt(skip_len_cnt),
        .I_ball_bg_ready(ball_bg_ready), .I_ball_capturing(ball_capturing),
        .I_run_rd_data(run_rd_data),
        .O_run_rd_addr(),
        .O_overlay(), .O_count(), .O_count_bcd(), .O_ball_now(),
        .O_ball_en(), .O_ball_bg_thr(), .O_ball_min_run(),
        .O_ball_roi_y1(), .O_ball_max_run_len(), .O_ball_capture(),
        .O_heartbeat(heartbeat), .O_scratch(scratch), .O_frame_cnt(frame_cnt)
    );

    always #3.33 hclk = ~hclk;   // ~150MHz

    // AHB 写（零等待，word）：地址相一拍 + 数据相一拍
    task ahb_write(input [31:0] a, input [31:0] d, input [2:0] sz);
    begin
        @(negedge hclk);
        htrans = 2'b10; hwrite = 1; haddr = a; hsize = sz;
        @(negedge hclk);          // 数据相
        hwdata = d;
        htrans = 2'b00; hwrite = 0; hsize = 3'b010;
        @(negedge hclk);
        hwdata = 0;
    end
    endtask

    // AHB 读（零等待）：地址相一拍，数据相采 hrdata
    task ahb_read(input [31:0] a, output [31:0] d);
    begin
        @(negedge hclk);
        htrans = 2'b10; hwrite = 0; haddr = a; hsize = 3'b010;
        @(negedge hclk);          // 数据相：hrdata 已稳定（锁存地址对应寄存器）
        #1 d = hrdata;
        htrans = 2'b00;
        @(negedge hclk);
    end
    endtask

    task chk(input [255:0] name, input [31:0] got, input [31:0] exp);
    begin
        if (got === exp) begin
            npass = npass + 1;
            $display("  [PASS] %0s  got=%08h exp=%08h", name, got, exp);
        end else begin
            nfail = nfail + 1;
            $display("  [FAIL] %0s  got=%08h exp=%08h", name, got, exp);
        end
    end
    endtask

    reg [31:0] rd;
    reg [31:0] exp_cam, exp_cv;

    initial begin
        hresetn = 0;
        repeat (4) @(posedge hclk);
        @(negedge hclk); hresetn = 1;

        // === 1. VER_REG ===
        ahb_read(32'h0C, rd);
        chk("VER_REG", rd, 32'h4D435601);

        // === 2. CAM_REG 打包 ===
        cam_id=16'h9E4B; cam_id_ok=1; cam_i2c_err=0; cam_cfg_done=1;
        ddr_rdy=1; sw4=1; sw3=0; cv_on=0; blob_cnt=6'd3;
        exp_cam = {16'h9E4B, 1'b1, 1'b0, 1'b1, 1'b1, 1'b1, 1'b0, 1'b0, 3'b000, 6'd3};
        // 等同步（2FF）：多给几拍
        repeat (4) @(negedge hclk);
        ahb_read(32'h00, rd);
        chk("CAM_REG", rd, exp_cam);

        // === 3. CV_REG ===
        bin_thr=8'h5B; run_cnt=11'h140; run_overflow=0;
        repeat (4) @(negedge hclk);
        exp_cv = {8'h5B, 3'b000, 11'h140, 2'b00, frame_cnt[7:0]};
        ahb_read(32'h04, rd);
        chk("CV_REG", rd, exp_cv);

        // === 4. 帧计数（vsync 上升沿）===
        // 状态同步在 ahb_clk，vsync 经 2FF；给 vsync 一拍高再低，等 2FF+edge
        @(negedge hclk); vsync=1; @(negedge hclk); vsync=0;
        repeat (3) @(negedge hclk);
        chk("frame_cnt after 1 vsync", frame_cnt, 32'd1);
        ahb_read(32'h08, rd);
        chk("FRAME_REG readback", rd, 32'd1);

        // === 5. 写 HEARTBEAT（word）===
        ahb_write(32'h10, 32'hDEADBEEF, 3'b010);
        repeat (2) @(negedge hclk);
        ahb_read(32'h10, rd);
        chk("HEARTBEAT word write", rd, 32'hDEADBEEF);

        // === 6. 写 SCRATCH 字节使能（AHB：数据须放在被寻址字节通道）===
        ahb_write(32'h14, 32'h00000011, 3'b000 /*byte0*/);   // byte0=0x11
        repeat (2) @(negedge hclk);
        ahb_read(32'h14, rd);
        chk("SCRATCH byte0 write", rd, 32'h00000011);

        ahb_write(32'h15, 32'h0000AA00, 3'b000 /*byte1，数据在 byte1*/);
        repeat (2) @(negedge hclk);
        ahb_read(32'h14, rd);
        chk("SCRATCH byte1 merge (0xAA<<8)", rd, 32'h0000AA11);

        ahb_write(32'h16, 32'h00FF0000, 3'b000 /*byte2，数据在 byte2*/);
        repeat (2) @(negedge hclk);
        ahb_read(32'h14, rd);
        chk("SCRATCH byte2 merge (0xFF<<16)", rd, 32'h00FFAA11);

        ahb_write(32'h14, 32'h00007777, 3'b001 /*halfword low，数据在 bytes1:0*/);
        repeat (2) @(negedge hclk);
        ahb_read(32'h14, rd);
        chk("SCRATCH halfword low merge (bytes1:0=0x7777)", rd, 32'h00FF7777);

        // === 7. BALL_NOW @0x54 ===
        ahb_write(32'h54, 32'd5, 3'b010);
        repeat (2) @(negedge hclk);
        ahb_read(32'h54, rd);
        chk("BALL_NOW readback", rd, 32'd5);

        // === 8. 未映射地址读 = 0 ===
        ahb_read(32'h3C, rd);
        chk("unmapped read", rd, 32'h0);

        // === 8. hreadyout/hresp 恒定 ===
        chk("hreadyout always 1", hreadyout, 1'b1);
        chk("hresp always OKAY", hresp, 2'b00);

        $display("\n== %0d PASS, %0d FAIL ==", npass, nfail);
        $finish(nfail == 0 ? 0 : 1);
    end

    initial begin #200000 $display("TIMEOUT"); $finish(1); end
endmodule
