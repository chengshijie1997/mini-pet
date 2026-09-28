@echo off
chcp 65001 >nul
setlocal
set "PORT=8787"
set "NODE="

where node >nul 2>nul && set "NODE=node"
if defined NODE goto run

for /d %%D in ("%LOCALAPPDATA%\OpenAI\Codex\runtimes\cua_node\*") do if exist "%%D\bin\node.exe" set "NODE=%%D\bin\node.exe"
if not defined NODE goto nonode

:run
echo 正在启动 Mini · 虚拟宠物 ...
start "" http://127.0.0.1:%PORT%/
"%NODE%" "%~dp0server.js"
pause
exit /b 0

:nonode
echo 没有找到 Node.js，请先安装 Node，或在脚本里指定 node.exe 的路径。
pause
exit /b 1
