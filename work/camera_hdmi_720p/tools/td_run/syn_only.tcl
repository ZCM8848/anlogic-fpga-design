# ============================================================================
# syn_only.tcl - fast area/timing measurement: elaborate -> optimize_rtl ->
#   optimize_gate only (no place/route/bitgen). ~5 min vs ~18 min full build.
#   Use for A/B comparing RTL/resource changes.
#
# MUST run with CWD = td_project/  (the .al XML relative paths resolve from CWD).
#   cd work/camera_hdmi_720p/td_project
#   D:\Tangdynasty\bin\td_commands_prompt.exe ../tools/td_run/syn_only.tcl
# ============================================================================

import_device ph1_35p.db -package PH1P35MDG324 -speed 3
open_project camera_hdmi_720p.al
elaborate -top design_top_wrapper

read_adc  ../constraints/pin.adc
read_ip_adc -ip ddr2 -file ../ip/ddr2/ddr2/src/adc/ddr2.adc
read_sdc  ../constraints/timing.sdc
read_sdc  -ip ddr2 ../ip/ddr2/ddr2/src/sdc/ddr2.sdc

insert_debugger
optimize_rtl
report_area -file camera_hdmi_720p_rtl.area
optimize_gate -packarea camera_hdmi_720p_gate.area
legalize_phy_inst
update_timing
report_timing_status -file camera_hdmi_720p_gate.ts
flow_status -file syn_flow.status
