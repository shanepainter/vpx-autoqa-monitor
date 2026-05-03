$since = (Get-Date).AddHours(-18)
$out = 'C:\Users\pinball\AppData\Local\Temp\autoqa-crashes.csv'
$events = Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='Application Error'; StartTime=$since} -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -match 'VPinballX|vpinball' }
"Total VPX crash events: $($events.Count)"
$rows = foreach ($e in $events) {
    $msg = $e.Message
    $faultMod = if ($msg -match 'Faulting module name:\s*(\S+)') { $matches[1] -replace ',$','' } else { '' }
    $exc = if ($msg -match 'Exception code:\s*(\S+)') { $matches[1] } else { '' }
    [PSCustomObject]@{
        TimeCreated = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
        FaultingModule = $faultMod
        ExceptionCode = $exc
    }
}
$rows | Export-Csv -Path $out -NoTypeInformation
"--- module breakdown ---"
$rows | Group-Object FaultingModule | Sort-Object Count -Descending | Select-Object Count, Name | Format-Table -AutoSize
"--- exception code breakdown ---"
$rows | Group-Object ExceptionCode | Sort-Object Count -Descending | Select-Object Count, Name | Format-Table -AutoSize
"--- CSV: $out"
