@echo off
chcp 65001 >nul
setlocal

where powershell >nul 2>nul
if errorlevel 1 goto nops

start "" /min powershell -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0pet-hud.ps1"
exit /b 0

:nops
echo 没找到 powershell.exe。
pause
exit /b 1
