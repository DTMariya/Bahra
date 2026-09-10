<#
.SYNOPSIS
    Dump exactly what the IND570 Shared Data Server sends during connect and login, byte for byte.

.DESCRIPTION
    Opens ONE connection, shows every byte the terminal sends with CR and LF made visible, sends
    'user admin', shows the reply, then quits. Nothing else.

    Written because Start-WeighbridgeAgent.ps1 reported "login refused: 53 Ready for user" against
    real hardware -- meaning the greeting is not the single clean line the stand-in sends. This
    settles what it actually is.

    Read-only: user and quit, nothing more.

.EXAMPLE
    .\Show-Handshake.ps1 192.168.104.51
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$TerminalIp,
    [int]$Port = 1701,
    [string]$User = 'admin'
)

$ErrorActionPreference = 'Stop'

function Show-Bytes {
    param([string]$Label, [byte[]]$Bytes, [int]$Count)
    if ($Count -le 0) { Write-Host "  $Label : (nothing)" -ForegroundColor DarkGray; return }
    $text = [Text.Encoding]::ASCII.GetString($Bytes, 0, $Count)
    $vis  = $text.Replace("`r", '<CR>').Replace("`n", "<LF>`n         ")
    $hex  = ($Bytes[0..([Math]::Min($Count, 24) - 1)] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
    Write-Host "  $Label ($Count bytes)" -ForegroundColor Cyan
    Write-Host "         $vis"
    Write-Host "    hex: $hex$(if ($Count -gt 24) { ' ...' })" -ForegroundColor DarkGray
}

function Read-For {
    param($Stream, [int]$Ms)
    $buf = New-Object byte[] 4096
    $total = 0
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalMilliseconds -lt $Ms) {
        if ($Stream.DataAvailable) {
            $n = $Stream.Read($buf, $total, $buf.Length - $total)
            if ($n -le 0) { break }
            $total += $n
            $sw.Restart()          # keep going while it is still talking
        } else {
            Start-Sleep -Milliseconds 10
        }
    }
    return @{ Buffer = $buf; Count = $total }
}

Write-Host ""
Write-Host "Connecting to ${TerminalIp}:${Port}" -ForegroundColor White

$client = New-Object System.Net.Sockets.TcpClient
$ar = $client.BeginConnect($TerminalIp, $Port, $null, $null)
if (-not $ar.AsyncWaitHandle.WaitOne(5000)) { $client.Close(); throw "connect timeout" }
$client.EndConnect($ar)
$client.NoDelay = $true
$stream = $client.GetStream()

try {
    Write-Host ""
    Write-Host "1. On connect, before we say anything" -ForegroundColor White
    $r = Read-For $stream 2000
    Show-Bytes 'greeting' $r.Buffer $r.Count

    Write-Host ""
    Write-Host "2. After sending 'user $User' + CR" -ForegroundColor White
    $b = [Text.Encoding]::ASCII.GetBytes("user $User`r")
    $stream.Write($b, 0, $b.Length); $stream.Flush()
    $r = Read-For $stream 2000
    Show-Bytes 'reply' $r.Buffer $r.Count

    Write-Host ""
    Write-Host "3. Quitting" -ForegroundColor White
    $b = [Text.Encoding]::ASCII.GetBytes("quit`r")
    $stream.Write($b, 0, $b.Length); $stream.Flush()
    $r = Read-For $stream 1000
    Show-Bytes 'reply' $r.Buffer $r.Count
} finally {
    $client.Close()
    Write-Host ""
    Write-Host "closed." -ForegroundColor DarkGray
    Write-Host ""
}
