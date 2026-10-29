$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "== selftest =="
python "$here\fpga_cv_sim.py" --selftest

Write-Host "== full clip, machine view (MASK_VIEW=1) =="
python "$here\fpga_cv_sim.py"

Write-Host "== full clip, image view =="
python "$here\fpga_cv_sim.py" --view image

Write-Host "== block detector pipeline (exit count) =="
python "$here\blkdet_sim.py"
