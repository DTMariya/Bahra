<#
.SYNOPSIS
    Health check for the weighbridge agent. Exit code 0 = healthy, 1 = degraded, 2 = down.

.DESCRIPTION
    Reads heartbeat.json, written by Start-WeighbridgeAgent.ps1 every few seconds, and judges it.

    The point is the failure nothing else catches: a service sitting in state "Running" with a
    wedged loop. Windows reports it healthy, the terminals look fine, and nobody notices until a
    day of weighings is missing. A stale heartbeat catches it in minutes.

    Meant to be called by monitoring, a scheduled task, or a person. Prints a summary and sets an
    exit code, so it drops into anything that checks exit codes.

.EXAMPLE
    .\Test-WeighbridgeAgent.ps1

.EXAMPLE
    # In a scheduled task, mail on failure
    .\Test-WeighbridgeAgent.ps1 -Quiet; if ($LASTEXITCODE -ne 0) { Send-MailMessage ... }
#>
[CmdletBinding()]
param(
    [string]$HeartbeatPath = "$PSScriptRoot\heartbeat.json",

    # Older than this and the agent is considered wedged or dead.
    [int]$StaleSeconds = 90,

    # Queued weighings at or above this count is degraded, not healthy.
    [int]$QueueWarnDepth = 5,

    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
function Say { param($m, $c = 'Gray') if (-not $Quiet) { Write-Host $m -ForegroundColor $c } }

if (-not (Test-Path $HeartbeatPath)) {
    Say "DOWN - no heartbeat file at $HeartbeatPath. The agent has never run, or is not this install." 'Red'
    exit 2
}

try {
    $hb = Get-Content $HeartbeatPath -Raw | ConvertFrom-Json
} catch {
    Say "DOWN - heartbeat file is unreadable: $($_.Exception.Message)" 'Red'
    exit 2
}

$writtenAt = [datetime]::Parse($hb.writtenAt)
$ageSec    = [int]((Get-Date) - $writtenAt).TotalSeconds

Say ""
Say ("  heartbeat  {0}  ({1}s ago)" -f $writtenAt.ToString('yyyy-MM-dd HH:mm:ss'), $ageSec)
Say ("  pid {0}, up {1} min, sent {2}, queued {3}{4}" -f `
    $hb.pid, $hb.uptimeMin, $hb.sentTotal, $hb.queueDepth, $(if ($hb.dryRun) { ', DRY RUN' } else { '' }))

if ($hb.PSObject.Properties['stoppedAt']) {
    Say ""
    Say "  DOWN - agent stopped cleanly at $($hb.stoppedAt)" 'Yellow'
    exit 2
}

if ($ageSec -gt $StaleSeconds) {
    Say ""
    Say "  DOWN - heartbeat is ${ageSec}s old (limit ${StaleSeconds}s)." 'Red'
    Say "  The process may still show as Running while its loop is stuck. Restart the service." 'Red'
    exit 2
}

# Alive. Now decide whether it is actually doing its job.
$problems = @()

Say ""
foreach ($t in $hb.terminals) {
    $bits = @()
    if (-not $t.stream) { $bits += 'stream DOWN' }
    if (-not $t.sd -and $t.state -ne 'IDLE') { $bits += '1701 DOWN' }
    $note = if ($bits.Count) { '  <-- ' + ($bits -join ', ') } else { '' }
    $col  = if ($bits.Count) { 'Yellow' } else { 'Green' }
    Say ("  {0,-16} {1,-15} {2,-9} weight {3}{4}" -f $t.name, $t.host, $t.state, $t.weight, $note) $col
    if (-not $t.stream) { $problems += "$($t.name): no stream connection" }
}

if ([int]$hb.queueDepth -ge $QueueWarnDepth) {
    $problems += "queue depth $($hb.queueDepth) -- Power Automate not accepting readings"
}
if ($hb.dryRun) {
    $problems += "running in DRY RUN -- nothing is being posted"
}

Say ""
if ($problems.Count -eq 0) {
    Say "  HEALTHY" 'Green'
    Say ""
    exit 0
}
Say "  DEGRADED" 'Yellow'
foreach ($p in $problems) { Say "    - $p" 'Yellow' }
Say ""
exit 1
