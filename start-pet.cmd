@echo off
rem Start the multi-source desk pet (comment kept ASCII: cmd reads this file as the OEM codepage).
rem Only one pet ever runs: it holds 127.0.0.1:47321, and takes over the plugin pet if that one is up.
setlocal
rem Collector port for remote sources. Change it here AND in ~/.ssh/config (RemoteForward) together.
set DESK_PET_PORT=47355
set PY=%USERPROFILE%\anaconda3\pythonw.exe
if not exist "%PY%" set PY=pythonw.exe
start "" "%PY%" "%~dp0pet\pet-multi.pyw" "%USERPROFILE%\.claude\desk-pet"
rem Dedicated reverse tunnel for remote sources. Needs ~/.ssh/desk-pet-tunnel authorized on the
rem remote (see README); the watchdog gives up by itself if it is not, so this line is safe either way.
if exist "%USERPROFILE%\.ssh\desk-pet-tunnel" start "" "%PY%" "%~dp0tunnel\tunnel.pyw" desk-pet-remote "%USERPROFILE%\.claude\desk-pet"
endlocal
