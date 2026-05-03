$now = Get-Date
$rows = Get-CimInstance Win32_Process -Filter "Name='VPinballX.exe'" | Sort-Object CreationDate | ForEach-Object {
    $age = [int]($now - $_.CreationDate).TotalMinutes
    $tbl = '<no-play>'
    if ($_.CommandLine -match '(?i)-play\s+"([^"]+)"') {
        $tbl = Split-Path $matches[1] -Leaf
    }
    [PSCustomObject]@{
        PID         = $_.ProcessId
        AgeMin      = $age
        StartTime   = $_.CreationDate.ToString('HH:mm:ss')
        TableFile   = $tbl
        CommandLine = $_.CommandLine
    }
}
$rows | Format-Table PID, AgeMin, StartTime, TableFile -AutoSize
"---"
"Total: $($rows.Count)  | Active (<2min): $(($rows | Where-Object { $_.AgeMin -lt 2 }).Count)  | Leaked (>=2min): $(($rows | Where-Object { $_.AgeMin -ge 2 }).Count)"
"---"
$leakCsv = 'C:\Users\pinball\AppData\Local\Temp\autoqa-leaked-tables.csv'
$rows | Where-Object { $_.AgeMin -ge 2 } | Export-Csv -Path $leakCsv -NoTypeInformation
"Leak CSV written: $leakCsv"
