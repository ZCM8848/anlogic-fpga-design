/*
 * ph1p35_status — MCU 接管状态上报（B6 固件）
 * ============================================================
 * 仓库版本控制快照。FD 编译的 live 版在 FD workspace：
 *   C:\Users\Z___C\FDWork\ph1p35_status\main.c
 * 改这份后请同步到 FD workspace（或让 FD 引用本文件）。
 *
 * 从 fabric AHB 窗口 0x80000000 读 ahb_status_slave 暴露的板级状态，
 * 用 UART0 (AL_LOG) 复现原 status_report.v 的串口行：
 *   CAM ID=<4hex> OK=<0/1> E=<0/1> CFG=<0/1> DDR=<0/1> SW4=<0/1> SW3=<0/1> CV=<0/1> NB=<2hex> TH=<2hex>\r\n
 * 每 ~500ms 一行；写 heartbeat 寄存器自证 MCU 活着。
 *
 * 寄存器映射（ahb_status_slave.v，AHB 窗口 0x80000000 + 偏移）：
 *   0x00 CAM_REG   [31:16]=cam_id [15]=id_ok [14]=i2c_err [13]=cfg_done
 *                  [12]=ddr_rdy [11]=sw4 [10]=sw3 [9]=cv_on [5:0]=blob_cnt
 *   0x04 CV_REG    [31:24]=bin_thr [21:11]=run_cnt [10]=ccl_busy [9]=run_overflow [7:0]=frame_cnt[7:0]
 *   0x08 FRAME_REG [31:0]=frame_cnt
 *   0x0C VER_REG   0x4D435601 ("MCV1") 魔术，供自检
 *   0x10 HEARTBEAT MCU 写
 */
#include <stdio.h>
#include <stdint.h>
#include "al_core.h"

#define AHB_STATUS_BASE  0x80000000UL
#define CAM_REG     (*(volatile uint32_t *)(AHB_STATUS_BASE + 0x00))
#define CV_REG      (*(volatile uint32_t *)(AHB_STATUS_BASE + 0x04))
#define FRAME_REG   (*(volatile uint32_t *)(AHB_STATUS_BASE + 0x08))
#define VER_REG     (*(volatile uint32_t *)(AHB_STATUS_BASE + 0x0C))
#define HEARTBEAT   (*(volatile uint32_t *)(AHB_STATUS_BASE + 0x10))

#define VER_MAGIC   0x4D435601U

/* 粗略延时：300MHz 核下 ~100k nop/loop ≈ 0.3ms，乘 ms 即可；只求"不刷屏"。
   若 BSP 有更准的 delay 可替换。 */
static void delay_ms(uint32_t ms)
{
    for (volatile uint32_t i = 0; i < ms * 100000U; i++) {
        __asm__ volatile("nop");
    }
}

int main(void)
{
    /* 自检：从口是否在线（读 VER_REG 应为魔术值） */
    uint32_t ver = VER_REG;
    if (ver != VER_MAGIC) {
        AL_LOG(AL_LOG_LEVEL_ERROR, "ahb_status_slave NOT found (ver=%08X)\r\n", ver);
        /* 不死循环：继续上报，让状态行也能看到（但 NB/TH 会是 0） */
    }

    uint32_t hb = 0;
    while (1) {
        uint32_t cam = CAM_REG;
        uint32_t cv  = CV_REG;

        uint32_t cam_id = (cam >> 16) & 0xFFFF;
        int ok  = (cam >> 15) & 1;
        int err = (cam >> 14) & 1;
        int cfg = (cam >> 13) & 1;
        int ddr = (cam >> 12) & 1;
        int sw4 = (cam >> 11) & 1;
        int sw3 = (cam >> 10) & 1;
        int cvon= (cam >>  9) & 1;
        int blob= cam & 0x3F;
        int thr = (cv >> 24) & 0xFF;

        AL_LOG(AL_LOG_LEVEL_NOTICE,
            "CAM ID=%04X OK=%d E=%d CFG=%d DDR=%d SW4=%d SW3=%d CV=%d NB=%02X TH=%02X\r\n",
            cam_id, ok, err, cfg, ddr, sw4, sw3, cvon, blob, thr);

        HEARTBEAT = ++hb;          /* 自证 MCU 活着 */
        delay_ms(500);
    }

    return 0;
}
