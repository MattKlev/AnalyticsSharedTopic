#Requires -Modules TcXaeMgmt
<#
.SYNOPSIS
    Simulates a mover travelling from Rt01 to Rt02 so both Analytics Loggers
    publish to the same MQTT topic, one after the other.

.DESCRIPTION
    For each target in turn:
      1. Sets MAIN.Active := TRUE via ADS.
      2. The PLC sets Mover.BTN := 1234 (the Analytics Logger event condition) and
         draws its half of the circle on Mover.SetXPos / Mover.SetYPos.
      3. The PLC resets MAIN.Active when the arc is finished; the script waits for
         that, then moves on to the next target.

    Rt01 draws 0..180 deg, Rt02 draws 180..360 deg, so one lap is a full circle.

.EXAMPLE
    .\Test-MoverHandoff.ps1

.EXAMPLE
    .\Test-MoverHandoff.ps1 -Laps 3 -PollMs 250

.EXAMPLE
    .\Test-MoverHandoff.ps1 -Loop
#>
[CmdletBinding()]
param(
    # Targets in the order the mover visits them.
    # Rt01 = 192.168.1.27.1.1, Rt02 = 192.168.1.25.1.1
    [string[]]$NetIds = @('192.168.1.27.1.1', '192.168.1.25.1.1'),

    [int]$Port = 851,

    # Number of full circles (each lap visits every target once).
    [ValidateRange(1, 1000)]
    [int]$Laps = 1,

    # Keep lapping until Ctrl+C (overrides -Laps).
    [switch]$Loop,

    # Maximum time to wait for one target to finish its arc.
    [int]$TimeoutSec = 15,

    # Poll interval while the arc is being drawn.
    [int]$PollMs = 200,

    [uint32]$ExpectedBtn = 1234
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-MoverArc {
    param([string]$NetId)

    $session = New-TcSession -NetId $NetId -Port $Port
    try {
        $state = (Get-AdsState -SessionId $session.Id -StateOnly)
        if ("$state" -ne 'Run') {
            throw "PLC on $NetId port $Port is in state '$state', expected 'Run'."
        }

        # Make sure we start from a clean, inactive mover so the PLC sees a rising edge.
        if (Read-TcValue -SessionId $session.Id -Path 'MAIN.Active') {
            Write-Warning "[$NetId] MAIN.Active was already TRUE - resetting it first."
            Write-TcValue -SessionId $session.Id -Path 'MAIN.Active' -Value $false -Force
            Start-Sleep -Milliseconds 200
        }

        Write-Host "[$NetId] Mover Active -> TRUE" -ForegroundColor Cyan
        Write-TcValue -SessionId $session.Id -Path 'MAIN.Active' -Value $true -Force

        $timer     = [System.Diagnostics.Stopwatch]::StartNew()
        $btnSeen   = $false
        $completed = $false

        while ($timer.Elapsed.TotalSeconds -lt $TimeoutSec) {
            Start-Sleep -Milliseconds $PollMs

            $mover  = Read-TcValue -SessionId $session.Id -Path 'MAIN.Mover'
            $active = Read-TcValue -SessionId $session.Id -Path 'MAIN.Active'

            if ($mover.BTN -eq $ExpectedBtn) { $btnSeen = $true }

            if (-not $active) {
                $completed = $true
                break
            }

            Write-Host ('[{0}] Controller={1}  BTN={2}  X={3,8:F3}  Y={4,8:F3}' -f `
                    $NetId, $mover.ControllerID, $mover.BTN, $mover.SetXPos, $mover.SetYPos)
        }

        if (-not $completed) {
            Write-TcValue -SessionId $session.Id -Path 'MAIN.Active' -Value $false -Force
            throw "[$NetId] Arc did not finish within $TimeoutSec s - MAIN.Active forced back to FALSE."
        }
        if (-not $btnSeen) {
            Write-Warning "[$NetId] Never saw Mover.BTN = $ExpectedBtn while active - the logger condition may not have triggered."
        }

        Write-Host ('[{0}] Mover Active -> FALSE after {1:F2} s' -f $NetId, $timer.Elapsed.TotalSeconds) -ForegroundColor Green
    }
    finally {
        Close-TcSession -Id $session.Id
    }
}

if ($Loop) { Write-Host 'Looping until Ctrl+C.' -ForegroundColor Yellow }

for ($lap = 1; $Loop -or $lap -le $Laps; $lap++) {
    $total = if ($Loop) { 'continuous' } else { "of $Laps" }
    Write-Host "=== Lap $lap $total ===" -ForegroundColor Yellow
    foreach ($netId in $NetIds) {
        Invoke-MoverArc -NetId $netId
    }
}

Write-Host 'Done.' -ForegroundColor Yellow
