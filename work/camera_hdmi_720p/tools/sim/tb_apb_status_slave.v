`timescale 1ns / 1ps
//=============================================================================
// tb_apb_status_slave.v — apb_status_slave RTL 仿真（iverilog）
//   驱动 APB 主机侧做读/写事务，检查只读寄存器打包、写寄存器字节合并、
//   vsync 帧计数、未映射地址回 0、pready/pslverr。
//   自检：每项 PASS/FAIL，末尾汇总；FAIL 时 $finish(1)。
//=============================================================================
module tb_apb_status_slave;

    reg         apb_clk = 0;
    reg         apb_rst_n = 0;
    reg  [19:0] paddr = 0;
    reg         psel = 0, penable = 0, pwrite = 0;
    reg  [31:0] pwdata = 0;
    reg  [3:0]  pstrobe = 0;
    reg  [2:0]  pprot = 0;
    wire [31:0] prdata;
    wire        pready, pslverr;

    // 状态输入
    reg [15:0] cam_id = 0; reg cam_id_ok=0, cam_i2c_err=0, cam_cfg_done=0;
    reg        ddr_rdy=0, sw4=0, sw3=0, cv_on=0;
    reg [5:0]  blob_cnt=0; reg [7:0] bin_thr=0; reg [10:0] run_cnt=0;
    reg        ccl_busy=0, run_overflow=0;
    reg        vsync = 0;
    wire [31:0] heartbeat, scratch, frame_cnt;

    integer npass = 0, nfail = 0;

    apb_status_slave #(.VER(32'h4D435601)) DUT (
        .I_apb_clk(apb_clk), .I_apb_rst_n(apb_rst_n),
        .I_paddr(paddr), .I_psel(psel), .I_penable(penable), .I_pwrite(pwrite),
        .I_pwdata(pwdata), .I_pstrobe(pstrobe), .I_pprot(pprot),
        .O_prdata(prdata), .O_pready(pready), .O_pslverr(pslverr),
        .I_cam_id(cam_id), .I_cam_id_ok(cam_id_ok), .I_cam_i2c_err(cam_i2c_err),
        .I_cam_cfg_done(cam_cfg_done), .I_ddr_rdy(ddr_rdy),
        .I_sw4(sw4), .I_sw3(sw3), .I_cv_on(cv_on), .I_blob_cnt(blob_cnt),
        .I_bin_thr(bin_thr), .I_run_cnt(run_cnt),
        .I_ccl_busy(ccl_busy), .I_run_overflow(run_overflow),
        .I_vsync(vsync),
        .O_heartbeat(heartbeat), .O_scratch(scratch), .O_frame_cnt(frame_cnt)
    );

    always #5 apb_clk = ~apb_clk;   // 100MHz

    // ---- APB 读任务：setup 拍 + access 拍，access 末采 prdata ----
    task apb_read(input [19:0] a, output [31:0] d);
    begin
        @(negedge apb_clk);
        psel=1'b1; penable=1'b0; pwrite=1'b0; paddr=a;
        @(negedge apb_clk);          // access 相
        penable=1'b1;
        @(posedge apb_clk);          // prdata 已稳定（setup 时已锁存）
        #1 d = prdata;               // 留一点布线延迟后采样
        @(negedge apb_clk);
        psel=1'b0; penable=1'b0;
    end
    endtask

    // ---- APB 写任务 ----
    task apb_write(input [19:0] a, input [31:0] d, input [3:0] strb);
    begin
        @(negedge apb_clk);
        psel=1'b1; penable=1'b0; pwrite=1'b1; paddr=a; pwdata=d; pstrobe=strb;
        @(negedge apb_clk);
        penable=1'b1;                // access：写落寄存器
        @(negedge apb_clk);
        psel=1'b0; penable=1'b0; pwrite=1'b0; pstrobe=4'h0;
    end
    endtask

    task chk(input [127:0] name, input [31:0] got, input [31:0] exp);
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
        // 复位
        apb_rst_n = 0;
        repeat (4) @(posedge apb_clk);
        @(negedge apb_clk); apb_rst_n = 1;

        // === 用例1：VER_REG ===
        apb_read(20'h0C, rd);
        chk("VER_REG", rd, 32'h4D435601);

        // === 用例2：CAM_REG 打包 ===
        cam_id=16'h9E4B; cam_id_ok=1; cam_i2c_err=0; cam_cfg_done=1;
        ddr_rdy=1; sw4=1; sw3=0; cv_on=0; blob_cnt=6'd3;
        exp_cam = {16'h9E4B, 1'b1, 1'b0, 1'b1, 1'b1, 1'b1, 1'b0, 1'b0, 3'b000, 6'd3};
        apb_read(20'h00, rd);
        chk("CAM_REG", rd, exp_cam);

        // === 用例3：CV_REG 打包 ===
        bin_thr=8'h5B; run_cnt=11'h140; ccl_busy=1; run_overflow=0;
        exp_cv = {8'h5B, 1'b0, 11'h140, 1'b1, 1'b0, 1'b0, frame_cnt[7:0]};
        apb_read(20'h04, rd);
        chk("CV_REG", rd, exp_cv);

        // === 用例4：帧计数——vsync 上升沿 ===
        // vsync 高 1 拍再低；2FF 同步后第 3 拍出上升沿 → frame_cnt+1
        @(negedge apb_clk); vsync=1; @(negedge apb_clk); vsync=0;
        repeat (2) @(negedge apb_clk);
        chk("frame_cnt after 1 vsync", frame_cnt, 32'd1);
        // 再 3 次
        repeat (3) begin
            @(negedge apb_clk); vsync=1; @(negedge apb_clk); vsync=0;
            repeat (2) @(negedge apb_clk);
        end
        chk("frame_cnt after 4 vsyncs", frame_cnt, 32'd4);
        apb_read(20'h08, rd);
        chk("FRAME_REG readback", rd, 32'd4);

        // === 用例5：写 HEARTBEAT 全字 ===
        apb_write(20'h10, 32'hDEADBEEF, 4'hF);
        apb_read(20'h10, rd);
        chk("HEARTBEAT full write", rd, 32'hDEADBEEF);
        chk("O_heartbeat out", heartbeat, 32'hDEADBEEF);

        // === 用例6：写 SCRATCH 字节使能 ===
        apb_write(20'h14, 32'h0000_AA00, 4'h2);  // 只 byte1
        apb_read(20'h14, rd);
        chk("SCRATCH byte1 only", rd, 32'h0000_AA00);
        apb_write(20'h14, 32'hFF00_0000, 4'h8);  // 只 byte3 合并
        apb_read(20'h14, rd);
        chk("SCRATCH byte3 merge", rd, 32'hFF00_AA00);

        // === 用例7：未映射地址读 = 0 ===
        apb_read(20'h3C, rd);
        chk("unmapped addr", rd, 32'h0);

        // === 用例8：pready/pslverr 恒定 ===
        chk("pready always 1", pready, 1'b1);
        chk("pslverr always 0", pslverr, 1'b0);

        $display("\n== %0d PASS, %0d FAIL ==", npass, nfail);
        if (nfail == 0) $display("ALL PASS");
        else $display("HAS FAIL");
        $finish(nfail == 0 ? 0 : 1);
    end

    // 防止死循环
    initial begin
        #100000 $display("TIMEOUT"); $finish(1);
    end

endmodule
