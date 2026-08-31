@echo off
rem Launch the nozzle maintenance UI.
rem The console window flashes briefly, then closes. Use the .vbs launcher to avoid that.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0NozzleCheckUI.ps1"
exit
