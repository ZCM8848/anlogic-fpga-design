/*
 * ph1p35_status — MCU 接管状态上报（B6 固件，B8 修正 printf 链接）
 * ============================================================
 * 仓库版本控制快照。FD 编译的 live 版在 FD workspace：
 *   C:\Users\Z___C\FDWork\ph1p35_status\main.c
 *
 * AL_LOG 走 al_simp_printf（不是 anl_printf；anl_printf 不在链接 lib 里）。
 * al_simp_printf 支持 %d/%x（%x 输出大写 hex），但不支持 %0Nx 宽度限定符。
 * 故 hex 字段用自写 putx（零填充定宽，经 al_simp_putchar 输出），%d 留给 flag。
 *
 * 从 fabric AHB 窗口 0x80000000 读 ahb_status_slave，用 UART0 复现原 status_report.v：
 *   CAM ID=<4hex> OK=<0/1> E=<0/1> CFG=<0/1> DDR=<0/1> SW4=<0/1> SW3=<0/1> CV=<0/1> NB=<2hex> TH=<2hex>\r\n
 */
#include <stdio.h>
#include <stdint.h>
#include "al_core.h"

/* al_simp_printf 在 lib/log 里、AL_LOG 内部用它（已链接）。al_simp_putchar 同 .c，
   但头里只声明了 al_simp_printf，故 al_simp_putchar 用 extern。 */
extern int  al_simp_printf(const char *format, ...);
extern void al_simp_putchar(char c);

#define AHB_STATUS_BASE  0x80000000UL
#define CAM_REG     (*(volatile uint32_t *)(AHB_STATUS_BASE + 0x00))
#define CV_REG      (*(volatile uint32_t *)(AHB_STATUS_BASE + 0x04))
#define FRAME_REG   (*(volatile uint32_t *)(AHB_STATUS_BASE + 0x08))
#define VER_REG     (*(volatile uint32_t *)(AHB_STATUS_BASE + 0x0C))
#define HEARTBEAT   (*(volatile uint32_t *)(AHB_STATUS_BASE + 0x10))

#define VER_MAGIC   0x4D435601U

/* al_simp_printf 不支持 %0Nx，自写零填充 hex 输出（大写）*/
static void putx(uint32_t val, int width)
{
    char b[8];
    int k;
    static const char hex[] = "0123456789ABCDEF";
    for (k = width - 1; k >= 0; k--) { b[k] = hex[val & 0xF]; val >>= 4; }
    for (k = 0; k < width; k++) al_simp_putchar(b[k]);
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
        al_simp_printf("ahb_status_slave NOT found (ver=");
        putx(ver, 8);
        al_simp_printf(")\r\n");
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

        al_simp_printf("CAM ID=");
        putx(cam_id, 4);
        al_simp_printf(" OK=%d E=%d CFG=%d DDR=%d SW4=%d SW3=%d CV=%d NB=", ok, err, cfg, ddr, sw4, sw3, cvon);
        putx(blob, 2);
        al_simp_printf(" TH=");
        putx(thr, 2);
        al_simp_printf("\r\n");

        HEARTBEAT = ++hb;
        delay_ms(500);
    }

    return 0;
}
