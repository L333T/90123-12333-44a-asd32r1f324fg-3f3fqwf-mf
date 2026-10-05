@echo off
title AmeisenNav (HTTP 127.0.0.1:47110 -^> TCP 47111)
cd /d "%~dp0"

tasklist /FI "IMAGENAME eq AmeisenNavigationServer.exe" 2>nul | find /I "AmeisenNavigationServer.exe" >nul
if %errorlevel%==0 (
    echo AmeisenNavigationServer.exe is already running.
    echo Close that window first if you want a clean restart.
    echo.
    pause
    exit /b 0
)

netstat -ano -p TCP | find "127.0.0.1:47111" | find "LISTENING" >nul
if %errorlevel%==0 (
    echo Port 47111 is in use:
    netstat -ano -p TCP | find "127.0.0.1:47111" | find "LISTENING"
    echo.
    pause
    exit /b 1
)

netstat -ano -p TCP | find "127.0.0.1:47110" | find "LISTENING" >nul
if %errorlevel%==0 (
    echo Port 47110 is in use:
    netstat -ano -p TCP | find "127.0.0.1:47110" | find "LISTENING"
    echo.
    pause
    exit /b 1
)

if not exist "mmaps\000.mmap" (
    echo Missing mmaps\000.mmap - run the hardlink setup first.
    echo.
    pause
    exit /b 1
)

start "AmeisenNavigation TCP 47111" /D "%~dp0" "AmeisenNavigationServer.exe" "%~dp0config.cfg"

echo Waiting for AmeisenNavigationServer on 127.0.0.1:47111 ...
set /a _tries=0
:wait_tcp
netstat -ano -p TCP | find "127.0.0.1:47111" | find "LISTENING" >nul
if %errorlevel%==0 goto tcp_ready
set /a _tries+=1
if %_tries% GEQ 40 (
    echo Server did not start listening on 47111.
    echo Check the "AmeisenNavigation TCP 47111" window for the error.
    echo.
    pause
    exit /b 1
)
timeout /t 1 /nobreak >nul
goto wait_tcp

:tcp_ready
echo TCP server is up. Starting HTTP bridge on 127.0.0.1:47110
echo Leave this window open while you play. Ctrl+C stops the bridge.
echo.
py -3 "%~dp0http_bridge.py"
echo.
echo Bridge exited. Press any key to close.
pause >nul
