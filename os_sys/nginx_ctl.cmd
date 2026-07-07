@echo OFF
::=============================================================================
:: nginx_ctl.cmd - Nginx Service Control Script
::=============================================================================
:: Description : Start, stop, restart, reload, or check status of Nginx
:: Usage       : nginx_ctl.cmd [start|stop|restart|reload|status]
:: Author      : System Administrator
:: Created     : 2026-07-06
::=============================================================================

setlocal

if "%~1"=="__init" (
    set "CMD_ARG=%~2"
    goto init
)
set "CMD_ARG=%~1"
call "%~dpnx0" __init %*
endlocal
exit /b %errorlevel%

:init

:: Configuration
set NGINX_HOME=d:\inetd\nginx
set NGINX_DATA=d:\data\nginx
set NGINX_LOG=d:\archive\logs\nginx

:: System Utilities
set TASKLIST=%SystemRoot%\System32\tasklist.exe
set TASKKILL=%SystemRoot%\System32\taskkill.exe
set TIMEOUT=%SystemRoot%\System32\timeout.exe
set FIND=%SystemRoot%\System32\find.exe

:: Validate NGINX_HOME exists
if not exist "%NGINX_HOME%\nginx.exe" (
    echo ERROR: nginx.exe not found in %NGINX_HOME%
    exit /b 1
)

:: Ensure log directory exists
if not exist "%NGINX_LOG%" mkdir "%NGINX_LOG%" 2>nul

:: Change to Nginx home directory
cd /d "%NGINX_HOME%"

:: Parse command line argument
if /i "%CMD_ARG%"=="start" goto start
if /i "%CMD_ARG%"=="stop" goto stop
if /i "%CMD_ARG%"=="restart" goto restart
if /i "%CMD_ARG%"=="reload" goto reload
if /i "%CMD_ARG%"=="status" goto status

:: Display usage if no valid argument provided
echo Usage: %~nx0 [start^|stop^|restart^|reload^|status]
exit /b 1

::-----------------------------------------------------------------------------
:: START - Start the Nginx server if not already running
::-----------------------------------------------------------------------------
:start
call :is_running
if not errorlevel 1 (
    echo nginx is already running
    exit /b 0
)
echo Starting nginx web proxy
echo [%DATE% %TIME%] Starting nginx >> "%NGINX_LOG%\nginx_ctl.log"
call :do_start
goto end

::-----------------------------------------------------------------------------
:: STOP - Stop the Nginx server if currently running
::-----------------------------------------------------------------------------
:stop
call :is_running
if errorlevel 1 (
    echo nginx is not running
    exit /b 0
)
echo Stopping nginx web proxy
echo [%DATE% %TIME%] Stopping nginx >> "%NGINX_LOG%\nginx_ctl.log"
call :do_stop
goto end

::-----------------------------------------------------------------------------
:: RESTART - Stop and start Nginx
::-----------------------------------------------------------------------------
:restart
echo Restarting nginx web proxy
echo [%DATE% %TIME%] Restarting nginx >> "%NGINX_LOG%\nginx_ctl.log"
call :do_stop
%TIMEOUT% /t 2 /nobreak >nul
call :do_start
goto end

::-----------------------------------------------------------------------------
:: RELOAD - Reload Nginx configuration without stopping
::-----------------------------------------------------------------------------
:reload
call :is_running
if errorlevel 1 (
    echo nginx is not running
    exit /b 1
)
echo Reloading nginx configuration
echo [%DATE% %TIME%] Reloading nginx configuration >> "%NGINX_LOG%\nginx_ctl.log"
"%NGINX_HOME%\nginx" -s reload
goto end

::-----------------------------------------------------------------------------
:: STATUS - Check if Nginx is running and display PID
::-----------------------------------------------------------------------------
:status
for /f "tokens=2" %%p in ('%TASKLIST% /FI "IMAGENAME eq nginx.exe" /NH 2^>nul ^| %FIND% /I "nginx.exe"') do (
    echo nginx is running [PID: %%p]
    exit /b 0
)
echo nginx is not running
exit /b 1

::-----------------------------------------------------------------------------
:: INTERNAL FUNCTIONS
::-----------------------------------------------------------------------------
:is_running
%TASKLIST% /FI "IMAGENAME eq nginx.exe" 2>nul | %FIND% /I "nginx.exe" >nul
exit /b %errorlevel%

:do_start
start "" /MIN "%NGINX_HOME%\nginx"
exit /b 0

:do_stop
start "" /MIN "%NGINX_HOME%\nginx" -s stop
%TIMEOUT% /t 5 /nobreak >nul
%TASKKILL% /F /IM nginx.exe >nul 2>&1
del "%NGINX_DATA%\var\nginx.pid" 2>nul
exit /b 0

::-----------------------------------------------------------------------------
:: END - Clean exit
::-----------------------------------------------------------------------------
:end
endlocal
