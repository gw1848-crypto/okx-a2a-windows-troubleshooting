@echo off
setlocal

if /I "%~1"=="stop" goto blocked
if /I "%~1"=="restart" goto blocked
if /I "%~1"=="update" goto blocked
if /I "%~1"=="setup" goto blocked
if /I "%~1"=="daemon" if /I "%~2"=="stop" goto blocked
if /I "%~1"=="daemon" if /I "%~2"=="restart" goto blocked

call "%APPDATA%\npm\okx-a2a.cmd" %*
exit /b %ERRORLEVEL%

:blocked
echo Blocked in an inbound A2A session: runtime maintenance cannot control its own daemon. 1>&2
exit /b 77
