@echo off
setlocal
set "PATH=%ProgramFiles%\nodejs;%APPDATA%\npm;%USERPROFILE%\.local\bin;%PATH%"

if /I "%~1"=="stop" goto blocked
if /I "%~1"=="restart" goto blocked
if /I "%~1"=="update" goto blocked
if /I "%~1"=="setup" goto blocked
if /I "%~1"=="daemon" if /I "%~2"=="stop" goto blocked
if /I "%~1"=="daemon" if /I "%~2"=="restart" goto blocked

if /I "%~1"=="xmtp-send" (
  echo %*| %SystemRoot%\System32\findstr.exe /I /C:"auth fail" /C:"jwt" /C:"authentication" /C:"stderr" /C:"stack trace" >nul && goto sensitive
)

call "%APPDATA%\npm\okx-a2a.cmd" %*
exit /b %ERRORLEVEL%

:blocked
echo Blocked in an inbound A2A session: runtime maintenance cannot control its own daemon. 1>&2
exit /b 77

:sensitive
echo Blocked in an inbound A2A session: internal diagnostics must not be sent to a peer. 1>&2
exit /b 78
