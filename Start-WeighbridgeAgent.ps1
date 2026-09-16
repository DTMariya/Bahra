<#
.SYNOPSIS
    Long-running agent. Watches the weighbridge terminals and posts one reading per weighing to
    Power Automate.

.DESCRIPTION
    For each terminal it holds two sockets open:

      port 8000  continuous output, ~20 Hz. Free arrival detection -- costs no requests and puts
                 no load on the Shared Data Server. Middle number non-zero means a truck is on.
      port 1701  Shared Data Server, request/response. The authoritative reading, with named
                 variables including wx0131 Motion.

    Per terminal, a four-state machine:

      IDLE      deck empty (|weight| < EmptyDeadband). Nothing to do.
      OCCUPIED  something on the deck. Poll 1701 every PollIntervalMs.
      CAPTURED  every reading for SettleSeconds stayed within SettleTolerance, and wx0131 says
                "not moving". Posted, then watched for a corrected weight.
      (back to IDLE when the deck clears)

    Posting once is not enough. The weight the gate office writes down is the one AFTER the driver
    climbs out of the cab -- a driver is around 80 kg, so the first settled weight is the wrong
    one. While a truck stays on the deck the agent therefore keeps watching port 8000, and when
    the deck holds a new weight for UpdateSteadySeconds it re-reads 1701 and posts an update:

      a DROP over ChangeThreshold          the driver got down. This is the number that counts.
      a RISE over MajorIncrease            we captured while the truck was only part-way on.
      a rise smaller than that             the driver climbing back in. Ignored deliberately,
                                           or the last thing sent would be the driver-in weight.

    Downstream must keep the LATEST reading for a truck (highest "sequence"), not the first.

    wx0131 is Motion, not "settled": 0 = No, 1 = Yes (Shared Data Reference p24, and section
    2.2.1.2 p38 -- "a measure of whether the weight has settled on the scale"). We send when it
    reads 0. Getting this backwards files every weight while the truck is still rolling, and
    nothing downstream can tell.

    READ-ONLY against the terminals. Sends only user / pass / read / quit. Never writes a Shared
    Data variable, never touches calibration.

    A failed POST is queued to disk and retried, so a Power Automate outage delays weighings
    rather than losing them.

.EXAMPLE
    .\Start-WeighbridgeAgent.ps1 -ConfigPath .\weighbridge-agent.config.json

.EXAMPLE
    # Watch what it would do without posting anything
    .\Start-WeighbridgeAgent.ps1 -DryRun -Verbose
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\weighbridge-agent.config.json",

    # Run the state machine and log, but never POST. The safe first run on a live plant.
    [switch]$DryRun,

    # Stop after this many seconds. 0 = run until stopped. For smoke tests.
    [int]$RunForSeconds = 0
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------- config
if (-not (Test-Path $ConfigPath)) {
    throw "No config at $ConfigPath. Copy weighbridge-agent.config.sample.json and fill it in."
}
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

function Get-Setting {
    param([string]$Name, $Default)
    $p = $cfg.PSObject.Properties[$Name]
    if ($null -ne $p -and $null -ne $p.Value -and "$($p.Value)" -ne '') { return $p.Value }
    return $Default
}

$StreamPort       = [int](Get-Setting 'streamPort' 8000)
$SdPort           = [int](Get-Setting 'sharedDataPort' 1701)
$SdUser           = [string](Get-Setting 'user' 'admin')
$SdPassword       = [string](Get-Setting 'password' '')
$EmptyDeadband    = [double](Get-Setting 'emptyDeadband' 100)
$SettleSeconds    = [double](Get-Setting 'settleSeconds' 30)
$SettleTolerance  = [double](Get-Setting 'settleTolerance' 200)
$ChangeThreshold  = [double](Get-Setting 'changeThreshold' 40)
$UpdateSteadySecs = [double](Get-Setting 'updateSteadySeconds' 15)
$MajorIncrease    = [double](Get-Setting 'majorIncreaseKg' 500)
$MaxUpdates       = [int](Get-Setting 'maxUpdatesPerTruck' 4)
$PollIntervalMs   = [int](Get-Setting 'pollIntervalMs' 300)
$MaxWeighingSecs  = [int](Get-Setting 'maxWeighingSeconds' 300)
$UtcOffsetHours   = [double](Get-Setting 'utcOffsetHours' 3)
$StreamField      = [int](Get-Setting 'streamWeightField' 1)   # 0-based, in '10  22940  00'
$ReconnectMinMs   = [int](Get-Setting 'reconnectMinMs' 2000)
$ReconnectMaxMs   = [int](Get-Setting 'reconnectMaxMs' 60000)
$QueueRetrySecs   = [int](Get-Setting 'queueRetrySeconds' 60)
$FlowUrl          = [string](Get-Setting 'flowUrl' '')
$LogRetentionDays = [int](Get-Setting 'logRetentionDays' 30)
$QueueWarnDepth   = [int](Get-Setting 'queueWarnDepth' 5)
$HeartbeatSecs    = [int](Get-Setting 'heartbeatSeconds' 15)
$StuckCapturedMins= [int](Get-Setting 'stuckCapturedMinutes' 30)

$LogDir   = Join-Path $PSScriptRoot ([string](Get-Setting 'logPath' 'logs'))
$QueueDir = Join-Path $PSScriptRoot ([string](Get-Setting 'queuePath' 'queue'))
foreach ($d in $LogDir, $QueueDir) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null } }
$HeartbeatPath = Join-Path $PSScriptRoot 'heartbeat.json'

if (-not $DryRun -and [string]::IsNullOrWhiteSpace($FlowUrl)) {
    throw "flowUrl is empty in $ConfigPath. Set it, or run with -DryRun."
}
if (-not $cfg.terminals -or @($cfg.terminals).Count -eq 0) {
    throw "No terminals in $ConfigPath."
}

# ---------------------------------------------------------------------------- logging
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO', [string]$Colour = 'Gray')
    $now  = Get-Date
    $line = '{0} [{1,-5}] {2}' -f $now.ToString('yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    Write-Host $line -ForegroundColor $Colour
    $file = Join-Path $LogDir ('agent-{0}.log' -f $now.ToString('yyyy-MM-dd'))
    Add-Content -Path $file -Value $line -Encoding UTF8
}

function Remove-OldLogs {
    if ($LogRetentionDays -le 0) { return }
    $cutoff = (Get-Date).AddDays(-$LogRetentionDays)
    $old = @(Get-ChildItem $LogDir -Filter 'agent-*.log' -ErrorAction SilentlyContinue |
             Where-Object { $_.LastWriteTime -lt $cutoff })
    foreach ($f in $old) {
        try { Remove-Item $f.FullName -Force; Write-Log "removed old log $($f.Name)" 'INFO' 'DarkGray' } catch {}
    }
}

function Write-Heartbeat {
    <#
        Proof of life for monitoring. A service can sit in state "Running" with a wedged loop,
        which is the failure nothing else here catches -- you would find out days later from a
        gap in the data. Test-WeighbridgeAgent.ps1 reads this file and shouts if it goes stale.
    #>
    param($Terminals, [int]$QueueDepth)
    $hb = [ordered]@{
        writtenAt    = (Get-Date).ToString('o')
        pid          = $PID
        startedAt    = $script:AgentStarted.ToString('o')
        uptimeMin    = [math]::Round(((Get-Date) - $script:AgentStarted).TotalMinutes, 1)
        dryRun       = [bool]$DryRun
        queueDepth   = $QueueDepth
        sentTotal    = $script:SentTotal
        terminals    = @($Terminals | ForEach-Object {
            [ordered]@{
                name    = $_.Name
                host    = $_.Host
                state   = $_.State
                stream  = ($null -ne $_.StreamClient)
                sd      = ($null -ne $_.SdClient)
                weight  = $_.LastStreamWeight
            }
        })
    }
    try { $hb | ConvertTo-Json -Depth 4 -Compress | Set-Content -Path $HeartbeatPath -Encoding UTF8 } catch {}
}

function Test-QueueDepth {
    $depth = @(Get-ChildItem $QueueDir -Filter '*.json' -ErrorAction SilentlyContinue).Count
    if ($depth -ge $QueueWarnDepth -and $depth -ne $script:LastQueueDepth) {
        Write-Log "QUEUE DEPTH $depth -- Power Automate has been unreachable long enough that someone should look" 'ALARM' 'Red'
    }
    $script:LastQueueDepth = $depth
    return $depth
}

# ---------------------------------------------------------------------------- sockets
function Connect-Socket {
    param([string]$TerminalHost, [int]$Port, [int]$TimeoutMs = 4000)
    $client = New-Object System.Net.Sockets.TcpClient
    $ar = $client.BeginConnect($TerminalHost, $Port, $null, $null)
    if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs)) { $client.Close(); throw "connect timeout" }
    $client.EndConnect($ar)
    $client.NoDelay = $true
    return $client
}

function Close-Socket {
    param($Client)
    if ($null -ne $Client) { try { $Client.Close() } catch {} }
}

function Get-Backoff {
    param([int]$Failures)
    $ms = $ReconnectMinMs * [Math]::Pow(2, [Math]::Min($Failures, 6))
    return [int][Math]::Min($ms, $ReconnectMaxMs)
}

# ---------------------------------------------------------------------------- shared data
function Read-SdLine {
    param($T, [int]$TimeoutMs = 3000)
    $bytes = New-Object byte[] 2048
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($T.SdBuf.IndexOf("`r`n") -lt 0) {
        if ($sw.Elapsed.TotalMilliseconds -gt $TimeoutMs) { throw "read timeout" }
        if ($T.SdStream.DataAvailable) {
            $n = $T.SdStream.Read($bytes, 0, $bytes.Length)
            if ($n -le 0) { throw "closed by terminal" }
            $T.SdBuf += [Text.Encoding]::ASCII.GetString($bytes, 0, $n)
        } else {
            Start-Sleep -Milliseconds 5
        }
    }
    $i = $T.SdBuf.IndexOf("`r`n")
    $line = $T.SdBuf.Substring(0, $i)
    $T.SdBuf = $T.SdBuf.Substring($i + 2)

    # The terminal emits a '>' prompt. Sometimes it is a line of its own arriving a moment after
    # the greeting -- which is how "login refused: >" happened on real hardware -- and it can also
    # arrive glued to the front of the next reply, as ">00R002~...". Stripping leading '>' and
    # whitespace from every line handles both, and no real Shared Data reply starts with '>'.
    return ($line -replace '^[\s>]+', '').TrimEnd()
}

function Send-SdCommand {
    param($T, [string]$Text)
    # CR alone. The terminal terminates on CR and reads a trailing LF as a second, empty command,
    # which draws a spurious "83 Command not recognized" and desynchronises the next reply.
    $b = [Text.Encoding]::ASCII.GetBytes($Text + "`r")
    $T.SdStream.Write($b, 0, $b.Length)
    $T.SdStream.Flush()
}

function Connect-SharedData {
    param($T)
    $T.SdClient = Connect-Socket -TerminalHost $T.Host -Port $SdPort
    $T.SdStream = $T.SdClient.GetStream()
    $T.SdBuf = ''

    # Do NOT assume the greeting is one clean line. Real hardware led with a blank line, so
    # reading exactly one line consumed the blank and then matched "53 Ready for user" against
    # the reply to `user` -- reported as "login refused: 53 Ready for user". Drain whatever
    # arrives, however many lines, then look for a real status code.
    Start-Sleep -Milliseconds 300
    $greeting = ''
    while ($T.SdStream.DataAvailable -or $T.SdBuf.IndexOf("`r`n") -ge 0) {
        $l = Read-SdLine $T
        if ($l.Trim() -ne '') { $greeting = $l.Trim() }
    }

    Send-SdCommand $T "user $SdUser"

    # 12 = access granted, 51 = password required, 53 = a greeting that arrived late.
    $ok = $false
    for ($i = 0; $i -lt 6; $i++) {
        $r = (Read-SdLine $T).Trim()
        if ($r -eq '') { continue }
        if ($r -like '12*') { $ok = $true; break }
        if ($r -like '51*') { Send-SdCommand $T "pass $SdPassword"; continue }
        if ($r -like '53*') { $greeting = $r; continue }
        throw "login refused: $r"
    }
    if (-not $ok) { throw "login: no status code after 6 lines" }

    Write-Log "$($T.Name): 1701 connected ($greeting)" 'INFO' 'Green'
}

function Invoke-SdRead {
    param($T, [string]$Vars)

    # Drain anything left over from the last command -- typically the '>' prompt, which arrives
    # after the reply we already consumed. Left in place it becomes the "reply" to this command.
    while ($T.SdStream.DataAvailable -or $T.SdBuf.IndexOf("`r`n") -ge 0) { [void](Read-SdLine $T) }

    Send-SdCommand $T "read $Vars"

    $line = ''
    for ($i = 0; $i -lt 5; $i++) {
        $line = Read-SdLine $T
        if ($line -eq '') { continue }              # a prompt line, already stripped to nothing
        if ($line -match '^83') { continue }        # spurious "command not recognized"
        break
    }
    $T.LastSdReply = $line
    if ($line -notmatch '^00') { throw "read failed: '$line'" }
    $parts = $line -split '~'
    # parts[0] is the status header; values follow, trailing empty from the final '~'
    $values = @()
    for ($i = 1; $i -lt $parts.Count; $i++) {
        if ($i -eq $parts.Count - 1 -and $parts[$i] -eq '') { break }
        $values += $parts[$i].Trim()
    }
    return $values
}

# ---------------------------------------------------------------------------- stream
function Connect-Stream {
    param($T)
    $T.StreamClient = Connect-Socket -TerminalHost $T.Host -Port $StreamPort
    $T.StreamStream = $T.StreamClient.GetStream()
    $T.StreamBuf = ''
    $T.StreamPrimed = $false      # first line is a partial frame; we joined mid-stream
    Write-Log "$($T.Name): $StreamPort connected" 'INFO' 'Green'
}

function Get-StreamWeight {
    <#
        Drain everything waiting and return the weight from the LAST complete frame, or $null if
        no complete frame arrived. At 20 Hz there are usually several; only the newest matters.
    #>
    param($T)

    $bytes = New-Object byte[] 8192
    while ($T.StreamStream.DataAvailable) {
        $n = $T.StreamStream.Read($bytes, 0, $bytes.Length)
        if ($n -le 0) { throw "closed by terminal" }
        $T.StreamBuf += [Text.Encoding]::ASCII.GetString($bytes, 0, $n)
    }

    $latest = $null
    while ($true) {
        $i = $T.StreamBuf.IndexOfAny([char[]]@("`r", "`n"))
        if ($i -lt 0) { break }
        $text = $T.StreamBuf.Substring(0, $i)
        $T.StreamBuf = $T.StreamBuf.Substring($i + 1).TrimStart(@("`r", "`n"))

        if (-not $T.StreamPrimed) {
            # We connected mid-frame, so this one is truncated -- 'D10  22940  00'. Never parse it.
            $T.StreamPrimed = $true
            continue
        }
        if ($text.Trim() -eq '') { continue }

        $fields = @($text.Trim() -split '\s+')
        if ($fields.Count -le $StreamField) { continue }
        $raw = $fields[$StreamField]
        $parsed = 0.0
        if ([double]::TryParse($raw, [ref]$parsed)) { $latest = $parsed; $T.LastStreamLine = $text.Trim() }
    }
    return $latest
}

# ---------------------------------------------------------------------------- posting
function New-Payload {
    param($T, [double]$Weight, [string]$Unit, [int]$Sequence = 1)
    return [ordered]@{
        sequence  = $Sequence     # 1 = first post for this truck, 2+ = a corrected weight
        gate      = [int]$T.Gate
        direction = [int]$T.Direction
        weight    = $Weight
        unit      = $Unit
        time      = [datetimeoffset]::UtcNow.ToOffset([timespan]::FromHours($UtcOffsetHours)).ToString('yyyy-MM-ddTHH:mm:sszzz')
        terminal  = $T.Host
        settled   = $true
    }
}

function Send-ToFlow {
    param($Payload)
    $json = $Payload | ConvertTo-Json -Compress
    if ([string]::IsNullOrWhiteSpace($json)) { throw "payload did not serialise" }
    if ($DryRun) {
        Write-Log "DRY RUN, not posted: $json" 'DRY' 'Magenta'
        return $true
    }
    try {
        $r = Invoke-WebRequest -Uri $FlowUrl -Method Post -Body $json -ContentType 'application/json' -UseBasicParsing -TimeoutSec 30
        $runId = $r.Headers['x-ms-workflow-run-id']
        Write-Log ("posted HTTP {0}{1}" -f [int]$r.StatusCode, $(if ($runId) { " run $runId" } else { '' })) 'SEND' 'Green'
        return $true
    } catch {
        Write-Log "POST failed: $($_.Exception.Message)" 'WARN' 'Yellow'
        return $false
    }
}

function Read-Terminal {
    <#
        One authoritative 1701 read. Throws if the socket is bad -- the caller drops the connection
        and reconnects. Returns $null for a reply that arrived but made no sense, which is not
        worth a reconnect.
    #>
    param($T)
    $v = Invoke-SdRead $T 'wt0101 wt0102 wt0103 wx0131 wx0133 wx0134'
    if ($v.Count -lt 6) {
        Write-Log "$($T.Name): short reply, got $($v.Count) values" 'WARN' 'Yellow'
        return $null
    }
    $g = 0.0
    if (-not [double]::TryParse($v[0], [ref]$g)) {
        Write-Log "$($T.Name): unparseable gross '$($v[0])'" 'WARN' 'Yellow'
        return $null
    }
    return @{
        Gross = $g; Net = $v[1]; Unit = $v[2]
        Motion = $v[3]      # wx0131  0 = No, 1 = Yes
        Over = $v[4]        # wx0133
        Under = $v[5]       # wx0134
    }
}

function Send-Reading {
    param($T, [double]$Weight, [string]$Unit)
    $T.Sequence++
    $payload = New-Payload -T $T -Weight $Weight -Unit $Unit -Sequence $T.Sequence
    # Do not count a dry run as sent -- "sent 3" in a heartbeat nobody posted is worse than no
    # number at all.
    if (Send-ToFlow $payload) { if (-not $DryRun) { $script:SentTotal++ } } else { Add-ToQueue $payload }
    $T.SentWeight = $Weight
}

function Add-ToQueue {
    param($Payload)
    $name = 'weighing-{0}-{1}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), ([guid]::NewGuid().ToString('N').Substring(0, 6))
    $path = Join-Path $QueueDir $name
    $Payload | ConvertTo-Json -Compress | Set-Content -Path $path -Encoding UTF8
    Write-Log "queued to $name -- will retry" 'WARN' 'Yellow'
}

function Invoke-QueueRetry {
    $files = @(Get-ChildItem $QueueDir -Filter '*.json' -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { return }
    Write-Log "retrying $($files.Count) queued weighing(s)" 'INFO' 'DarkGray'
    foreach ($f in $files) {
        try {
            $payload = Get-Content $f.FullName -Raw | ConvertFrom-Json
        } catch {
            Write-Log "queue file $($f.Name) is corrupt, leaving it alone" 'WARN' 'Yellow'
            continue
        }
        if (Send-ToFlow $payload) { Remove-Item $f.FullName -Force }
        else { break }   # still down; stop hammering
    }
}

# ---------------------------------------------------------------------------- state
$terminals = @()
foreach ($t in $cfg.terminals) {
    $terminals += @{
        Name = [string]$t.name; Host = [string]$t.host
        Gate = $t.gate; Direction = $t.direction

        StreamClient = $null; StreamStream = $null; StreamBuf = ''; StreamPrimed = $false
        SdClient = $null; SdStream = $null; SdBuf = ''

        State = 'IDLE'
        LastStreamWeight = 0.0
        SettleSince = $null; SettleMin = 0.0; SettleMax = 0.0
        LastPollAt = [datetime]::MinValue
        OccupiedSince = $null
        CapturedAt = $null
        GaveUp = $false

        # Diagnostics only -- none of these change what is sent.
        LastStreamLine = ''; LastSdReply = ''
        SentWeight = $null; PeakWeight = 0.0; Sequence = 0; Updates = 0
        SteadyWeight = $null; SteadySince = $null; PlateauDone = $null

        StreamFailures = 0; SdFailures = 0
        NextStreamRetryAt = [datetime]::MinValue
        NextSdRetryAt = [datetime]::MinValue
    }
}

function Set-State {
    param($T, [string]$New, [string]$Why)
    if ($T.State -eq $New) { return }
    Write-Log ("$($T.Name): {0} -> {1}  ({2})" -f $T.State, $New, $Why) 'STATE' 'Cyan'
    $T.State = $New
}

# ---------------------------------------------------------------------------- single instance
# Two copies running would double-post every weighing, and each would fight the other for the
# terminal's limited Shared Data sessions. Global\ so it holds across user sessions and services.
$mutex = New-Object System.Threading.Mutex($false, 'Global\BahraWeighbridgeAgent')
$haveMutex = $false
try { $haveMutex = $mutex.WaitOne(0, $false) } catch [System.Threading.AbandonedMutexException] {
    # Previous instance was killed rather than stopped. The lock is ours and the state is fine.
    $haveMutex = $true
}
if (-not $haveMutex) {
    Write-Log "another agent is already running on this machine -- refusing to start a second one" 'FATAL' 'Red'
    exit 1
}

# ---------------------------------------------------------------------------- main
$script:AgentStarted   = Get-Date
$script:SentTotal      = 0
$script:LastQueueDepth = -1

Write-Log ("agent starting -- {0} terminal(s), stream :{1}, shared data :{2}{3}" -f `
    $terminals.Count, $StreamPort, $SdPort, $(if ($DryRun) { ', DRY RUN' } else { '' })) 'INFO' 'White'
Write-Log "empty deadband +/-$EmptyDeadband, settle needs ${SettleSeconds}s with readings no more than $SettleTolerance apart, poll every ${PollIntervalMs}ms" 'INFO' 'DarkGray'
Write-Log "heartbeat -> $HeartbeatPath every ${HeartbeatSecs}s, logs kept ${LogRetentionDays} days, queue alarm at $QueueWarnDepth" 'INFO' 'DarkGray'

$started = Get-Date
$lastQueueRetry = Get-Date
$lastHeartbeat  = [datetime]::MinValue
$lastLogSweep   = [datetime]::MinValue

try {
    while ($true) {
        if ($RunForSeconds -gt 0 -and ((Get-Date) - $started).TotalSeconds -ge $RunForSeconds) {
            Write-Log "RunForSeconds reached, stopping" 'INFO' 'White'
            break
        }
        $now = Get-Date

        foreach ($T in $terminals) {

            # -- keep the stream socket up -------------------------------------------------
            if ($null -eq $T.StreamClient -and $now -ge $T.NextStreamRetryAt) {
                try {
                    Connect-Stream $T
                    $T.StreamFailures = 0
                } catch {
                    $T.StreamFailures++
                    $wait = Get-Backoff $T.StreamFailures
                    $T.NextStreamRetryAt = $now.AddMilliseconds($wait)
                    if ($T.StreamFailures -le 3 -or $T.StreamFailures % 10 -eq 0) {
                        Write-Log "$($T.Name): $StreamPort unreachable ($($_.Exception.Message)), retry in $([int]($wait/1000))s [attempt $($T.StreamFailures)]" 'WARN' 'Yellow'
                    }
                    Close-Socket $T.StreamClient; $T.StreamClient = $null
                }
            }

            # -- read the deck -------------------------------------------------------------
            if ($null -ne $T.StreamClient) {
                try {
                    $w = Get-StreamWeight $T
                    if ($null -ne $w) { $T.LastStreamWeight = $w }
                } catch {
                    Write-Log "$($T.Name): stream dropped ($($_.Exception.Message))" 'WARN' 'Yellow'
                    Close-Socket $T.StreamClient; $T.StreamClient = $null
                    $T.StreamFailures++
                    $T.NextStreamRetryAt = $now.AddMilliseconds((Get-Backoff $T.StreamFailures))
                }
            }

            # How long port 8000 has held one weight, give or take ChangeThreshold. This is what
            # spots the driver climbing out, and it costs nothing -- the stream is free.
            if ($null -eq $T.SteadySince -or [Math]::Abs($T.LastStreamWeight - $T.SteadyWeight) -gt $ChangeThreshold) {
                $T.SteadyWeight = $T.LastStreamWeight; $T.SteadySince = $now
            }

            $occupied = ([Math]::Abs($T.LastStreamWeight) -ge $EmptyDeadband)

            # -- IDLE ----------------------------------------------------------------------
            if (-not $occupied) {
                if ($T.State -ne 'IDLE') {
                    Write-Log ("$($T.Name): truck gone -- last sent {0} ({1} update(s)), highest on deck {2}" -f `
                        $(if ($null -ne $T.SentWeight) { $T.SentWeight } else { 'nothing' }), $T.Updates, $T.PeakWeight) 'DIAG' 'DarkCyan'
                    $T.SentWeight = $null; $T.PeakWeight = 0.0; $T.PlateauDone = $null
                    $T.Sequence = 0; $T.Updates = 0
                    Set-State $T 'IDLE' "deck clear ($($T.LastStreamWeight))"
                    $T.SettleSince = $null
                    $T.OccupiedSince = $null
                    $T.CapturedAt = $null
                    $T.GaveUp = $false
                }
                continue
            }

            # -- arrival -------------------------------------------------------------------
            if ($T.State -eq 'IDLE') {
                Set-State $T 'OCCUPIED' "weight $($T.LastStreamWeight) on deck"
                $T.OccupiedSince = $now
                $T.SettleSince = $null
            }
            if ($T.LastStreamWeight -gt $T.PeakWeight) { $T.PeakWeight = $T.LastStreamWeight }

            # -- keep the shared data socket up --------------------------------------------
            # Above the latch, because a captured truck still needs 1701 to confirm a corrected
            # weight once the driver is out.
            if ($null -eq $T.SdClient -and $now -ge $T.NextSdRetryAt) {
                try {
                    Connect-SharedData $T
                    $T.SdFailures = 0
                } catch {
                    $T.SdFailures++
                    $wait = Get-Backoff $T.SdFailures
                    $T.NextSdRetryAt = $now.AddMilliseconds($wait)
                    if ($T.SdFailures -le 3 -or $T.SdFailures % 10 -eq 0) {
                        Write-Log "$($T.Name): $SdPort unavailable ($($_.Exception.Message)), retry in $([int]($wait/1000))s" 'WARN' 'Yellow'
                    }
                    Close-Socket $T.SdClient; $T.SdClient = $null
                }
            }
            if ($null -eq $T.SdClient) { continue }

            # Sent once for this truck. Watch for the weight that actually counts.
            if ($T.State -eq 'CAPTURED') {
                $steadyFor = ($now - $T.SteadySince).TotalSeconds
                $delta     = $T.SteadyWeight - $T.SentWeight

                if ($null -ne $T.SentWeight -and $steadyFor -ge $UpdateSteadySecs -and
                    [Math]::Abs($delta) -gt $ChangeThreshold -and $T.PlateauDone -ne $T.SteadyWeight) {

                    $T.PlateauDone = $T.SteadyWeight     # handle each new plateau once

                    if ($delta -gt 0 -and $delta -le $MajorIncrease) {
                        # Someone got back on. Sending this would replace the driver-out weight
                        # with the driver-in one, which is the number we are trying to avoid.
                        Write-Log ("$($T.Name): deck rose to {0} (+{1}) after sending {2} -- someone getting back on, not a load change. Left alone." -f `
                            $T.SteadyWeight, $delta, $T.SentWeight) 'DIAG' 'DarkCyan'
                    } elseif ($T.Updates -ge $MaxUpdates) {
                        Write-Log ("$($T.Name): deck now holds {0} but $MaxUpdates update(s) already sent for this truck -- not sending again." -f $T.SteadyWeight) 'WARN' 'Yellow'
                    } else {
                        $why = if ($delta -lt 0) { "driver out / load off" } else { "was only part-way on" }
                        try { $r = Read-Terminal $T } catch {
                            Write-Log "$($T.Name): 1701 read failed ($($_.Exception.Message))" 'WARN' 'Yellow'
                            Close-Socket $T.SdClient; $T.SdClient = $null
                            $T.SdFailures++
                            $T.NextSdRetryAt = $now.AddMilliseconds((Get-Backoff $T.SdFailures))
                            $T.PlateauDone = $null       # try this plateau again once reconnected
                            $r = $null
                        }
                        if ($null -ne $r -and $r.Motion -eq '0' -and $r.Over -ne '1' -and $r.Under -ne '1' -and
                            [Math]::Abs($r.Gross - $T.SentWeight) -gt $ChangeThreshold) {
                            $T.Updates++
                            Write-Log ("$($T.Name): CORRECTION -- deck held {0} for {1:N0}s ({2}); sent {3}, now sending {4}" -f `
                                $T.SteadyWeight, $steadyFor, $why, $T.SentWeight, $r.Gross) 'STATE' 'Cyan'
                            Send-Reading -T $T -Weight $r.Gross -Unit $r.Unit
                        } elseif ($null -ne $r) {
                            Write-Log ("$($T.Name): port 8000 moved to {0} but 1701 says gross {1}, motion {2} -- not sending" -f `
                                $T.SteadyWeight, $r.Gross, $r.Motion) 'DIAG' 'DarkCyan'
                        }
                    }
                }

                # A deck that never returns to empty leaves this terminal latched forever -- it
                # captures one weighing and then goes silent, which looks identical to "no trucks
                # today". Say so out loud rather than letting it disappear. Common causes: the
                # bridge needs re-zeroing, or something is parked on it.
                if ($null -ne $T.CapturedAt -and ((Get-Date) - $T.CapturedAt).TotalMinutes -ge $StuckCapturedMins) {
                    Write-Log ("$($T.Name): STILL LATCHED after $StuckCapturedMins min -- deck reads $($T.LastStreamWeight) and has not cleared, so no further weighing can be captured here. Check the bridge is empty and zeroed, or raise emptyDeadband.") 'ALARM' 'Red'
                    $T.CapturedAt = Get-Date    # re-arm the warning rather than repeating every loop
                }
                continue
            }

            # -- give up on a truck that never settles --------------------------------------
            if (-not $T.GaveUp -and $null -ne $T.OccupiedSince -and ($now - $T.OccupiedSince).TotalSeconds -gt $MaxWeighingSecs) {
                Write-Log "$($T.Name): on deck ${MaxWeighingSecs}s without settling -- not sending. Deck must clear before the next attempt." 'WARN' 'Yellow'
                $T.GaveUp = $true
            }
            if ($T.GaveUp) { continue }

            # -- poll 1701 ------------------------------------------------------------------
            if (($now - $T.LastPollAt).TotalMilliseconds -lt $PollIntervalMs) { continue }
            $T.LastPollAt = $now

            try {
                $r = Read-Terminal $T
            } catch {
                Write-Log "$($T.Name): 1701 read failed ($($_.Exception.Message))" 'WARN' 'Yellow'
                Close-Socket $T.SdClient; $T.SdClient = $null
                $T.SdFailures++
                $T.NextSdRetryAt = $now.AddMilliseconds((Get-Backoff $T.SdFailures))
                $T.SettleSince = $null     # unobserved time must not count toward settling
                continue
            }
            if ($null -eq $r) { continue }

            $gross = $r.Gross
            $unit  = $r.Unit

            if ($r.Over -eq '1' -or $r.Under -eq '1') {
                Write-Log "$($T.Name): refusing -- over capacity=$($r.Over) under zero=$($r.Under)" 'WARN' 'Yellow'
                $T.SettleSince = $null
                continue
            }

            # Settled = every reading for SettleSeconds within SettleTolerance of the others. A long
            # window, not a few reads: trucks stop part-way on the deck while lining up, and wx0131
            # reads "not moving" during that pause. On 2026-09-15 three reads in a row sent 9020
            # for a JV Scale OUT truck that then stood at 13700. The tolerance lets a wobble of a
            # division or two (13700 / 13780 on the same truck) through without restarting the wait.
            if ($null -eq $T.SettleSince -or
                ([Math]::Max($T.SettleMax, $gross) - [Math]::Min($T.SettleMin, $gross)) -gt $SettleTolerance) {
                if ($null -ne $T.SettleSince) { Write-Verbose "$($T.Name): weight moved to $gross, settle timer restarted" }
                $T.SettleSince = $now; $T.SettleMin = $gross; $T.SettleMax = $gross
                continue
            }
            $T.SettleMin = [Math]::Min($T.SettleMin, $gross)
            $T.SettleMax = [Math]::Max($T.SettleMax, $gross)

            # wx0131 == '0' means NOT moving. This is the comparison to never get backwards.
            # Required on the reading we send, not on every reading in the window.
            $settledFor = ($now - $T.SettleSince).TotalSeconds
            if ($settledFor -lt $SettleSeconds -or $r.Motion -ne '0') { continue }

            # -- settled --------------------------------------------------------------------
            Set-State $T 'CAPTURED' ("settled at $gross $unit -- held {0}-{1} for {2:N0}s" -f $T.SettleMin, $T.SettleMax, $settledFor)
            Write-Log ("$($T.Name): capture detail -- 1701 reply '{0}' (gross {1}, net {2}, unit {3}, motion {4}); port {5} at the same moment '{6}' = {7}" -f `
                $T.LastSdReply, $gross, $r.Net, $unit, $r.Motion, $StreamPort, $T.LastStreamLine, $T.LastStreamWeight) 'DIAG' 'DarkCyan'
            $T.CapturedAt = Get-Date
            $T.PlateauDone = $T.SteadyWeight    # the plateau we just sent is not a correction
            Send-Reading -T $T -Weight $gross -Unit $unit
            $T.SettleSince = $null
        }

        if (((Get-Date) - $lastQueueRetry).TotalSeconds -ge $QueueRetrySecs) {
            $lastQueueRetry = Get-Date
            Invoke-QueueRetry
        }

        if (((Get-Date) - $lastHeartbeat).TotalSeconds -ge $HeartbeatSecs) {
            $lastHeartbeat = Get-Date
            Write-Heartbeat -Terminals $terminals -QueueDepth (Test-QueueDepth)
        }

        # Once a day is plenty; a sweep walks the log directory.
        if (((Get-Date) - $lastLogSweep).TotalHours -ge 24) {
            $lastLogSweep = Get-Date
            Remove-OldLogs
        }

        Start-Sleep -Milliseconds 50
    }
} finally {
    Write-Log "shutting down, closing sockets" 'INFO' 'White'
    foreach ($T in $terminals) {
        if ($null -ne $T.SdClient) { try { Send-SdCommand $T 'quit' } catch {} }
        Close-Socket $T.SdClient
        Close-Socket $T.StreamClient
    }
    # Leave a final heartbeat marked stopped, so monitoring can tell a clean stop from a crash.
    try {
        if (Test-Path $HeartbeatPath) {
            $h = Get-Content $HeartbeatPath -Raw | ConvertFrom-Json
            $h | Add-Member -NotePropertyName 'stoppedAt' -NotePropertyValue ((Get-Date).ToString('o')) -Force
            $h | ConvertTo-Json -Depth 4 -Compress | Set-Content -Path $HeartbeatPath -Encoding UTF8
        }
    } catch {}
    if ($haveMutex) { try { $mutex.ReleaseMutex() } catch {}; $mutex.Dispose() }
}
