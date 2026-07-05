@echo off
setlocal EnableExtensions
set "maintenance="
set "target="

if /I "%~1"=="install" set "maintenance=1"
if /I "%~1"=="i" set "maintenance=1"
if /I "%~1"=="update" set "maintenance=1"
if /I "%~1"=="uninstall" set "maintenance=1"

for %%A in (%*) do (
  echo %%~A| %SystemRoot%\System32\findstr.exe /I /C:"@okxweb3/a2a-node" >nul && set "target=1"
)

if defined maintenance if defined target (
  echo Blocked in an inbound A2A session: update the A2A package from a separate maintenance shell. 1>&2
  exit /b 77
)

call "%ProgramFiles%\nodejs\npm.cmd" %*
exit /b %ERRORLEVEL%
