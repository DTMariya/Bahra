# Live view of port 8000 on both OUT terminals. Read-only: sends nothing. Ctrl+C to stop.
$port      = 8000
$terminals = @(
    @{ Name = 'JV Scale OUT';   Host = '192.168.104.51' },   # .51 is OUT, .52 is IN (Bahra, 2026-09-16)
    @{ Name = 'South Gate OUT'; Host = '192.168.174.12' }
)
$showEveryLine = $false   # $true = print all ~20 lines/sec, like PuTTY. $false = only when the reading changes.

foreach ($t in $terminals) {
    $t.Client = New-Object System.Net.Sockets.TcpClient
    $t.Stream = $null; $t.Buf = ''; $t.Primed = $false; $t.Last = ''; $t.Count = 0
    $ar = $t.Client.BeginConnect($t.Host, $port, $null, $null)
    if ($ar.AsyncWaitHandle.WaitOne(4000) -and $t.Client.Connected) {
        $t.Client.EndConnect($ar)
        $t.Stream = $t.Client.GetStream()
        Write-Host ("{0,-15} {1}:{2} connected" -f $t.Name, $t.Host, $port) -ForegroundColor Green
    } else {
        Write-Host ("{0,-15} {1}:{2} NOT reachable" -f $t.Name, $t.Host, $port) -ForegroundColor Red
        $t.Client.Close()
    }
}
Write-Host "Watching. Ctrl+C to stop." -ForegroundColor Cyan

$bytes = New-Object byte[] 8192
$lastSummary = Get-Date
try {
    while (@($terminals | Where-Object { $_.Stream }).Count -gt 0) {
        foreach ($t in $terminals) {
            if (-not $t.Stream) { continue }

            # Closed by the terminal: readable but nothing to read.
            if ($t.Client.Client.Poll(0, [Net.Sockets.SelectMode]::SelectRead) -and $t.Client.Available -eq 0) {
                Write-Host ("{0}  {1,-15} DISCONNECTED" -f (Get-Date -f 'HH:mm:ss.fff'), $t.Name) -ForegroundColor Red
                $t.Client.Close(); $t.Stream = $null; continue
            }
            while ($t.Stream.DataAvailable) {
                $n = $t.Stream.Read($bytes, 0, $bytes.Length)
                $t.Buf += [Text.Encoding]::ASCII.GetString($bytes, 0, $n)
            }

            $parts = $t.Buf -split "[\r\n]+"
            $t.Buf = $parts[$parts.Count - 1]              # unfinished line, keep for next read
            for ($i = 0; $i -lt $parts.Count - 1; $i++) {
                $line = $parts[$i].Trim()
                if (-not $t.Primed) { $t.Primed = $true; continue }   # first line is cut off mid-frame
                if ($line -eq '') { continue }
                $t.Count++
                if ($showEveryLine -or $line -ne $t.Last) {
                    Write-Host ("{0}  {1,-15} {2}" -f (Get-Date -f 'HH:mm:ss.fff'), $t.Name, $line)
                }
                $t.Last = $line
            }
        }

        # Every 5 s, prove each stream is still alive even when the deck is quiet.
        $elapsed = ((Get-Date) - $lastSummary).TotalSeconds
        if ($elapsed -ge 5) {
            foreach ($t in $terminals) {
                if ($t.Stream) {
                    Write-Host ("{0}  {1,-15} alive, {2:N1} lines/s, last '{3}'" -f (Get-Date -f 'HH:mm:ss.fff'), $t.Name, ($t.Count / $elapsed), $t.Last) -ForegroundColor DarkGray
                }
                $t.Count = 0
            }
            $lastSummary = Get-Date
        }
        Start-Sleep -Milliseconds 20
    }
} finally {
    foreach ($t in $terminals) { if ($t.Client) { $t.Client.Close() } }
    Write-Host "Closed." -ForegroundColor Cyan
}
