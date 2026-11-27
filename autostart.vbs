' Desk pet autostart: run start-pet.cmd with no console flash (0 = hidden window).
' Comments kept ASCII on purpose: wscript reads .vbs as ANSI, and a UTF-8 BOM can break it.
' No settings live here -- the port and the python path stay in start-pet.cmd alone.
' "auto" tells start-pet.cmd this is an unattended start, so it leaves the "off" marker alone.
Dim sh, here
Set sh = CreateObject("WScript.Shell")
here = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
sh.Run """" & here & "start-pet.cmd"" auto", 0, False
