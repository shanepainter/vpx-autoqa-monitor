$ErrorActionPreference = 'SilentlyContinue'
$logPath = 'C:\Users\pinball\AppData\Local\Temp\autoqa-watch.log'
$startedAt = Get-Date

$paths = @(
    @{ Path = 'D:\vPinball\PinUPSystem'; Recurse = $false },
    @{ Path = 'D:\vPinball\PinUPSystem\Recordings'; Recurse = $true },
    @{ Path = 'D:\vPinball\PinUPSystem\PUPVideos'; Recurse = $false },
    @{ Path = 'D:\vPinball\PinUPSystem\POPMedia'; Recurse = $false },
    @{ Path = 'D:\vPinball\PinUPSystem\pinupdates'; Recurse = $true },
    @{ Path = 'D:\vPinball\PinUPSystem\_tmpDownload'; Recurse = $true },
    @{ Path = 'D:\vPinball\VisualPinball'; Recurse = $false },
    @{ Path = 'D:\vPinball\VisualPinball\User'; Recurse = $true },
    @{ Path = 'D:\vPinball'; Recurse = $false },
    @{ Path = 'C:\Users\pinball\AppData\Roaming\PopperAutoQA'; Recurse = $true },
    @{ Path = 'C:\Users\pinball\AppData\Local\PopperAutoQA'; Recurse = $true },
    @{ Path = 'C:\Users\pinball\AppData\Roaming\PinUP'; Recurse = $true },
    @{ Path = 'C:\Users\pinball\AppData\Local\Temp'; Recurse = $false },
    @{ Path = 'C:\Users\pinball\Documents'; Recurse = $false },
    @{ Path = 'C:\Users\pinball\Desktop'; Recurse = $false }
)

"=== watcher started $($startedAt.ToString('o')) PID=$PID ===" | Out-File $logPath -Encoding UTF8
$seen = @{}
$tick = 0
while ($true) {
    $tick++
    $tickStart = Get-Date
    $newCount = 0
    try {
        foreach ($spec in $paths) {
            try {
                if (-not (Test-Path $spec.Path)) { continue }
                $items = if ($spec.Recurse) {
                    Get-ChildItem -Path $spec.Path -Recurse -File -ErrorAction SilentlyContinue
                } else {
                    Get-ChildItem -Path $spec.Path -File -ErrorAction SilentlyContinue
                }
                foreach ($f in $items) {
                    if ($f.LastWriteTime -lt $startedAt) { continue }
                    $key = "$($f.FullName)|$($f.LastWriteTime.Ticks)|$($f.Length)"
                    if ($seen.ContainsKey($key)) { continue }
                    $seen[$key] = $true
                    $newCount++
                    "$($f.LastWriteTime.ToString('HH:mm:ss'))`t$($f.Length)`t$($f.FullName)" | Out-File $logPath -Append -Encoding UTF8
                }
            } catch {
                "!! path-error $($spec.Path): $($_.Exception.Message)" | Out-File $logPath -Append -Encoding UTF8
            }
        }
    } catch {
        "!! tick-error: $($_.Exception.Message)" | Out-File $logPath -Append -Encoding UTF8
    }
    $elapsed = ((Get-Date) - $tickStart).TotalSeconds
    "--- tick $tick @ $((Get-Date).ToString('HH:mm:ss')) new=$newCount scanMs=$([int]($elapsed*1000)) seen=$($seen.Count) ---" | Out-File $logPath -Append -Encoding UTF8
    # Cap memory: prune seen if it grows huge (AutoQA writing thousands of recordings)
    if ($seen.Count -gt 50000) {
        $seen = @{}
        "!! pruned seen-cache" | Out-File $logPath -Append -Encoding UTF8
    }
    Start-Sleep -Seconds 30
}
