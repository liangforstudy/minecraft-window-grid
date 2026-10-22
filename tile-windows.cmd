<# : batch launcher. cmd runs these lines; PowerShell skips them as a comment and runs the script below.
@echo off
setlocal
set "PS_SCRIPT=%~f0"
set "PS_ARGS=%*"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$sb = [scriptblock]::Create([IO.File]::ReadAllText($env:PS_SCRIPT)); & ([scriptblock]::Create('& $args[0] ' + $env:PS_ARGS)) $sb"
set "RC=%ERRORLEVEL%"
if "%~1"=="" pause
exit /b %RC%
#>
<#
.SYNOPSIS
  Tiles the running Minecraft windows in a grid on the main screen: quarters for up to 4,
  3x2 for 5-6, 3x3 for 7-9. The second screen stays free (-SecondScreen: old layout with
  the 5th window maximized there).

.DESCRIPTION
  Windows are found per process (javaw.exe / java.exe), not by title, since every
  instance has the same title. Each process is matched to its Prism instance folder from
  its command line, and windows are assigned to slots in instance-folder order (or -Order),
  so the same instance lands in the same slot every time.

  All coordinates are physical pixels: the script switches its own thread to per-monitor
  DPI awareness (v2), so display scaling (125%, 150%, ...) doesn't shrink or offset
  anything. Monitor positions are read from Windows, not hard-coded. Windows' invisible
  resize borders are compensated, so the visible frames meet edge to edge.

.EXAMPLE
  tile-windows.cmd                 # tile
  tile-windows.cmd -List           # only show monitors and windows found
  tile-windows.cmd -CoverTaskbar   # use the whole screen; bottom row goes under the taskbar
  tile-windows.cmd -SecondScreen   # 4 quarters + 5th maximized on the second screen
  tile-windows.cmd -Order 'Bot 2','Bot 3'   # these first (Prism display names)
#>
[CmdletBinding()]
param(
    [switch]$List,
    [switch]$CoverTaskbar,               # use the whole main screen (bottom row goes under the taskbar)
    [switch]$SecondScreen,               # old layout: 4 quarters on the main screen, 5th maximized on the second
    [string[]]$Order = @(),
    [string[]]$ProcessName = @('javaw', 'java'),
    [string]$WindowClass = 'GLFW30'      # Minecraft's (LWJGL/GLFW) window class
)
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class McTiler {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct MONITORINFOEX { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice; }
    delegate bool MonitorEnumProc(IntPtr hMon, IntPtr hdc, ref RECT r, IntPtr data);
    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc cb, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr hMon, ref MONITORINFOEX mi);
    [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr hMon, int type, out uint dpiX, out uint dpiY);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr hWnd, uint cmd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hWnd, StringBuilder sb, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int n);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr hWnd, int attr, out RECT r, int size);

    const uint SWP_NOZORDER = 0x4, SWP_NOACTIVATE = 0x10;
    const int SW_RESTORE = 9, SW_MAXIMIZE = 3, DWMWA_EXTENDED_FRAME_BOUNDS = 9;

    // Per-monitor-aware v2 on the calling thread: all coordinates are physical pixels.
    static void PerMonitor() { SetThreadDpiAwarenessContext(new IntPtr(-4)); }

    public class Monitor { public string Device; public bool Primary; public RECT Bounds, Work; public uint Dpi; }
    public class Window { public IntPtr Handle; public uint Pid; public string Class, Title; public RECT Rect; }

    public static List<Monitor> Monitors() {
        PerMonitor();
        var list = new List<Monitor>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, delegate (IntPtr h, IntPtr dc, ref RECT r, IntPtr d) {
            var mi = new MONITORINFOEX(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
            GetMonitorInfo(h, ref mi);
            uint dx, dy; if (GetDpiForMonitor(h, 0, out dx, out dy) != 0) dx = 96;
            list.Add(new Monitor { Device = mi.szDevice, Primary = (mi.dwFlags & 1) != 0, Bounds = mi.rcMonitor, Work = mi.rcWork, Dpi = dx });
            return true;
        }, IntPtr.Zero);
        return list;
    }

    // Visible, unowned top-level windows of the given processes.
    public static List<Window> Windows(uint[] pids) {
        PerMonitor();
        var set = new HashSet<uint>(pids);
        var list = new List<Window>();
        EnumWindows(delegate (IntPtr h, IntPtr l) {
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (!set.Contains(pid) || !IsWindowVisible(h) || GetWindow(h, 4) != IntPtr.Zero) return true;
            var cls = new StringBuilder(256); GetClassName(h, cls, 256);
            var title = new StringBuilder(512); GetWindowText(h, title, 512);
            RECT r; GetWindowRect(h, out r);
            list.Add(new Window { Handle = h, Pid = pid, Class = cls.ToString(), Title = title.ToString(), Rect = r });
            return true;
        }, IntPtr.Zero);
        return list;
    }

    // Visible frame (without the invisible resize borders) placed exactly at x,y,w,h.
    public static RECT Place(IntPtr h, int x, int y, int w, int hh) {
        PerMonitor();
        ShowWindow(h, SW_RESTORE);
        SetWindowPos(h, IntPtr.Zero, x, y, w, hh, SWP_NOZORDER | SWP_NOACTIVATE);
        RECT wr, fr;
        GetWindowRect(h, out wr);
        if (DwmGetWindowAttribute(h, DWMWA_EXTENDED_FRAME_BOUNDS, out fr, Marshal.SizeOf(typeof(RECT))) == 0) {
            int l = fr.Left - wr.Left, t = fr.Top - wr.Top, r = wr.Right - fr.Right, b = wr.Bottom - fr.Bottom;
            SetWindowPos(h, IntPtr.Zero, x - l, y - t, w + l + r, hh + t + b, SWP_NOZORDER | SWP_NOACTIVATE);
        }
        return Frame(h);
    }

    public static RECT Maximize(IntPtr h, RECT on) {
        PerMonitor();
        ShowWindow(h, SW_RESTORE);
        // move onto the target monitor first so it maximizes there
        SetWindowPos(h, IntPtr.Zero, on.Left + 50, on.Top + 50, (on.Right - on.Left) / 2, (on.Bottom - on.Top) / 2, SWP_NOZORDER | SWP_NOACTIVATE);
        ShowWindow(h, SW_MAXIMIZE);
        return Frame(h);
    }

    public static RECT Frame(IntPtr h) {
        PerMonitor();
        RECT r;
        if (DwmGetWindowAttribute(h, DWMWA_EXTENDED_FRAME_BOUNDS, out r, Marshal.SizeOf(typeof(RECT))) != 0) GetWindowRect(h, out r);
        return r;
    }
}
'@

function Format-Rect($r) { '{0},{1} {2}x{3}' -f $r.Left, $r.Top, ($r.Right - $r.Left), ($r.Bottom - $r.Top) }

# ---------- monitors ----------
$monitors = [McTiler]::Monitors()
$main = $monitors | Where-Object Primary | Select-Object -First 1
$second = $monitors | Where-Object { -not $_.Primary } | Select-Object -First 1
Write-Host 'Monitors (physical pixels):'
foreach ($m in $monitors) {
    Write-Host ('  {0}{1}  {2}  work {3}  {4}%' -f $m.Device, $(if ($m.Primary) { ' (main)' } else { '' }),
        (Format-Rect $m.Bounds), (Format-Rect $m.Work), [math]::Round($m.Dpi / 96 * 100))
}

# ---------- Minecraft windows, one per process ----------
$procs = Get-CimInstance Win32_Process | Where-Object { $ProcessName -contains [IO.Path]::GetFileNameWithoutExtension($_.Name) }
$instOf = @{}
foreach ($p in $procs) {
    # e.g. -Djava.library.path=C:/Users/.../PrismLauncher/instances/<folder>/natives
    $label = "(pid $($p.ProcessId))"
    if ($p.CommandLine -match '([A-Za-z]:[\\/](?:[^"\\/;]+[\\/])*?instances[\\/]([^\\/";]+))[\\/]') {
        $folder = $Matches[2]
        $cfgName = Select-String -LiteralPath (Join-Path $Matches[1] 'instance.cfg') -Pattern '^name=' -ErrorAction SilentlyContinue | Select-Object -First 1
        $display = if ($cfgName) { $cfgName.Line.Substring(5) } else { $folder }
        # Prism's display name; folder too when it differs
        $label = if ($display -eq $folder) { $display } else { "$display [folder: $folder]" }
    }
    $instOf[[uint32]$p.ProcessId] = $label
}
$all = if ($procs) { [McTiler]::Windows([uint32[]]@($procs | ForEach-Object { [uint32]$_.ProcessId })) } else { @() }
$windows = foreach ($g in ($all | Group-Object Pid)) {
    # the game window; fall back to the process's biggest window if the class doesn't match
    $w = @($g.Group | Where-Object { $_.Class -eq $WindowClass })
    if (-not $w) { $w = @($g.Group | Sort-Object { ($_.Rect.Right - $_.Rect.Left) * ($_.Rect.Bottom - $_.Rect.Top) } -Descending) }
    $w[0] | Add-Member -NotePropertyName Instance -NotePropertyValue $instOf[[uint32]$g.Name] -PassThru
}
$windows = @($windows | Sort-Object @{ e = { $i = [array]::IndexOf($Order, $_.Instance); if ($i -lt 0) { [int]::MaxValue } else { $i } } }, Instance, Pid)

Write-Host "`nMinecraft windows found: $($windows.Count)"
foreach ($w in $windows) { Write-Host ('  {0,-42} pid {1,-6} {2}  "{3}"' -f $w.Instance, $w.Pid, (Format-Rect ([McTiler]::Frame($w.Handle))), $w.Title) }
if ($List -or -not $windows) { return }

# ---------- slots ----------
$area = if ($CoverTaskbar) { $main.Bounds } else { $main.Work }   # default: stay above the taskbar
$W = $area.Right - $area.Left; $H = $area.Bottom - $area.Top
# grid on the main screen: at least 2x2 (quarters), 3x2 for 5-6 windows, 3x3 for 7-9, ...
$onMain = if ($SecondScreen -and $second) { [math]::Min($windows.Count, 4) } else { $windows.Count }
$cols = [math]::Max(2, [math]::Ceiling([math]::Sqrt($onMain)))
$rows = [math]::Max(2, [math]::Ceiling($onMain / $cols))
$slots = @()
for ($r = 0; $r -lt $rows; $r++) {
    for ($c = 0; $c -lt $cols; $c++) {
        # integer edges so the cells meet exactly and fill the area
        $x0 = $area.Left + [math]::Floor($W * $c / $cols); $x1 = $area.Left + [math]::Floor($W * ($c + 1) / $cols)
        $y0 = $area.Top + [math]::Floor($H * $r / $rows);  $y1 = $area.Top + [math]::Floor($H * ($r + 1) / $rows)
        $slots += @{ Name = "row $($r + 1), col $($c + 1)"; X = $x0; Y = $y0; W = $x1 - $x0; H = $y1 - $y0 }
    }
}
if ($SecondScreen -and $second) { $slots = @($slots[0..3]) + @{ Name = 'second screen (maximized)'; Second = $true } }

Write-Host ''
for ($n = 0; $n -lt $windows.Count; $n++) {
    $w = $windows[$n]
    if ($n -ge $slots.Count) { Write-Warning "No slot left for $($w.Instance) (pid $($w.Pid)); left where it is."; continue }
    $s = $slots[$n]
    $r = if ($s.Second) { [McTiler]::Maximize($w.Handle, $second.Work) } else { [McTiler]::Place($w.Handle, $s.X, $s.Y, $s.W, $s.H) }
    Write-Host ('  {0,-26} {1,-42} pid {2,-6} -> {3}' -f $s.Name, $w.Instance, $w.Pid, (Format-Rect $r))
}
