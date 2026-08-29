@echo off
rem One-click start for the radar track viewer (port 5180)
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1"
pause
