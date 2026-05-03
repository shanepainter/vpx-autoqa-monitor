$ErrorActionPreference = 'SilentlyContinue'
$failCsv = 'C:\Users\pinball\AppData\Local\Temp\autoqa-failed-tables.csv'
$logPath = 'C:\Users\pinball\AppData\Local\Temp\autoqa-janitor.log'
$startedAt = Get-Date
$ageThresholdMin = 5
$tickIntervalSec = 900

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
using System.Collections.Generic;
public class WinUtil {
    public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr h, EnumWindowsProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder sb, int len);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int len);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern int GetWindowLongW(IntPtr h, int idx);

    public static List<IntPtr> GetWindowsForPid(uint pid) {
        var list = new List<IntPtr>();
        EnumWindows((h, p) => {
            uint wpid; GetWindowThreadProcessId(h, out wpid);
            if (wpid == pid) list.Add(h);
            return true;
        }, IntPtr.Zero);
        return list;
    }
    public static string GetVisFlag(IntPtr h) {
        return IsWindowVisible(h) ? "vis" : "hid";
    }
    public static string GetTitle(IntPtr h) {
        var sb = new StringBuilder(512); GetWindowTextW(h, sb, 512); return sb.ToString();
    }
    public static string GetCls(IntPtr h) {
        var sb = new StringBuilder(128); GetClassNameW(h, sb, 128); return sb.ToString();
    }
    public static List<string> GetChildTexts(IntPtr h) {
        var ts = new List<string>();
        EnumChildWindows(h, (ch, p) => {
            var sb = new StringBuilder(2048); GetWindowTextW(ch, sb, 2048);
            var t = sb.ToString().Trim();
            if (!string.IsNullOrEmpty(t) && t.Length > 1) ts.Add(t);
            return true;
        }, IntPtr.Zero);
        return ts;
    }
}
"@

if (-not (Test-Path $failCsv)) {
    'KilledAt,PID,AgeMin,TableFile,RamMB,WindowClass,Title,DialogText' | Out-File $failCsv -Encoding UTF8
}

"=== janitor v2 (with dialog capture) started $($startedAt.ToString('o')) PID=$PID threshold=${ageThresholdMin}m interval=${tickIntervalSec}s ===" | Out-File $logPath -Append -Encoding UTF8

function Sanitize($s) {
    if (-not $s) { return '' }
    $s = $s -replace '[\r\n\t]+', ' ' -replace '"', "'"
    if ($s.Length -gt 600) { $s = $s.Substring(0, 600) + '...' }
    return $s
}

while ($true) {
    try {
        $now = Get-Date
        $procs = Get-CimInstance Win32_Process -Filter "Name='VPinballX.exe'"
        $leaked = @($procs | Where-Object { (($now - $_.CreationDate).TotalMinutes) -ge $ageThresholdMin })
        $killCount = 0
        foreach ($p in $leaked) {
            $age = [int](($now - $p.CreationDate).TotalMinutes)
            $tbl = '<no-play>'
            if ($p.CommandLine -match '(?i)-play\s+"([^"]+)"') {
                $tbl = Split-Path $matches[1] -Leaf
            }
            $proc = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
            $ram = if ($proc) { [int]($proc.WS / 1MB) } else { 0 }

            # Capture window state BEFORE killing
            $titles = @()
            $classes = @()
            $allDialogText = @()
            try {
                $hwnds = [WinUtil]::GetWindowsForPid([uint32]$p.ProcessId)
                foreach ($h in $hwnds) {
                    $cls = [WinUtil]::GetCls($h)
                    $ttl = [WinUtil]::GetTitle($h)
                    $vis = [WinUtil]::GetVisFlag($h)
                    if ($ttl -or ($cls -and $cls -ne 'IME' -and $cls -ne 'MSCTFIME UI')) {
                        $classes += "${cls}/${vis}"
                        $titles += $ttl
                    }
                    $kidTexts = [WinUtil]::GetChildTexts($h)
                    if ($kidTexts.Count -gt 0) { $allDialogText += $kidTexts }
                }
            } catch {
                "  WIN-ENUM-FAIL PID $($p.ProcessId): $($_.Exception.Message)" | Out-File $logPath -Append -Encoding UTF8
            }
            $titleStr  = Sanitize (($titles | Where-Object { $_ }) -join ' | ')
            $classStr  = Sanitize (($classes | Where-Object { $_ }) -join ' | ')
            $dialogStr = Sanitize (($allDialogText | Where-Object { $_ }) -join ' | ')

            try {
                Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
                $tblEsc = $tbl -replace '"', '""'
                $row = "{0},{1},{2},`"{3}`",{4},`"{5}`",`"{6}`",`"{7}`"" -f $now.ToString('yyyy-MM-dd HH:mm:ss'), $p.ProcessId, $age, $tblEsc, $ram, $classStr, $titleStr, $dialogStr
                $row | Out-File $failCsv -Append -Encoding UTF8
                $previewTitle = if ($titleStr) { $titleStr.Substring(0, [Math]::Min(80, $titleStr.Length)) } else { '<no-window>' }
                "  killed PID $($p.ProcessId) age=${age}m ram=${ram}MB table=$tbl title=[$previewTitle]" | Out-File $logPath -Append -Encoding UTF8
                $killCount++
            } catch {
                "  FAIL-KILL PID $($p.ProcessId): $($_.Exception.Message)" | Out-File $logPath -Append -Encoding UTF8
            }
        }
        "tick @ $($now.ToString('HH:mm:ss')) totalVpx=$($procs.Count) leaked=$($leaked.Count) killed=$killCount" | Out-File $logPath -Append -Encoding UTF8
    } catch {
        "!! tick-error: $($_.Exception.Message)" | Out-File $logPath -Append -Encoding UTF8
    }
    Start-Sleep -Seconds $tickIntervalSec
}
