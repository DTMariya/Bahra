<#
.SYNOPSIS
    Talk to a METTLER TOLEDO IND570 Shared Data Server (raw TCP, port 1701) and print one reading.

.DESCRIPTION
    The same handshake as `weighbridge_agent.py probe`, in pure PowerShell 5.1 so it can run on a
    box with no Python and no admin rights -- e.g. an RDP dev server inside the Bahra network.

    STRICTLY READ-ONLY. It sends only `user`, `pass`, `read` and `quit`. It never writes a Shared
    Data variable, never changes a setting, and never touches the scale's calibration.

    Protocol, from the IND570 Shared Data Reference (30205337 rev 04, section 1.10):

        connect  ->  "user <name>"  ->  "pass <pw>" if the terminal answers "51 Enter Password"
                 ->  "read wt0101 wt0102 wt0103"  ->  "quit"

        A read replies   00R003~ 24680.00~10230.00~kg~
                         ^^ "00" success, "99" failure; then values, "~"-separated, in order.

.EXAMPLE
    .\Probe-Weighbridge.ps1 10.20.30.40

.EXAMPLE
    .\Probe-Weighbridge.ps1 10.20.30.40 -Password s3cret -SettleCheck
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$TerminalIp,

    [int]$Port = 1701,
    [string]$User = 'admin',
    [string]$Password = '',
    [int]$TimeoutMs = 5000,

    # Read twice, half a second apart, and report whether the deck had settled.
    [switch]$SettleCheck,

    # How long to listen, saying nothing, before deciding what kind of port this is.
    [int]$SniffMs = 2500
)

$ErrorActionPreference = 'Stop'
$script:buf = ''

# Set once the socket is open. It changes what a failure means: before it, the problem is the
# network or the terminal's Ethernet; after it, we are talking to the terminal and the problem is
# a credential or a setting. Printing the wrong checklist sends someone to the plant for nothing.
$script:reachedTerminal = $false

function Write-Step { param([string]$Text) Write-Host "  $Text" -ForegroundColor DarkGray }
function Write-Good { param([string]$Text) Write-Host "  $Text" -ForegroundColor Green }
function Write-Bad  { param([string]$Text) Write-Host "  $Text" -ForegroundColor Red }

function Read-SdLine {
    param([System.Net.Sockets.NetworkStream]$Stream, [switch]$Optional)

    $bytes = New-Object byte[] 1024
    while ($script:buf.IndexOf("`r`n") -lt 0) {
        try {
            $n = $Stream.Read($bytes, 0, $bytes.Length)
        } catch {
            if ($Optional) { return '' }
            throw "Timed out waiting for a reply from the terminal."
        }
        if ($n -le 0) {
            if ($Optional) { return '' }
            throw "The terminal closed the connection."
        }
        $script:buf += [Text.Encoding]::ASCII.GetString($bytes, 0, $n)
    }
    $i = $script:buf.IndexOf("`r`n")
    $line = $script:buf.Substring(0, $i)
    $script:buf = $script:buf.Substring($i + 2)
    return $line.Trim()
}

function Get-UnsolicitedData {
    <#
        Listen without sending anything, and report what arrives.

        This is the whole question about Bahra's terminals. Port 1701 carries the Shared Data
        Server (silent until asked) but the IND570 also serves the Console Print Server and EPrint,
        which push a continuous stream at whoever connects. Same port number, opposite contract.
        Saying nothing for a moment tells them apart with certainty, where reading the manual does
        not.
    #>
    param([System.Net.Sockets.NetworkStream]$Stream, [int]$Ms)

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $bytes = New-Object byte[] 4096
    $text = ''
    while ($sw.ElapsedMilliseconds -lt $Ms) {
        if ($Stream.DataAvailable) {
            $n = $Stream.Read($bytes, 0, $bytes.Length)
            if ($n -gt 0) { $text += [Text.Encoding]::ASCII.GetString($bytes, 0, $n) }
        } else {
            Start-Sleep -Milliseconds 50
        }
    }
    return $text
}

function Send-SdCommand {
    param([System.Net.Sockets.NetworkStream]$Stream, [string]$Text)

    $data = [Text.Encoding]::ASCII.GetBytes($Text + "`r`n")
    $Stream.Write($data, 0, $data.Length)
    $Stream.Flush()
    return (Read-SdLine -Stream $Stream)
}

function Read-Weight {
    param([System.Net.Sockets.NetworkStream]$Stream)

    # wt0101 displayed gross, wt0102 displayed net, wt0103 units (block WT, read-only).
    $reply = Send-SdCommand -Stream $Stream -Text 'read wt0101 wt0102 wt0103'
    if (-not $reply.StartsWith('00')) {
        throw "The terminal refused the read: '$reply'  (00 = success, 99 = failure)"
    }
    $values = ($reply -split '~', 2)[1] -split '~' | ForEach-Object { $_.Trim() }
    return [pscustomobject]@{
        Raw   = $reply
        Gross = $values[0]
        Net   = $values[1]
        Unit  = $values[2]
    }
}

Write-Host ''
Write-Host "IND570 probe  ->  ${TerminalIp}:${Port}" -ForegroundColor Cyan
Write-Host ''

# --- 1. is the port open at all? -------------------------------------------

Write-Host 'Step 1  Is anybody home?'
try {
    $t = Test-NetConnection -ComputerName $TerminalIp -Port $Port -WarningAction SilentlyContinue
    if ($t.PingSucceeded) {
        Write-Step 'ping        replies'
    } else {
        Write-Step 'ping        no reply (often just ICMP blocked -- not fatal on its own)'
    }
    if ($t.TcpTestSucceeded) {
        Write-Good "tcp $Port    open"
    } else {
        Write-Bad "tcp $Port    closed or filtered"
    }
} catch {
    Write-Step 'Test-NetConnection unavailable; going straight to a direct socket.'
}

# --- 2. the conversation ----------------------------------------------------

Write-Host ''
Write-Host 'Step 2  Can we hold a conversation?'

$client = New-Object System.Net.Sockets.TcpClient
$stream = $null
try {
    $iar = $client.BeginConnect($TerminalIp, $Port, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) {
        throw "Could not connect within $TimeoutMs ms."
    }
    $client.EndConnect($iar)
    $script:reachedTerminal = $true
    Write-Good "connect     ok  (port $Port accepted the connection)"

    $stream = $client.GetStream()
    $stream.ReadTimeout = $TimeoutMs
    $stream.WriteTimeout = $TimeoutMs

    Write-Step "listening   $SniffMs ms, sending nothing ..."
    $unsolicited = Get-UnsolicitedData -Stream $stream -Ms $SniffMs
    $lines = @($unsolicited -split "`r?`n" | Where-Object { $_.Trim() })

    # Two or more unprompted lines that carry no "00R001~" status header is a push stream, not the
    # Shared Data Server. Reporting that is the point of this probe -- it decides how the agent
    # reads the weight, and no amount of manual-reading settles it.
    $isStream = ($lines.Count -ge 2) -and -not ($lines[0] -match '^\d\d[A-Za-z]\d*~')

    if ($isStream) {
        Write-Host ''
        Write-Host 'Result' -ForegroundColor Cyan
        Write-Good "This port PUSHES a continuous stream. It is not the Shared Data Server."
        Write-Host ''
        Write-Host "  $($lines.Count) lines arrived in $SniffMs ms without us asking. First few:" -ForegroundColor DarkGray
        foreach ($l in ($lines | Select-Object -First 6)) { Write-Host "    $l" }
        Write-Host ''
        Write-Host '  What this means:' -ForegroundColor Yellow
        Write-Host '    The agent must PARSE THIS STREAM rather than log in and issue "read".'
        Write-Host '    Send these lines to whoever is building the agent -- the column layout is'
        Write-Host '    all that is needed to finish it.'
        Write-Host ''
        Write-Host "    Port 1701 also carries the Shared Data Server. If you probed 1701 and got"
        Write-Host "    this, try the request/response path too -- some firmware serves both."
        Write-Host ''
        exit 0
    }

    if ($lines.Count -eq 1) {
        Write-Step "greeting    '$($lines[0])'"
    } else {
        Write-Step 'greeting    (silent -- consistent with the Shared Data Server)'
    }

    $reply = Send-SdCommand -Stream $stream -Text "user $User"
    Write-Step "user $User  -> '$reply'"
    if ($reply.StartsWith('51')) {
        if (-not $Password) {
            throw "The terminal wants a password. Re-run with -Password '<Shared Data Server password>'."
        }
        $reply = Send-SdCommand -Stream $stream -Text "pass $Password"
        Write-Step "pass ****   -> '$reply'"
    }
    if (-not $reply.StartsWith('12')) {
        throw "Login refused: '$reply'  (expected '12 Access OK')"
    }
    Write-Good 'login       ok'

    $first = Read-Weight -Stream $stream
    Write-Step "read        '$($first.Raw)'"

    $settled = $null
    if ($SettleCheck) {
        Start-Sleep -Milliseconds 500
        $second = Read-Weight -Stream $stream
        Write-Step "read again  '$($second.Raw)'"
        $settled = ($first.Gross -eq $second.Gross)
    }

    Write-Host ''
    Write-Host 'Result' -ForegroundColor Cyan
    Write-Good "gross       $($first.Gross) $($first.Unit)"
    Write-Good "net         $($first.Net) $($first.Unit)"
    if ($null -ne $settled) {
        if ($settled) {
            Write-Good 'settled     yes -- two reads agreed, the deck is still'
        } else {
            Write-Bad  'settled     NO  -- the two reads differed. Do not file this weight.'
        }
    }
    Write-Host ''
    Write-Host "Reachable from this machine. Record the IP: $TerminalIp" -ForegroundColor Green
    Write-Host ''
}
catch {
    Write-Host ''
    Write-Bad "FAILED: $($_.Exception.Message)"
    Write-Host ''

    if ($script:reachedTerminal) {
        # The network is fine -- we opened the socket and it answered. Do not send anyone to the
        # plant to look at cabling; this is a credential or a Shared Data Server setting.
        Write-Host 'The good news: the network path works. This machine reached the terminal and it' -ForegroundColor Yellow
        Write-Host 'replied. What failed is the login or the read, so check:' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  - The Shared Data Server username and password.'
        Write-Host '    Terminal: Communication > Network > Shared Data Server. Ask Bahra for the'
        Write-Host '    credentials rather than guessing -- repeated bad logins can lock the port.'
        Write-Host ''
        Write-Host '  - That the wt01xx variables are readable on this firmware. Try one at a time:'
        Write-Host '    wt0101 (gross), wt0102 (net), wt0103 (units).'
        Write-Host ''
        Write-Host "  Record for the project: $TerminalIp`:$Port is REACHABLE from this machine." -ForegroundColor Green
        Write-Host ''
        exit 1
    }

    Write-Host 'Check these four things, in this order:' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  1. Is the optional Ethernet interface physically fitted to the IND570?'
    Write-Host '     Without it the terminal has no network port at all -- only RS-232 on COM1 --'
    Write-Host '     and no amount of network work will help. Check this one first.'
    Write-Host ''
    Write-Host '  2. Is the IP right? On the terminal: Communication > Network.'
    Write-Host "     You used $TerminalIp."
    Write-Host ''
    Write-Host '  3. Is the Shared Data Server switched ON in the terminal, on port 1701?'
    Write-Host '     It can be disabled, and the port can be changed.'
    Write-Host ''
    Write-Host '  4. Is THIS machine allowed to reach the plant network?'
    Write-Host '     A dev server usually sits on a different VLAN from the plant floor, and the'
    Write-Host '     firewall between them commonly blocks everything by default. A failure HERE'
    Write-Host '     does not prove the scale is unreachable -- only that this box cannot reach it.'
    Write-Host '     Ask Bahra IT to retest from a PC on the weighbridge VLAN before concluding.'
    Write-Host ''
    exit 1
}
finally {
    if ($stream) {
        try {
            $bye = [Text.Encoding]::ASCII.GetBytes("quit`r`n")
            $stream.Write($bye, 0, $bye.Length)
        } catch {}
        $stream.Close()
    }
    $client.Close()
}
