#NoEnv  ; Recommended for performance and compatibility with future AutoHotkey releases.
; #Warn  ; Enable warnings to assist with detecting common errors.
SendMode Input  ; Recommended for new scripts due to its superior speed and reliability.



^!q:: ; Define the action for Ctrl + Alt + Q
{
    ; Insert "Deletions started." with a delay between each keystroke
    Send, Deletions started.
    Sleep, 50 ; Adjust the delay as needed
    Send, {Tab}
    Sleep, 50 ; Adjust the delay as needed
    Send, {Space}
    ; Optional: Prevent the original key combination from being sent
    Return
}

^!w:: ; Define the action for Ctrl + Alt + W
{
    ; Insert "Deletions completed." with a delay between each keystroke
    Send, Deletions completed.
    Sleep, 50 ; Adjust the delay as needed
    Send, {Tab}
    Sleep, 50 ; Adjust the delay as needed
    Send, {Space}
    ; Optional: Prevent the original key combination from being sent
    Return
}
