# ============================================================================
# build_full.tcl - full compile straight on camera_hdmi_720p.al
#   flow: elaborate -> optimize_rtl -> optimize_gate -> place -> route -> bitgen
#   No _Runs/ and no .prj needed (uses the .al directly).
#
# MUST run with CWD = td_project/  (the .al XML relative paths resolve from CWD).
#
#   cd work/camera_hdmi_720p/td_project
#   D:\Tangdynasty\bin\td_commands_prompt.exe ..\tools\td_run\build_full.tcl
#
# NOTE: divider is required by rtl/isp/awb.v. This checkout has NO
#   ip/divider/divider.ipc, so the .al must reference the generated netlist
#   ip/divider/divider_gate.v (module name is "divider").
# ============================================================================

import_device ph1_35p.db -package PH1P35MDG324 -speed 3
open_project camera_hdmi_720p.al
elaborate -top design_top_wrapper

# ---- constraints (IP scoped: -ip ddr2 needed for DDR pin/PHY constraints) ----
read_adc  ../constraints/pin.adc
read_ip_adc -ip ddr2 -file ../ip/ddr2/ddr2/src/adc/ddr2.adc
read_sdc  ../constraints/timing.sdc
read_sdc  -ip ddr2 ../ip/ddr2/ddr2/src/sdc/ddr2.sdc

# ---- synthesis ----
insert_debugger
optimize_rtl
report_area -file camera_hdmi_720p_rtl.area
optimize_gate -packarea camera_hdmi_720p_gate.area
legalize_phy_inst
update_timing
report_timing_status -file camera_hdmi_720p_gate.ts
flow_status -file syn_flow.status

# ---- place ----
place
update_timing -mode manhattan
report_area -io_info -file camera_hdmi_720p_phy.area
report_clock_utilization -file place_clock_utilization.txt
flow_status -file place_flow.status

# ---- route ----
route
update_timing -mode final
report_timing_status   -file camera_hdmi_720p_phy.ts
report_timing_summary  -file camera_hdmi_720p_pr.timing
report_timing_exception -file camera_hdmi_720p_exception.timing
report_clock_utilization -file route_clock_utilization.txt
flow_status -file route_flow.status

# ---- bitgen ----
bitgen -bit camera_hdmi_720p.bit
setup_debugger
