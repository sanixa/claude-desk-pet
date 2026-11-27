@echo off
rem Start the multi-source desk pet (comment kept ASCII: cmd reads this file as the OEM codepage).
rem Only one pet ever runs: it holds 127.0.0.1:47321, and takes over the plugin pet if that one is up.
rem
rem Called with "auto" (from autostart.vbs / the scheduled task) it respects the "off" marker that
rem the pet's quit menu leaves behind. Called by hand it clears that marker: starting it on purpose
rem is how you say "I want it back".
setlocal
set OFF=%USERPROFILE%\.claude\desk-pet\off
if /i "%~1"=="auto" (
  if exist "%OFF%" exit /b 0
) else (
  if exist "%OFF%" del "%OFF%" >nul 2>&1
)
rem Collector port for remote sources. Change it here AND in ~/.ssh/config (RemoteForward) together.
set DESK_PET_PORT=47355
set PY=%USERPROFILE%\anaconda3\pythonw.exe
if not exist "%PY%" set PY=pythonw.exe
start "" "%PY%" "%~dp0pet\pet-multi.pyw" "%USERPROFILE%\.claude\desk-pet"
rem Dedicated reverse tunnel for remote sources. Needs ~/.ssh/desk-pet-tunnel authorized on the
rem remote (see RUNBOOK); the watchdog gives up by itself if it is not, so this line is safe either way.
if exist "%USERPROFILE%\.ssh\desk-pet-tunnel" start "" "%PY%" "%~dp0tunnel\tunnel.pyw" desk-pet-remote "%USERPROFILE%\.claude\desk-pet"
endlocal
