#Requires -Version 5.1
<#
.SYNOPSIS
    Keeps the workstation awake and Teams presence "Available" without holding
    the mouse button down.

.DESCRIPTION
    Rewrite of StorM.ps1. Behavioural differences from v1, in order of importance:

      1. No mouse button is held BY DEFAULT. v1 injected MOUSEEVENTF_LEFTDOWN and
         never sent a matching LEFTUP in ANY code path - not on pause, not on
         exit, not on kill. That is what leaves text highlighted and icons
         dragging. The default here is a 1px relative mouse move (out and back)
         via SendInput, which resets the idle timer with no button state at all.
         The held press is still available for A/B testing via the
         $LEFT_BUTTON_MODE toggle below, and unlike v1 it is released on pause,
         on exit, and as soon as you touch the mouse or keyboard again.

      2. Idle-driven, not timer-driven. v1 nudged every 60s unconditionally, even
         while you were actively typing. This one reads GetLastInputInfo and only
         nudges once you have actually been idle for -IdleThresholdSeconds. While
         you are working it does nothing at all.

      3. Single instance. A named mutex refuses a second copy. v1 had no guard,
         and because it is launched with -windowstyle Hidden a duplicate is
         invisible - two loops can desync and the Scroll Lock LED then lies
         about whether anything is still running.

      4. System-wide hotkeys via RegisterHotKey instead of polled GetKeyState.
         No missed keypresses between 100ms samples, and the Ctrl+Alt+M / P
         chord no longer leaks through to whatever app has focus.
         Falls back to GetAsyncKeyState polling if registration is refused.

      5. Guaranteed cleanup. try/finally releases any held button, clears the
         Scroll Lock indicator and drops the power request. Note this runs on
         Ctrl+C and on a quit request but NOT when the console window is closed
         with the X or the process is killed - which is exactly why the default
         holds no button in the first place.

      6. SetThreadExecutionState keeps the display and system awake directly,
         without relying on synthetic input. Verify with: powercfg /requests
         This does NOT affect Teams presence - that still needs real input.

      7. It logs. Every build before this one ran hidden and wrote nothing to
         disk, so a disappearance left no evidence whatsoever - and the three
         ways it can end are indistinguishable from outside. See -LogPath,
         -HeartbeatSeconds and -AllowAltGrCollision.

.PARAMETER IdleThresholdSeconds
    Nudge only after this many seconds with no user input. Default 50.

.PARAMETER Method
    Move (default) - 1px relative mouse move out and back, via SendInput.
    Key            - tap F15, an inert key with no default binding.
    Wheel          - a mouse wheel event with a zero delta. A real mouse event
                     that scrolls nothing and cannot activate a control. Use
                     this if a move turns out not to be enough.
    Both           - Move + Key.

    Measured 2026-08-06, idle-timer reset per method:
        SendInput move      resets      SendInput LEFTDOWN   resets
        SendInput wheel 0   resets      keybd_event F15      resets
        SetCursorPos        DOES NOT RESET   <- what v1 used for its move

.PARAMETER ClickHoldMs
    Escalation lever. 0 (default) means no mouse button is ever pressed.
    If a plain move turns out not to hold Teams off "Away" in this tenant, try
    50. That sends a real LEFTDOWN + LEFTUP pair, guaranteed released within
    ClickHoldMs. It is a real click, so the cursor position matters again.

.PARAMETER StartActive
    Begin armed instead of waiting for Ctrl+Alt+M.

.PARAMETER NoScrollLock
    Do not use the Scroll Lock LED as a state indicator.

.PARAMETER NoKeepAwake
    Do not issue the SetThreadExecutionState power request.

.PARAMETER PollMs
    Main loop interval. Default 100.

.PARAMETER StartKey
.PARAMETER PauseKey
.PARAMETER QuitKey
    Letter, digit or F-key to combine with Ctrl+Alt. Defaults M / P / none.

    QuitKey is empty by default. Nothing needs a quit hotkey - the tray menu
    quits - and a quit chord is the one misfire that cannot be undone. See
    -AllowAltGrCollision for what went wrong with the old L default.

    Hotkey survey on this machine, 2026-08-06:
      Ctrl+Alt+M, P  were owned by storage_mover.ahk - an older AutoHotkey
                     keep-awake with the same unreleased-LEFTDOWN bug. That
                     script has been retired, so M and P are free again and
                     register natively.
      Ctrl+Alt+Q, W  owned by pip_del_text.ahk, which TYPES "Deletions
                     started." + Tab + Space into the focused window. Do not
                     use Q as the quit key. Hence the L default.
      Ctrl+Alt+5, 6  owned by another AHK script.

.PARAMETER AllowAltGrCollision
    Register a chord even when AltGr+<key> is a real character on one of the
    installed keyboard layouts. Off by default, and off matters.

    RegisterHotKey's MOD_CONTROL|MOD_ALT does not distinguish left Alt from
    right, and AltGr is right-Alt plus a synthetic left-Ctrl. So on the Polish
    (Programmers) layout, typing the l-with-stroke IS Ctrl+Alt+L. Under the old
    -QuitKey L default that quit the script mid-sentence, hours into a session,
    through the normal exit path, leaving no trace of itself anywhere.

    A colliding QUIT chord is therefore refused outright. A colliding arm or
    pause chord only warns - a stray arm or pause is recoverable, a stray quit
    is not. Test a chord for yourself with Test-AltGrHotkey.ps1.

.PARAMETER LogPath
    Append-only log. Defaults to %LOCALAPPDATA%\StorM2\StorM2.log, rotated to
    .log.1 at 2 MB. Deliberately not under OneDrive - a heartbeat once a minute
    inside a synced folder is pure sync churn.

.PARAMETER NoLog
    Do not write the log file.

.PARAMETER HeartbeatSeconds
    Write a liveness line this often. Default 60, 0 disables.

    This is the only thing that can date a death the script cannot report
    itself - a kill, or the console closed with the X, neither of which reaches
    the finally block. The last HEARTBEAT line is the time of death. It also
    separates "the process died" from "the tray icon vanished": heartbeats
    continuing past the moment the icon disappeared means the icon went and the
    script did not.

.PARAMETER ShowConsole
    Keep the console window visible. By default the script hides its own
    console once startup is done, so it runs purely from the tray.

.PARAMETER NoTrayIcon
    Do not create the tray icon. With the console also hidden this leaves no
    UI at all, so the hotkeys become the only way to control it.

.EXAMPLE
    .\StorM2.ps1
    Ctrl+Alt+M arm, Ctrl+Alt+P pause, no quit chord - quit from the tray menu.
    No console, tray icon only: green dot armed, grey dot paused. Double-click
    toggles, right-click for the menu. Logs to %LOCALAPPDATA%\StorM2\StorM2.log.

.NOTES
    Launch it with -windowstyle Minimized rather than Hidden. Hidden gives you
    no feedback, no way to Ctrl+C, and hides duplicate instances.
#>
[CmdletBinding()]
param(
    [ValidateRange(5, 3600)] [int]    $IdleThresholdSeconds = 50,
    [ValidateSet('Move','Key','Wheel','Both')][string] $Method = 'Move',
    [ValidateRange(0, 1000)] [int]    $ClickHoldMs          = 0,
    [ValidateRange(25, 2000)][int]    $PollMs               = 100,
    [string] $StartKey = 'M',
    [string] $PauseKey = 'P',
    [string] $QuitKey  = '',
    [switch] $StartActive,
    [switch] $NoScrollLock,
    [switch] $NoKeepAwake,
    [switch] $ShowConsole,
    [switch] $NoTrayIcon,
    [switch] $AllowAltGrCollision,
    [string] $LogPath,
    [switch] $NoLog,
    [ValidateRange(0, 3600)][int] $HeartbeatSeconds = 60
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Native interop
# ---------------------------------------------------------------------------
if (-not ('StorM.Native' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace StorM {
    public static class Native {

        // ---- SendInput ----------------------------------------------------
        [StructLayout(LayoutKind.Sequential)]
        public struct MOUSEINPUT {
            public int dx; public int dy; public uint mouseData;
            public uint dwFlags; public uint time; public IntPtr dwExtraInfo;
        }
        [StructLayout(LayoutKind.Sequential)]
        public struct KEYBDINPUT {
            public ushort wVk; public ushort wScan;
            public uint dwFlags; public uint time; public IntPtr dwExtraInfo;
        }
        [StructLayout(LayoutKind.Explicit)]
        public struct INPUTUNION {
            [FieldOffset(0)] public MOUSEINPUT mi;
            [FieldOffset(0)] public KEYBDINPUT ki;
        }
        [StructLayout(LayoutKind.Sequential)]
        public struct INPUT { public uint type; public INPUTUNION u; }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

        private const uint INPUT_MOUSE = 0, INPUT_KEYBOARD = 1;
        private const uint MOUSEEVENTF_MOVE = 0x0001,
                           MOUSEEVENTF_LEFTDOWN = 0x0002,
                           MOUSEEVENTF_LEFTUP = 0x0004,
                           MOUSEEVENTF_WHEEL = 0x0800;
        private const uint KEYEVENTF_KEYUP = 0x0002;

        private static INPUT M(uint flags, int dx, int dy) {
            INPUT i = new INPUT();
            i.type = INPUT_MOUSE;
            i.u.mi.dx = dx; i.u.mi.dy = dy; i.u.mi.dwFlags = flags;
            return i;
        }
        private static INPUT K(ushort vk, bool up) {
            INPUT i = new INPUT();
            i.type = INPUT_KEYBOARD;
            i.u.ki.wVk = vk; i.u.ki.dwFlags = up ? KEYEVENTF_KEYUP : 0;
            return i;
        }
        private static uint Send(params INPUT[] items) {
            return SendInput((uint)items.Length, items, Marshal.SizeOf(typeof(INPUT)));
        }

        // Relative move, so no hardcoded screen size and no multi-monitor wrap.
        public static uint NudgeMouse() {
            return Send(M(MOUSEEVENTF_MOVE, 1, 0), M(MOUSEEVENTF_MOVE, -1, 0));
        }
        public static uint TapKey(ushort vk) { return Send(K(vk, false), K(vk, true)); }
        public static uint LeftDown()        { return Send(M(MOUSEEVENTF_LEFTDOWN, 0, 0)); }
        public static uint LeftUp()          { return Send(M(MOUSEEVENTF_LEFTUP,   0, 0)); }

        // A wheel event with a zero delta. Measured to reset the idle timer, but
        // scrolls nothing and cannot activate a control. This is a genuine mouse
        // button-class event without any of the risk of a held button.
        public static uint WheelNudge() {
            INPUT i = new INPUT();
            i.type = INPUT_MOUSE;
            i.u.mi.dwFlags = MOUSEEVENTF_WHEEL;
            i.u.mi.mouseData = 0;
            return Send(i);
        }

        // ---- key state ----------------------------------------------------
        [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int vKey);
        [DllImport("user32.dll")] private static extern short GetKeyState(int vKey);

        // Interrupt-level "is it down right now", independent of focus.
        public static bool IsDown(int vKey)    { return (GetAsyncKeyState(vKey) & 0x8000) != 0; }
        // Toggle bit for lock keys; GetKeyState is the correct API for this one.
        public static bool IsToggled(int vKey) { return (GetKeyState(vKey) & 0x0001) != 0; }

        // ---- idle time ----------------------------------------------------
        [StructLayout(LayoutKind.Sequential)]
        private struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
        [DllImport("user32.dll")] private static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

        public static uint IdleMilliseconds() {
            LASTINPUTINFO lii = new LASTINPUTINFO();
            lii.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
            if (!GetLastInputInfo(ref lii)) { return 0; }
            unchecked { return (uint)Environment.TickCount - lii.dwTime; }
        }

        // ---- system-wide hotkeys -------------------------------------------
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

        [StructLayout(LayoutKind.Sequential)]
        public struct MSG {
            public IntPtr hwnd; public uint message; public IntPtr wParam;
            public IntPtr lParam; public uint time; public int x; public int y;
        }
        [DllImport("user32.dll")]
        private static extern bool PeekMessage(out MSG lpMsg, IntPtr hWnd, uint min, uint max, uint remove);
        [DllImport("user32.dll")] private static extern bool TranslateMessage(ref MSG m);
        [DllImport("user32.dll")] private static extern IntPtr DispatchMessage(ref MSG m);

        private const uint MOD_ALT = 0x0001, MOD_CONTROL = 0x0002, MOD_NOREPEAT = 0x4000;
        private const uint WM_HOTKEY = 0x0312;
        private const uint PM_REMOVE = 0x0001;

        // hWnd = NULL posts WM_HOTKEY to this thread's queue, so no window needed.
        public static bool RegisterCtrlAlt(int id, uint vk) {
            return RegisterHotKey(IntPtr.Zero, id, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, vk);
        }
        public static bool Unregister(int id) { return UnregisterHotKey(IntPtr.Zero, id); }

        // Returns the next pending hotkey id, or 0 if none. Non-hotkey messages
        // are DISPATCHED, not discarded - the tray icon owns a hidden window on
        // this thread and stops responding if its messages are thrown away.
        // Returning early leaves the rest queued for the next call.
        public static int NextHotkeyId() {
            MSG m;
            while (PeekMessage(out m, IntPtr.Zero, 0, 0, PM_REMOVE)) {
                if (m.message == WM_HOTKEY) { return (int)m.wParam; }
                TranslateMessage(ref m);
                DispatchMessage(ref m);
            }
            return 0;
        }

        public static int LastError() { return Marshal.GetLastWin32Error(); }

        // ---- power ----------------------------------------------------------
        [DllImport("kernel32.dll")] private static extern uint SetThreadExecutionState(uint esFlags);
        private const uint ES_CONTINUOUS       = 0x80000000;
        private const uint ES_SYSTEM_REQUIRED  = 0x00000001;
        private const uint ES_DISPLAY_REQUIRED = 0x00000002;

        public static void KeepAwakeOn()  {
            SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED);
        }
        public static void KeepAwakeOff() { SetThreadExecutionState(ES_CONTINUOUS); }

        // ---- console window ---------------------------------------------------
        [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll")]   private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")]   private static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")]   public  static extern bool IsWindowVisible(IntPtr hWnd);
        private const int SW_HIDE = 0, SW_SHOW = 5;

        public static void HideConsole() {
            IntPtr h = GetConsoleWindow();
            if (h != IntPtr.Zero) { ShowWindow(h, SW_HIDE); }
        }
        public static void ShowConsole() {
            IntPtr h = GetConsoleWindow();
            if (h != IntPtr.Zero) { ShowWindow(h, SW_SHOW); SetForegroundWindow(h); }
        }
        public static bool ConsoleVisible() {
            IntPtr h = GetConsoleWindow();
            return h != IntPtr.Zero && IsWindowVisible(h);
        }

        // ---- AltGr collision detection ---------------------------------------
        [DllImport("user32.dll")]
        private static extern int GetKeyboardLayoutList(int nBuff, [Out] IntPtr[] lpList);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int ToUnicodeEx(uint wVirtKey, uint wScanCode, byte[] lpKeyState,
            System.Text.StringBuilder pwszBuff, int cchBuff, uint wFlags, IntPtr dwhkl);
        [DllImport("user32.dll")]
        private static extern uint MapVirtualKeyEx(uint uCode, uint uMapType, IntPtr dwhkl);

        // Every keyboard layout loaded for this session, not just the active one.
        // The active layout is irrelevant here - the question is what the user
        // COULD type at some point today.
        public static IntPtr[] Layouts() {
            int n = GetKeyboardLayoutList(0, null);
            if (n <= 0) { return new IntPtr[0]; }
            IntPtr[] list = new IntPtr[n];
            GetKeyboardLayoutList(n, list);
            return list;
        }

        // The character, if any, that AltGr+vk produces under one layout. AltGr
        // is right-Alt plus a synthetic left-Ctrl, so that is the key state to
        // ask about. Empty string means the chord produces no character there.
        public static string AltGrChar(uint vk, IntPtr hkl) {
            byte[] ks = new byte[256];
            ks[0x11] = 0x80; ks[0xA2] = 0x80;   // VK_CONTROL, VK_LCONTROL
            ks[0x12] = 0x80; ks[0xA5] = 0x80;   // VK_MENU,    VK_RMENU
            uint sc = MapVirtualKeyEx(vk, 0, hkl);   // MAPVK_VK_TO_VSC
            System.Text.StringBuilder sb = new System.Text.StringBuilder(8);
            int rc = ToUnicodeEx(vk, sc, ks, sb, sb.Capacity, 0, hkl);
            // ToUnicodeEx leaves any dead-key state pending inside the layout.
            // Tap it a second time to flush, or this diagnostic composes the
            // user's next real keystroke against a leftover dead key.
            System.Text.StringBuilder flush = new System.Text.StringBuilder(8);
            ToUnicodeEx(vk, sc, ks, flush, flush.Capacity, 0, hkl);
            if (rc > 0) { return sb.ToString(0, Math.Min(rc, sb.Length)); }
            if (rc < 0) { return "(dead key)"; }
            return "";
        }

        // Icons built from a Bitmap must be destroyed by hand or the handle leaks.
        [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr hIcon);
    }
}
'@
}

# ===========================================================================
#  EXPERIMENTAL TOGGLE - edit the value here.
#  Deliberately NOT a parameter, so a shortcut or scheduled task cannot switch
#  it on by accident. You have to open the file to change it.
# ===========================================================================
#
#  Holds the left mouse button DOWN with no matching UP, the way StorM.ps1 v1
#  did. It is a press, not a click, so it will not activate a button or a link
#  (controls fire on mouse-UP). What it WILL do is start a text selection or a
#  drag if the cursor happens to be over text or an icon.
#
#    'off'   default. No mouse button is ever pressed.
#    'add'   press and hold, IN ADDITION to the normal -Method nudge.
#    'only'  press and hold INSTEAD of the -Method nudge. Use this one for a
#            clean A/B - it isolates the button as the only input event, which
#            is effectively what v1 was doing.
#
#  Measured 2026-08-06 on this machine: SendInput mouse movement already resets
#  the Windows idle timer, so the button is NOT needed to prevent sleep. Note
#  that v1's SetCursorPos movement does NOT reset it - which is why v1 needed
#  the button. The open question this toggle exists to answer is whether Teams
#  presence needs more than a move. See also -Method Wheel: a real mouse event
#  with the same idle-reset effect and none of the drag risk.
#
$LEFT_BUTTON_MODE = 'off'      # 'off' | 'add' | 'only'

#  Release the held button as soon as genuine user input is detected, so you
#  never come back to the keyboard and find text selected. Does not affect the
#  experiment, which only runs while you are away.
$HOLD_AUTO_RELEASE = $true

# ===========================================================================

if (@('off','add','only') -notcontains $LEFT_BUTTON_MODE) {
    throw "LEFT_BUTTON_MODE must be 'off', 'add' or 'only' - got '$LEFT_BUTTON_MODE'."
}

# ---------------------------------------------------------------------------
# Constants and state
# ---------------------------------------------------------------------------
$VK_LBUTTON = 0x01
$VK_CONTROL = 0x11
$VK_MENU    = 0x12
$VK_F15     = 0x7E
$VK_SCROLL  = 0x91

$HK_START = 1
$HK_PAUSE = 2
$HK_QUIT  = 3

$script:Active       = $false
$script:ButtonHeld   = $false      # true only between our own LEFTDOWN and LEFTUP
$script:NudgeCount   = 0
$script:HotkeysOk    = $false
$script:Registered   = @()
$script:PrevCombo    = @{ $HK_START = $false; $HK_PAUSE = $false; $HK_QUIT = $false }
$script:LastNudgeAt  = [datetime]::MinValue
$script:EnabledIds   = @()         # chords actually in use after the AltGr guard
$script:ExitReason   = 'unknown'   # overwritten on every path that can speak
$script:StartedAt    = Get-Date
$script:LastBeatAt   = Get-Date
$script:ActionForId  = @{ $HK_START = 'arm'; $HK_PAUSE = 'pause'; $HK_QUIT = 'quit' }

$ThresholdMs = $IdleThresholdSeconds * 1000

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
# The script runs hidden, so every console message it has ever written went
# nowhere. That matters more than it sounds: from the outside, three completely
# different endings look identical - the quit hotkey, an unhandled error under
# $ErrorActionPreference = 'Stop' with no catch, and being killed. All three are
# a clean process exit with no Application Error entry and no WER report. Only a
# log tells them apart, so every path that can name itself now does, and the
# heartbeat dates the ones that cannot.
if (-not $LogPath) { $LogPath = Join-Path $env:LOCALAPPDATA 'StorM2\StorM2.log' }
$script:LogEnabled = -not $NoLog
$script:LogBroken  = $false
$MaxLogBytes = 2MB

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    if (-not $script:LogEnabled -or $script:LogBroken) { return }
    try {
        $dir = Split-Path -Parent $LogPath
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        # One rotation generation is enough to answer "it died overnight" the
        # next morning, without letting the file grow forever.
        $f = Get-Item -LiteralPath $LogPath -ErrorAction SilentlyContinue
        if ($f -and $f.Length -gt $MaxLogBytes) {
            Move-Item -LiteralPath $LogPath -Destination ($LogPath + '.1') -Force
        }
        $line = '{0:yyyy-MM-dd HH:mm:ss} {1,-5} pid={2} {3}{4}' -f `
                (Get-Date), $Level, $PID, $Message, [Environment]::NewLine
        # UTF-8 WITH a BOM. AppendAllText only emits the preamble when it creates
        # the file, so this costs 3 bytes once - and without it PowerShell 5.1's
        # Get-Content reads the log as ANSI and renders every non-ASCII character
        # wrong, which matters here because the characters are the evidence.
        [System.IO.File]::AppendAllText($LogPath, $line, (New-Object System.Text.UTF8Encoding($true)))
    } catch {
        # Logging must never be the thing that kills the script. One failure
        # disables it for the rest of the run rather than retrying 10x a second.
        $script:LogBroken = $true
    }
}

# Which physical modifiers are still down. Sampled when the message is dequeued,
# up to PollMs after the press, so a fast release reads as 'none' - a hint, not
# proof. RAlt without LAlt is the AltGr signature.
function Get-ModifierSnapshot {
    $m = @()
    if ([StorM.Native]::IsDown(0xA2)) { $m += 'LCtrl' }
    if ([StorM.Native]::IsDown(0xA3)) { $m += 'RCtrl' }
    if ([StorM.Native]::IsDown(0xA4)) { $m += 'LAlt'  }
    if ([StorM.Native]::IsDown(0xA5)) { $m += 'RAlt'  }
    if ($m.Count -eq 0) { return 'none' }
    return ($m -join '+')
}

function Write-ErrorLog {
    param($Record, [string]$Context)
    Write-Log ('{0}: {1}: {2}' -f $Context, $Record.Exception.GetType().FullName,
               $Record.Exception.Message) 'ERROR'
    try {
        Write-Log ('  {0}' -f (($Record.InvocationInfo.PositionMessage -replace '\s+', ' ').Trim())) 'ERROR'
        Write-Log ('  stack {0}' -f ($Record.ScriptStackTrace -replace '\r?\n', ' | ')) 'ERROR'
    } catch { }
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function ConvertTo-Vk {
    param([string]$Key)
    # Empty means "no chord for this action". Used to disable quit entirely,
    # which is the default now.
    if ([string]::IsNullOrWhiteSpace($Key)) { return 0 }
    $k = $Key.Trim().ToUpperInvariant()
    if ($k -match '^F([1-9]|1[0-9]|2[0-4])$') { return 0x70 + [int]$Matches[1] - 1 }
    if ($k -match '^[A-Z0-9]$')               { return [int][char]$k }
    throw "Unsupported key '$Key'. Use a single letter A-Z, a digit 0-9, or F1-F24."
}

$script:KeyName = @{ $HK_START = $StartKey.ToUpperInvariant()
                     $HK_PAUSE = $PauseKey.ToUpperInvariant()
                     $HK_QUIT  = $QuitKey.ToUpperInvariant() }
$script:KeyMap  = @{ $HK_START = (ConvertTo-Vk $StartKey)
                     $HK_PAUSE = (ConvertTo-Vk $PauseKey)
                     $HK_QUIT  = (ConvertTo-Vk $QuitKey) }

function Write-State {
    param([string]$Message, [string]$Colour = 'Gray', [string]$Level = 'INFO')
    Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message) -ForegroundColor $Colour
    Write-Log $Message $Level
}

# Is Ctrl+Alt+<vk> also a character on any layout loaded in this session? If it
# is, typing that character fires the chord - see -AllowAltGrCollision.
function Get-AltGrCollision {
    param([int]$Vk)
    $hits = @()
    if ($Vk -eq 0) { return $hits }
    try {
        foreach ($hkl in [StorM.Native]::Layouts()) {
            $ch = [StorM.Native]::AltGrChar([uint32]$Vk, $hkl)
            if (-not [string]::IsNullOrEmpty($ch)) {
                $codes = (($ch.ToCharArray() | ForEach-Object { 'U+{0:X4}' -f [int]$_ }) -join ' ')
                $hits += ('layout 0x{0:X8} types {1} [{2}]' -f $hkl.ToInt64(), $ch, $codes)
            }
        }
    } catch {
        # A guard that throws is worse than no guard - fail open and say so.
        Write-Log ('AltGr guard failed, chords not checked: {0}' -f $_.Exception.Message) 'WARN'
    }
    return $hits
}

function Get-ChordLabel {
    param([int]$Id)
    if ($script:KeyMap[$Id] -eq 0) { return 'not bound' }
    return ('Ctrl+Alt+{0}' -f $script:KeyName[$Id])
}

function Set-WindowTitle {
    param([string]$Text)
    try { $Host.UI.RawUI.WindowTitle = $Text } catch { }
}

function Set-ScrollLockState {
    param([bool]$On)
    if ($NoScrollLock) { return }
    if ([StorM.Native]::IsToggled($VK_SCROLL) -ne $On) {
        [void][StorM.Native]::TapKey($VK_SCROLL)
    }
}

# Clears a left button left down by a previous run (v1 never released it).
function Clear-StuckMouseButton {
    param([switch]$Quiet)
    if ([StorM.Native]::IsDown($VK_LBUTTON)) {
        [void][StorM.Native]::LeftUp()
        $script:ButtonHeld = $false
        if (-not $Quiet) { Write-State 'Left mouse button was down - released it.' 'Yellow' }
        return $true
    }
    return $false
}

function Invoke-Nudge {
    if ($LEFT_BUTTON_MODE -ne 'only') {
        switch ($Method) {
            'Move'  { [void][StorM.Native]::NudgeMouse() }
            'Key'   { [void][StorM.Native]::TapKey($VK_F15) }
            'Wheel' { [void][StorM.Native]::WheelNudge() }
            'Both'  { [void][StorM.Native]::NudgeMouse(); [void][StorM.Native]::TapKey($VK_F15) }
        }
    }

    # Held press, no matching release. Re-pressing while already down still
    # counts as an input event, which is what keeps the idle timer alive.
    if ($LEFT_BUTTON_MODE -ne 'off') {
        [void][StorM.Native]::LeftDown()
        $script:ButtonHeld = $true
    }

    # Timed click. Separate from the held mode above and mutually exclusive
    # with it - a click cancels the hold.
    if ($ClickHoldMs -gt 0 -and $LEFT_BUTTON_MODE -eq 'off') {
        try {
            $script:ButtonHeld = $true
            [void][StorM.Native]::LeftDown()
            Start-Sleep -Milliseconds $ClickHoldMs
        } finally {
            [void][StorM.Native]::LeftUp()
            $script:ButtonHeld = $false
        }
    }

    $script:NudgeCount++
    $script:LastNudgeAt = Get-Date
}

# True when the most recent system input did not come from us. Compares the
# absolute timestamp of the last input against our own last nudge, rather than
# just testing "is idle low" - our own nudge drives idle to zero too.
function Test-UserIsBack {
    param([uint32]$IdleMs)
    $lastInputAt = (Get-Date).AddMilliseconds(-[double]$IdleMs)
    return $lastInputAt -gt $script:LastNudgeAt.AddMilliseconds(250)
}

function Set-ActiveState {
    param([bool]$On)
    if ($script:Active -eq $On) { return }
    $script:Active = $On
    Set-ScrollLockState $On
    if ($On) {
        if (-not $NoKeepAwake) { [StorM.Native]::KeepAwakeOn() }
        Write-State 'ARMED  - idle nudging enabled.' 'Green'
        Set-WindowTitle 'StorM2 [ARMED]'
    } else {
        if (-not $NoKeepAwake) { [StorM.Native]::KeepAwakeOff() }
        [void](Clear-StuckMouseButton)
        Write-State ('PAUSED - {0} nudge(s) this session.' -f $script:NudgeCount) 'Cyan'
        Set-WindowTitle 'StorM2 [paused]'
    }
    Update-Tray
}

# Fallback only, used when RegisterHotKey is refused. Edge-triggered so holding
# a chord fires once. GetAsyncKeyState reads interrupt-level state, so it sees
# the keys even when another app owns the chord as a registered global hotkey.
# Every chord's previous state is updated on every pass - returning early would
# leave the unchecked ones stale and swallow their next genuine press.
function Get-PolledHotkeyId {
    $mods  = [StorM.Native]::IsDown($VK_CONTROL) -and [StorM.Native]::IsDown($VK_MENU)
    $fired = 0
    foreach ($id in $script:EnabledIds) {
        $now = $mods -and [StorM.Native]::IsDown($script:KeyMap[$id])
        if ($now -and (-not $script:PrevCombo[$id]) -and $fired -eq 0) { $fired = $id }
        $script:PrevCombo[$id] = $now
    }
    return $fired
}

# ---------------------------------------------------------------------------
# Tray icon
# ---------------------------------------------------------------------------
# Menu clicks are delivered from inside DispatchMessage, i.e. nested inside the
# main loop. Handlers therefore do not act directly - they drop a request into
# $script:Bus and the loop picks it up on its next pass. Mutating a captured
# hashtable is also the one scope-safe way to get data out of a GetNewClosure
# handler; assigning to $script: from inside one writes to the wrong module.
$script:Bus = @{ Action = $null; Source = 'none' }
$script:Tray = $null
$script:TrayIcons = @{}

function New-DotIcon {
    param([int]$R, [int]$G, [int]$B)
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    $gfx.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $gfx.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, $R, $G, $B))
    $pen   = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(190, 20, 20, 20)), 1.4
    $gfx.FillEllipse($brush, 2, 2, 12, 12)
    $gfx.DrawEllipse($pen,   2, 2, 12, 12)
    $gfx.Dispose(); $brush.Dispose(); $pen.Dispose()
    $handle = $bmp.GetHicon()
    $bmp.Dispose()
    return @{ Icon = [System.Drawing.Icon]::FromHandle($handle); Handle = $handle }
}

function Initialize-Tray {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $script:TrayIcons = @{
        armed  = New-DotIcon  60 200  90     # green
        paused = New-DotIcon 130 130 130     # grey
    }

    $bus  = $script:Bus
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    foreach ($entry in @(@('Arm  (Ctrl+Alt+' + $script:KeyName[$HK_START] + ')', 'arm'),
                         @('Pause  (Ctrl+Alt+' + $script:KeyName[$HK_PAUSE] + ')', 'pause'),
                         @('-', $null),
                         @('Show / hide console', 'console'),
                         @('-', $null),
                         @('Quit  (' + (Get-ChordLabel $HK_QUIT) + ')', 'quit'))) {
        if ($entry[0] -eq '-') { [void]$menu.Items.Add('-'); continue }
        $item = $menu.Items.Add($entry[0])
        $verb = $entry[1]
        $item.add_Click({ $bus.Action = $verb; $bus.Source = 'tray menu' }.GetNewClosure())
    }

    $ni = New-Object System.Windows.Forms.NotifyIcon
    $ni.Icon = $script:TrayIcons.paused.Icon
    $ni.Text = 'StorM2 - paused'
    $ni.ContextMenuStrip = $menu
    $ni.add_DoubleClick({ $bus.Action = 'toggle'; $bus.Source = 'tray double-click' }.GetNewClosure())
    $ni.Visible = $true
    $script:Tray = $ni
}

function Update-Tray {
    if ($null -eq $script:Tray) { return }
    if ($script:Active) {
        $script:Tray.Icon = $script:TrayIcons.armed.Icon
        $text = 'StorM2 - ARMED ({0} nudges)' -f $script:NudgeCount
    } else {
        $script:Tray.Icon = $script:TrayIcons.paused.Icon
        $text = 'StorM2 - paused'
    }
    # NotifyIcon.Text throws above 63 characters.
    if ($text.Length -gt 63) { $text = $text.Substring(0, 63) }
    $script:Tray.Text = $text
}

function Show-TrayBalloon {
    param([string]$Title, [string]$Message, [string]$Level = 'Info')
    if ($null -eq $script:Tray) { return }
    try { $script:Tray.ShowBalloonTip(6000, $Title, $Message, $Level) } catch { }
}

# ---------------------------------------------------------------------------
# Single instance
# ---------------------------------------------------------------------------
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\StorM2_KeepAwake', [ref]$createdNew)
if (-not $createdNew) {
    Write-Host 'StorM2 is already running in this session. Refusing to start a second copy.' -ForegroundColor Red
    Write-Host 'Find it with:  Get-CimInstance Win32_Process -Filter "Name=''powershell.exe''" | ? CommandLine -like "*StorM*" | Select ProcessId,CommandLine' -ForegroundColor DarkGray
    $mutex.Dispose()
    exit 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
try {
    Write-Host ''
    Write-Host '  StorM2 - keep awake' -ForegroundColor White
    Write-Host ('  PID {0} | method {1} | idle threshold {2}s | click hold {3}ms' -f `
                $PID, $Method, $IdleThresholdSeconds, $ClickHoldMs) -ForegroundColor DarkGray
    if ($LEFT_BUTTON_MODE -ne 'off') {
        Write-Host ('  LEFT BUTTON HELD DOWN - mode ''{0}'', auto-release {1}. Experimental.' -f `
                    $LEFT_BUTTON_MODE, $HOLD_AUTO_RELEASE) -ForegroundColor Yellow
    }
    Write-Host ''

    Write-Log ('host={0} method={1} idle={2}s click={3}ms poll={4}ms leftButton={5} startActive={6} tray={7} console={8}' -f `
               $PSVersionTable.PSVersion, $Method, $IdleThresholdSeconds, $ClickHoldMs, $PollMs,
               $LEFT_BUTTON_MODE, [bool]$StartActive, (-not $NoTrayIcon), [bool]$ShowConsole) 'START'
    Write-Log ('  chords requested: arm={0} pause={1} quit={2} | log={3} heartbeat={4}s' -f `
               (Get-ChordLabel $HK_START), (Get-ChordLabel $HK_PAUSE), (Get-ChordLabel $HK_QUIT),
               $LogPath, $HeartbeatSeconds) 'START'
    try {
        $layoutList = ((([StorM.Native]::Layouts()) | ForEach-Object { '0x{0:X8}' -f $_.ToInt64() }) -join ', ')
    } catch { $layoutList = 'unavailable' }
    Write-Log ('  keyboard layouts loaded: {0}' -f $layoutList) 'START'

    # Clean up after a previous run that died with the button down.
    [void](Clear-StuckMouseButton)

    # Decide which chords are usable BEFORE the tray exists, so the menu can
    # label an unbound quit key honestly.
    #
    # The AltGr trap: RegisterHotKey's MOD_CONTROL|MOD_ALT does not distinguish
    # left Alt from right, and AltGr is right-Alt plus a synthetic left-Ctrl. So
    # on the Polish (Programmers) layout the l-with-stroke IS Ctrl+Alt+L, which
    # under the old -QuitKey L default quit this script the moment a Polish word
    # was typed - through the normal exit path, hours into a session, with no
    # trace of itself anywhere. Refuse a colliding quit chord; only warn about a
    # colliding arm or pause, since those are recoverable.
    $notes = @()
    foreach ($id in @($HK_START, $HK_PAUSE, $HK_QUIT)) {
        if ($script:KeyMap[$id] -eq 0) {
            Write-Log ('{0}: no chord requested' -f $script:ActionForId[$id])
            continue
        }
        # @() around the call: an empty return unrolls to $null, and $null.Count
        # is a terminating error under Set-StrictMode -Version 2.0.
        $collide = @(Get-AltGrCollision $script:KeyMap[$id])
        if ($collide.Count -eq 0) { $script:EnabledIds += $id; continue }
        $label = 'Ctrl+Alt+{0}' -f $script:KeyName[$id]
        if ($id -eq $HK_QUIT -and -not $AllowAltGrCollision) {
            $script:KeyMap[$id] = 0
            $notes += @{ Colour = 'Red'; Level = 'WARN'; Balloon = $true
                         Text = ('{0} REFUSED as the quit chord - AltGr+{1} is a character here ({2}), so typing it would quit StorM2. Quit from the tray menu, or pass -AllowAltGrCollision to override.' -f `
                                 $label, $script:KeyName[$id], ($collide -join '; ')) }
        } else {
            $script:EnabledIds += $id
            $notes += @{ Colour = 'Yellow'; Level = 'WARN'; Balloon = $false
                         Text = ('{0} collides with AltGr - {1} is a character here ({2}), so typing it will {3} StorM2.' -f `
                                 $label, $script:KeyName[$id], ($collide -join '; '), $script:ActionForId[$id]) }
        }
    }

    # Tray next, so a hotkey warning has somewhere visible to go when the console
    # is hidden.
    if (-not $NoTrayIcon) {
        try { Initialize-Tray; Write-State 'Tray icon created.' 'DarkGray' }
        catch { Write-State ("Tray icon unavailable: {0}" -f $_.Exception.Message) 'Yellow' 'WARN' }
    }

    foreach ($n in $notes) {
        Write-State $n.Text $n.Colour $n.Level
        if ($n.Balloon) { Show-TrayBalloon 'StorM2 - chord refused' $n.Text 'Warning' }
    }
    if ($script:KeyMap[$HK_QUIT] -eq 0 -and $NoTrayIcon) {
        Write-State 'No quit chord and no tray icon - Task Manager is the only way to stop this.' 'Yellow' 'WARN'
    }

    # Prefer real system-wide hotkeys.
    $failed = @()
    foreach ($id in $script:EnabledIds) {
        if ([StorM.Native]::RegisterCtrlAlt($id, $script:KeyMap[$id])) {
            $script:Registered += $id
        } else {
            $failed += ('Ctrl+Alt+{0} (err {1})' -f $script:KeyName[$id], [StorM.Native]::LastError())
        }
    }
    if ($script:EnabledIds.Count -eq 0) {
        # Nothing to register and nothing to poll. The pump still runs - the tray
        # icon needs it.
        $script:HotkeysOk = $true
        Write-State 'No chords bound - tray menu only.' 'DarkGray'
    } elseif ($script:Registered.Count -eq $script:EnabledIds.Count) {
        $script:HotkeysOk = $true
        Write-State 'Hotkeys registered system-wide - keypresses will not leak to the focused app.' 'DarkGray'
    } else {
        # Partial registration is worse than none - release and poll instead.
        foreach ($id in $script:Registered) { [void][StorM.Native]::Unregister($id) }
        $script:Registered = @()
        $script:HotkeysOk = $false
        Write-State ('Chord already owned by another app: {0}' -f ($failed -join ', ')) 'Yellow' 'WARN'
        Write-State 'Using GetAsyncKeyState polling instead - works, but the chord also fires that app.' 'Yellow' 'WARN'
        Write-State 'Pick a free chord to avoid that, e.g. -StartKey J -PauseKey K' 'DarkGray'
        # With the console hidden this warning would otherwise be invisible.
        Show-TrayBalloon 'StorM2 - hotkey conflict' `
            (("{0} is already owned by another app. Falling back to polling, " -f ($failed -join ', ')) +
             'so the chord will fire that app too. Pick a free key instead.') 'Warning'
    }

    Write-Host ('  {0}  arm      {1}  pause      {2}  quit' -f `
                (Get-ChordLabel $HK_START), (Get-ChordLabel $HK_PAUSE), (Get-ChordLabel $HK_QUIT)) -ForegroundColor DarkGray
    Write-Host ''

    Set-WindowTitle 'StorM2 [paused]'
    if ($StartActive) { Set-ActiveState $true }
    else { Write-State ('Idle - waiting for {0}.' -f (Get-ChordLabel $HK_START)) 'DarkGray' }

    # Hide last, so any startup warning above is still on screen if -ShowConsole.
    if (-not $ShowConsole) { [StorM.Native]::HideConsole() }

    $consecutiveErrors = 0
    while ($true) {
      try {
        # Always pump, even in polling mode - the tray icon needs it.
        while (($id = [StorM.Native]::NextHotkeyId()) -ne 0) {
            # Logged before it is acted on. If a stray chord ever quits this
            # again, this line is the evidence, and the modifier snapshot says
            # whether right-Alt - that is, AltGr - was involved.
            Write-Log ('{0} -> {1}, modifiers still down: {2}' -f `
                       (Get-ChordLabel $id), $script:ActionForId[$id], (Get-ModifierSnapshot)) 'HOTKEY'
            $script:Bus.Action = $script:ActionForId[$id]
            $script:Bus.Source = 'hotkey ' + (Get-ChordLabel $id)
        }
        if (-not $script:HotkeysOk) {
            $polled = Get-PolledHotkeyId
            if ($polled -ne 0) {
                Write-Log ('polled {0} -> {1}, modifiers down: {2}' -f `
                           (Get-ChordLabel $polled), $script:ActionForId[$polled], (Get-ModifierSnapshot)) 'HOTKEY'
                $script:Bus.Action = $script:ActionForId[$polled]
                $script:Bus.Source = 'polled ' + (Get-ChordLabel $polled)
            }
        }

        if ($null -ne $script:Bus.Action) {
            $action = $script:Bus.Action
            $source = $script:Bus.Source
            $script:Bus.Action = $null
            Write-Log ('action {0} from {1}' -f $action, $source) 'ACT'
            switch ($action) {
                'arm'     { Set-ActiveState $true }
                'pause'   { Set-ActiveState $false }
                'toggle'  { Set-ActiveState (-not $script:Active) }
                'console' { if ([StorM.Native]::ConsoleVisible()) { [StorM.Native]::HideConsole() }
                            else { [StorM.Native]::ShowConsole() } }
                'quit'    { $script:ExitReason = 'quit requested from ' + $source
                            Write-State ('Quit requested from {0}.' -f $source) 'White'; return }
            }
        }

        if ($script:Active) {
            # Only act once genuinely idle, so this never fights live input.
            # Our own nudge resets the counter, giving a natural cadence of one
            # nudge per IdleThresholdSeconds while away, and none while working.
            $idle = [StorM.Native]::IdleMilliseconds()
            if ($idle -ge $ThresholdMs) {
                Invoke-Nudge
                Set-WindowTitle ('StorM2 [ARMED] {0} nudges' -f $script:NudgeCount)
                Update-Tray
            }
            elseif ($script:ButtonHeld -and $HOLD_AUTO_RELEASE -and (Test-UserIsBack $idle)) {
                [void][StorM.Native]::LeftUp()
                $script:ButtonHeld = $false
                Write-State 'You are back - released the held mouse button.' 'Yellow'
            }
        }

        # Liveness. A kill, or the console closed with the X, never reaches the
        # finally block and so cannot report its own exit - the last of these
        # lines is the time of death. It also separates "the process died" from
        # "the tray icon vanished": beats continuing past the moment the icon
        # disappeared means the icon went and this loop did not.
        if ($HeartbeatSeconds -gt 0 -and ((Get-Date) - $script:LastBeatAt).TotalSeconds -ge $HeartbeatSeconds) {
            $script:LastBeatAt = Get-Date
            Write-Log ('armed={0} nudges={1} idle={2}s alive={3:N0}m' -f `
                       $script:Active, $script:NudgeCount,
                       [int]([StorM.Native]::IdleMilliseconds() / 1000),
                       ((Get-Date) - $script:StartedAt).TotalMinutes) 'BEAT'
        }

        $consecutiveErrors = 0
        Start-Sleep -Milliseconds $PollMs
      }
      catch {
        # Until this catch existed, ANY error in here ended the script outright:
        # $ErrorActionPreference = 'Stop' plus no catch means one bad call in a
        # loop that runs 10x a second exits the process, silently, hours in, and
        # looks exactly like a deliberate quit from outside. Log it, carry on,
        # and give up only once it is clearly not transient.
        $consecutiveErrors++
        Write-ErrorLog $_ ('loop error {0} of 5' -f $consecutiveErrors)
        if ($consecutiveErrors -ge 5) {
            $script:ExitReason = 'five consecutive loop errors'
            throw
        }
        Start-Sleep -Milliseconds 500
      }
    }
}
catch {
    if ($script:ExitReason -eq 'unknown') { $script:ExitReason = 'unhandled error' }
    Write-ErrorLog $_ 'FATAL'
    Write-State ('Stopping on an unhandled error: {0}' -f $_.Exception.Message) 'Red' 'ERROR'
    # Give the balloon a moment to render - finally disposes the icon next.
    Show-TrayBalloon 'StorM2 stopped' ('Unhandled error: ' + $_.Exception.Message) 'Error'
    Start-Sleep -Seconds 3
}
finally {
    Write-Log ('reason={0} nudges={1} alive={2:N0}m armed={3}' -f `
               $script:ExitReason, $script:NudgeCount,
               ((Get-Date) - $script:StartedAt).TotalMinutes, $script:Active) 'EXIT'
    # Runs on normal exit, Ctrl+Alt+Q and Ctrl+C. Does NOT run if the console is
    # closed with the X or the process is killed - hence the no-button default.
    foreach ($id in $script:Registered) { [void][StorM.Native]::Unregister($id) }
    if ($script:ButtonHeld) { [void][StorM.Native]::LeftUp() }
    [void](Clear-StuckMouseButton -Quiet)
    if (-not $NoKeepAwake) { [StorM.Native]::KeepAwakeOff() }
    Set-ScrollLockState $false
    Set-WindowTitle 'StorM2 [stopped]'
    # Without an explicit Dispose the icon lingers in the tray until hovered.
    if ($null -ne $script:Tray) {
        $script:Tray.Visible = $false
        $script:Tray.Dispose()
        $script:Tray = $null
    }
    foreach ($k in @($script:TrayIcons.Keys)) {
        try { $script:TrayIcons[$k].Icon.Dispose()
              [void][StorM.Native]::DestroyIcon($script:TrayIcons[$k].Handle) } catch { }
    }
    Write-Host ("[{0:HH:mm:ss}] Stopped. Cleanup done." -f (Get-Date)) -ForegroundColor White
    if ($null -ne $mutex) {
        try { $mutex.ReleaseMutex() } catch { }
        $mutex.Dispose()
    }
}
