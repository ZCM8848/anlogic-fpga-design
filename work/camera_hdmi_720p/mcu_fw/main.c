/*
 * ph1p35_status — MCU 接管状态上报（B6 固件，B8 修正 printf）
 * ============================================================
 * 仓库版本控制快照。FD 编译的 live 版在 FD workspace：
 *   C:\Users\Z___C\FDWork\ph1p35_status\main.c
 * 改这份后请同步到 FD workspace。
 *
 * BSP 的 anl_printf 是极简实现：只支持 %c/%s/%d/%x（小写），不支持 %X/%04X/%02X
 * 宽度限定符。故 hex 字段用自写 putx（零填充定宽），%d 留给 flag 字段。
 *
 * 从 fabric AHB 窗口 0x80000000 读 ahb_status_slave，用 UART0 复现原 status_report.v：
 *   CAM ID=<4hex> OK=<0/1> E=<0/1> CFG=<0/1> DDR=<0/1> SW4=<0/1> SW3=<0/1> CV=<0/1> NB=<2hex> TH=<2hex>\r\n
 */
#include <stdio.h>
#include <stdint.h>
#include "al_core.h"
#include "anl_printf.h"

#define AHB_STATUS_BASE  0x80000000UL
#define CAM_REG     (*(volatile uint32_t *)(AHB_STATUS_BASE + 0x00))
#define CV_REG      (*(volatile uint32_t *)(AHB_STATUS_BASE + 0x04))
#define FRAME_REG   (*(volatile uint32_t *)(AHB_STATUS_BASE + 0x08))
#define VER_REG     (*(volatile uint32_t *)(AHB_STATUS_BASE + 0x0C))
#define HEARTBEAT   (*(volatile uint32_t *)(AHB_STATUS_BASE + 0x10))

#define VER_MAGIC   0x4D435601U

/* anl_printf 不支持 %0NX，自写零填充 hex 输出（大写）*/
static void putx(uint32_t val, int width)
{
    char b[8];
    int k;
    static const char hex[] = "0123456789ABCDEF";
    for (k = width - 1; k >= 0; k--) { b[k] = hex[val & 0xF]; val >>= 4; }
    for (k = 0; k < width; k++) anl_putchar(b[k]);
}

static void delay_ms(uint32_t ms)
{
    for (volatile uint32_t i = 0; i < ms * 100000U; i++) {
        __asm__ volatile("nop");
    }
}

int main(void)
{
    uint32_t ver = VER_REG;
    if (ver != VER_MAGIC) {
        anl_printf("ahb_status_slave NOT found (ver=");
        putx(ver, 8);
        anl_printf(")\r\n");
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

        anl_printf("CAM ID=");
        putx(cam_id, 4);
        anl_printf(" OK=%d E=%d CFG=%d DDR=%d SW4=%d SW3=%d CV=%d NB=", ok, err, cfg, ddr, sw4, sw3, cvon);
        putx(blob, 2);
        anl_printf(" TH=");
        putx(thr, 2);
        anl_printf("\r\n");

        HEARTBEAT = ++hb;
        delay_ms(500);
    }

    return 0;
}
