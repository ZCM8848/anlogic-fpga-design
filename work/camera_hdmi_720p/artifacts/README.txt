camera_hdmi_720p SW2/K1 debug-display build
source: phy_1/camera_hdmi_720p.bit
commit: 66299be
MD5: 703565FF84763407253FD138C5AE949E
size: 1789539
saved: 2026-10-28 19:41

2) ball detection baseline after rollback to eccbbf2 (recompiled)
   file: camera_hdmi_720p_ball_eccbbf2_6D403127.bit
   source commit: eccbbf2 + revert b52e77d
   MD5: 6D4031278473F3EA560A4A227DAEB5F8

3) SW2/K1 debug-display build after restore to 66299be (recompiled)
   file: camera_hdmi_720p_sw2k1_restored_10928897.bit
   source commit: 66299be + revert-of-revert f987cf8
   MD5: 109288971337F87D5FF9B765D47198DF

4) SW1~SW4 serial status build
   bit: camera_hdmi_720p_swstat_159096EF.bit
   bit MD5: 159096EFED613A673579C9907473F7AC
   elf: ph1p35_status_swstat_49B4B4CF.elf
   elf MD5: 49B4B4CF323F6E0FE729E29285DF3173

5) BCD 7-seg + decimal HDMI count build
   bit: camera_hdmi_720p_bcd_7seg_B210DEC2.bit
   bit MD5: B210DEC27F0E0FCFE8484E6C1544677E
   elf: ph1p35_status_bcd_7seg_95C1D203.elf
   elf MD5: 95C1D203778197E09A013ED82BCAC154

6) Ball-counter layout + 4x scaled Count build
   bit: camera_hdmi_720p_ball_layout_08C07B70.bit
   bit MD5: 08C07B702088C5D135152D361060629E
   elf: ph1p35_status_bcd_7seg_95C1D203.elf (unchanged)
   elf MD5: 95C1D203778197E09A013ED82BCAC154
   layout: Logo (24,24); Count (24,638) 4x 160x28; OSD (24,172)
   timing: Setup WNS +0.247ns, Hold WNS +0.020ns, 17039 slices (80.31%)

7) Recognition UI + MiSans + frame counter build
   bit: camera_hdmi_720p_ui_misans_F9423A80.bit
   bit MD5: F9423A8058A162D056B6D7F6297252A1
   elf: ph1p35_status_bcd_7seg_95C1D203.elf (unchanged)
   elf MD5: 95C1D203778197E09A013ED82BCAC154
   UI: SW1=0 Logo + STEEL BALL + Count + Anlogic HX1P35A + FRAME; SW1=1 off
   timing: Setup WNS +0.211ns, Hold WNS +0.020ns, 16877 slices (79.55%)

8) Run-level params in AHB registers + skip counters
   bit: camera_hdmi_720p_run_cfg_5BE4E732.bit
   bit MD5: 5BE4E7320DB195E24EB9C12452E3557A
   elf: ph1p35_status_run_cfg_986FF3DC.elf
   elf MD5: 986FF3DC4B4437790F8440034DAC104B
   regs: 0x48 BALL_RUN_CFG (roi_y1/max_run_len), 0x4C SKIP_CNT
   timing: Setup WNS +0.115ns, Hold WNS +0.020ns, 17254 slices (81.33%)

9) KEY1 long-press count/track reset + HDMI count digit order fix
   bit: camera_hdmi_720p_k1_reset_countfix_4F26BAAC.bit
   bit MD5: 4F26BAACC794714569B336088B69144D
   elf: ph1p35_status_k1_reset_CF8E3B32.elf
   elf MD5: CF8E3B322051DD702B5848AC5239438B
   changes: KEY_EVT@0x50; K1 hold>=1s clears count+OV+BCD+tracks; HDMI digit order left=MSD
   timing: Setup WNS +0.120ns, Hold WNS +0.020ns, 17050 slices (80.36%)

10) K1 reset + tuned params bg_thr=80, roi_y1=180, merge_dist=20
   bit: camera_hdmi_720p_k1_reset_countfix_4F26BAAC.bit (unchanged)
   bit MD5: 4F26BAACC794714569B336088B69144D
   elf: ph1p35_status_k1_reset_tuned_45F994C3.elf
   elf MD5: 45F994C377AF3543579F1D19667F1B2C
   params: bg_thr=80, roi_y1=180, merge_dist=20; KEY_EVT@0x50 present
   timing: bit unchanged (Setup WNS +0.120ns, Hold WNS +0.020ns)

11) DETECTED N UI + all-visible-text MiSans
   bit: camera_hdmi_720p_detected_misans_49A22829.bit
   bit MD5: 49A228298A32F71A664C01A0DBAF4664
   elf: ph1p35_status_detected_misans_9944019C.elf
   elf MD5: 9944019CDA352C8A7F5E1AC03A38304A
   regs: 0x54 BALL_NOW [3:0] (MCU writes actual boxed-ball count oi)
   UI: SW1=0 shows DETECTED N at (24,204); editable via UI Layout Studio
   fonts: MiSans Medium for Count 30x34, ball ID 8x12, DETECTED 96x20+16x20,
          test pattern 288x20; existing label/text/frame unchanged MiSans
   sims: tb_ui_overlay, tb_count_order, tb_ahb_status_slave, tb_test_pattern,
         tb_cv_ball, tb_hdmi_logo all PASS
   timing: Setup WNS +0.103ns, Hold WNS +0.020ns, 16998 slices (80.12%),
           RAM 69/108, DSP 10/40, 0 violations

12) Gate line OSD + K2 background recapture + full-height gate
   bit: camera_hdmi_720p_gate_line_86D69468.bit
   bit MD5: 86D6946873657D004904B475C8BDA04B
   elf: ph1p35_status_gate_full_9AAF88CA.elf
   elf MD5: 9AAF88CA4C8A0DD0C95A796C48B4DD16
   regs: 0x58 SEG_CTRL, 0x5C BALL_GATE, KEY_EVT[1]=K2 long press
   UI: gate line #FF3366 at gate_x*4, y from gate_y0*4 to gate_y1*4
   params: gate_y0=0, gate_y1=180 (full height); K2 long press recaptures BG
   timing: Setup WNS +0.175ns, Hold WNS +0.020ns, 16981 slices (80.04%),
           RAM 69/108, DSP 10/40, 0 violations

13) MCU-controlled exposure/gain (AE=700, gain=144)
   bit: camera_hdmi_720p_ae_mcu_E93577E7.bit
   bit MD5: E93577E71A445D475698BA80A714343B
   elf: ph1p35_status_ae700_65A834DE.elf
   elf MD5: 65A834DE623EFF3523406DC899D8B2CA
   regs: 0x60 CAM_AE, 0x64 CAM_AG
   params: exposure=700 (半行, 约5.8ms), gain=144
   note: N2/J14 按键退休；后续只改 main.c 的 exposure/gain，无需重新综合
   timing: Setup WNS +0.140ns, Hold WNS +0.020ns, 16940 slices (79.85%),
           RAM 69/108, DSP 10/40, 0 violations

14) MCU gain=0 (minimum sensor gain)
   bit: camera_hdmi_720p_ae_mcu_E93577E7.bit (unchanged)
   bit MD5: E93577E71A445D475698BA80A714343B
   elf: ph1p35_status_gain0_5B491FC6.elf
   elf MD5: 5B491FC6397E5B2C208CB4A9281811B0
   params: exposure=700, gain=0
   note: ae_set clamps gain 0 -> 16; SC520GainTbl maps 16 to 1x minimum gain
   timing: bit unchanged (Setup WNS +0.140ns, Hold WNS +0.020ns)

15) gate_x=32
   bit: camera_hdmi_720p_ae_mcu_E93577E7.bit (unchanged)
   bit MD5: E93577E71A445D475698BA80A714343B
   elf: ph1p35_status_gate32_D970AA60.elf
   elf MD5: D970AA60B167CFEE8DCA34438769C4BF
   params: gate_x=32 -> full-res x=128; gate_y0=0, gate_y1=180
   note: BALL_GATE@0x5C is written at boot; gate line moves to x=128
   timing: bit unchanged (Setup WNS +0.140ns, Hold WNS +0.020ns)

16) restore pre-exposure camera settings
   bit: camera_hdmi_720p_ae_mcu_E93577E7.bit (unchanged)
   bit MD5: E93577E71A445D475698BA80A714343B
   elf: ph1p35_status_pre_exposure_F9B65FAE.elf
   elf MD5: F9B65FAE1F5494349273A13C74257BE0
   params: exposure=1991, gain=144 (same effective as before AE control)
   note: gate_x stays 32; only camera exposure/gain restored
   timing: bit unchanged (Setup WNS +0.140ns, Hold WNS +0.020ns)

17) field tuning: exposure=768, gain=64, max_area=2000, gate_x=100 (current)
   bit: camera_hdmi_720p_ae_mcu_E93577E7.bit (unchanged)
   bit MD5: E93577E71A445D475698BA80A714343B
   elf: ph1p35_status_tune_gate100_E6DFDDC8.elf
   elf MD5: E6DFDDC8E784C607C1192C3459FC97DF
   params: exposure=768, gain=64, max_area=2000, gate_x=100, gate_y0=0, gate_y1=180
   note: gate_x=100 -> full-res x=400; bit unchanged
   timing: bit unchanged (Setup WNS +0.140ns, Hold WNS +0.020ns)

18) Buzzer beep on ball crossing
   bit: camera_hdmi_720p_buzzer_981A0C97.bit
   bit MD5: 981A0C9761D1F4F3766567A544C146BC
   elf: ph1p35_status_buzzer_1EE84369.elf
   elf MD5: 1EE84369F98AC3F452CAF838FDB0034A
   regs: 0x68 BUZZ_CTRL, 0x6C BUZZ_CFG
   buzzer: 1 kHz, 50 ms, low-active, C12, SW5 hardware enable
   trigger: MCU flips BUZZ_CTRL[0] on gate count
   timing: Setup WNS +0.183ns, Hold WNS +0.020ns, 17278 slices (81.44%),
           RAM 69/108, DSP 10/40, 0 violations

19) Buzzer test song + MiSans attribution + key event gating
   bit: camera_hdmi_720p_buzzer_song_0A5A29B6.bit
   bit MD5: 0A5A29B62F7A80CD48AB30E497145C92
   elf: ph1p35_status_buzzer_song_7CB7577E.elf
   elf MD5: 7CB7577E94F0E78DD9F85C72A4B4E541
   features:
     - static test mode: K1 short toggles buzzer song play/pause (default paused)
     - test pattern adds "MiSans by Xiaomi" attribution below HDMI TEST text
     - K1/K2 long press only active in recognition mode (SW1=0)
     - buzzer output mux: recognition beep vs test song
   timing: Setup WNS +0.132ns, Hold WNS +0.020ns, 17403 slices (82.03%),
           RAM 71/108, DSP 10/40, 0 violations

20) Buzzer per-crossing queue + static-mode beep silencing (current)
   release: camera_hdmi_720p-v1.0.0
   bit: camera_hdmi_720p_buzzer_queue_AD9BB563.bit
   bit MD5: AD9BB56382EF350F0CD714EF752EFCC1
   elf: ph1p35_status_buzzer_queue_C2226280.elf
   elf MD5: C2226280E474EF5B847EB2673F95D91C
   features:
     - MCU queues one beep per gate crossing; spacing derived from beep_ms
     - static test mode: buzzer_beep forced silent via I_en, events not queued
     - test pattern includes "MiSans by Xiaomi" attribution
   timing: Setup WNS +0.158ns, Hold WNS +0.020ns, 17359 slices (81.82%),
           RAM 71/108, DSP 10/40, 0 violations
