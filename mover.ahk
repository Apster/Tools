#NoEnv  ; Recommended for performance and compatibility with future AutoHotkey releases.
; #Warn  ; Enable warnings to assist with detecting common errors.
SendMode Input  ; Recommended for new scripts due to its superior speed and reliability.
SetWorkingDir %A_ScriptDir%  ; Ensures a consistent starting directory.

;create variable to check if the script is running
isRunning := false

;create hotkeys for starting and stopping the script
^!m::
    if (isRunning = false) {
        SetTimer, MoveMouse, 60000
        isRunning := true
    }
return

^!p::
    if (isRunning = true) {
        SetTimer, MoveMouse, off
        isRunning := false
    }
return

MoveMouse:
DllCall("mouse_event", uint, 1, int, -5, int, 0, uint, 0, int, 0)
DllCall("mouse_event", uint, 1, int, 5, int, 0, uint, 0, int, 0)
DllCall("mouse_event", uint, 2, int, 0, int, 0, uint, 0, int, 0)
return
#NoTrayIcon