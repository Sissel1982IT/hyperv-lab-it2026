[CmdletBinding()]
param (
    [string]$ConfigFile = "monitor.json",
    [string]$StopFile   = "monitor.stop",
    [string]$StatusFile = "monitor.status.json",
    [switch]$KeepStatus   
)

$username = "Administrator"
$password = ConvertTo-SecureString "P@ssw0rd" -AsPlainText -Force
$cred     = New-Object System.Management.Automation.PSCredential ($username, $password)

$configPath = Join-Path $PSScriptRoot $ConfigFile
if (-not (Test-Path $configPath)) { throw "Konfigurationsdatei nicht gefunden: $configPath" }

$config   = Get-Content $configPath -Raw | ConvertFrom-Json
$logFile  = Join-Path $PSScriptRoot $config.Settings.LogFile
$stopPath = Join-Path $PSScriptRoot $StopFile
$statusPath = Join-Path $PSScriptRoot $StatusFile

# Hysterese gegen Flapping
$FailThreshold = if ($config.Settings.FailThreshold) { $config.Settings.FailThreshold } else { 3 }
$OkThreshold   = if ($config.Settings.OkThreshold)   { $config.Settings.OkThreshold }   else { 2 }

$DefaultFailoverAlias = if ($config.Settings.DefaultFailoverAlias) { $config.Settings.DefaultFailoverAlias } else { "Backbone_two" }
$DefaultFailbackAlias = if ($config.Settings.DefaultFailbackAlias) { $config.Settings.DefaultFailbackAlias } else { "Backbone_one" }

function Get-InterfaceAlias {
    param([string]$Neighbor, [ValidateSet("Failover","Failback")][string]$Kind)
    $override = $config.Settings.InterfaceAliases.$Neighbor
    if ($override -and $override.$Kind) { return $override.$Kind }
    if ($Kind -eq "Failover") { return $DefaultFailoverAlias } else { return $DefaultFailbackAlias }
}

# ------------------------------------------------------------------
# Generischer Helfer: Befehl auf einer VM per PowerShell Direct ausfuehren
# ------------------------------------------------------------------
function Invoke-VMJob {
    param(
        [string]$VMName,
        [scriptblock]$InnerScriptBlock,
        [object[]]$InnerArgumentList = @(),
        [int]$TimeoutSeconds = 15
    )

    $innerText = $InnerScriptBlock.ToString()

    $job = Start-Job -ScriptBlock {
        param($vmName, $vmCred, $innerSbText, $innerArgs)
        $sb = [scriptblock]::Create($innerSbText)
        Invoke-Command -VMName $vmName -Credential $vmCred -ScriptBlock $sb `
            -ArgumentList $innerArgs -ErrorAction Stop
    } -ArgumentList $VMName, $cred, $innerText, $InnerArgumentList

    $finished = Wait-Job -Job $job -Timeout $TimeoutSeconds

    if (-not $finished) {
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        return @{ Success = $false; Error = "Zeitüberschreitung nach ${TimeoutSeconds}s - VM antwortet nicht auf PowerShell Direct" }
    }

    try {
        $result = Receive-Job -Job $job -ErrorAction Stop
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        return @{ Success = $true; Result = $result }
    } catch {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

# ------------------------------------------------------------------
# Erreichbarkeitsprüfung über einen LEBENDEN "Späher"-Router
# ------------------------------------------------------------------
function Test-HostAlive {
    param([PSCustomObject]$TargetRouter)

    # 1. Hyper-V Grundcheck: Läuft die VM überhaupt?
    $vm = Get-VM -Name $TargetRouter.Name -ErrorAction SilentlyContinue
    if (-not $vm -or $vm.State -ne 'Running') {
        return $false # VM ist komplett aus
    }

    # 2. Wir testen direkt, ob der primäre Weg (Backbone_one / PrimaryIP) noch antwortet
    $pingScriptBlock = {
        param($ipToPing)
        return (Test-Connection -ComputerName $ipToPing -Count 1 -Quiet -ErrorAction SilentlyContinue)
    }

    $job = Invoke-VMJob -VMName $TargetRouter.Name -InnerScriptBlock $pingScriptBlock `
             -InnerArgumentList @($TargetRouter.PrimaryIP) -TimeoutSeconds 5

    # Wenn der Ping durchgeht, ist Backbone_one gesund -> TRUE (Online)
    if ($job.Success -and $job.Result -eq $true) {
        return $true
    }

    # Wenn der Ping FEHLSCHLÄGT, aber die VM läuft, ist Backbone_one tot!
    # Das werten wir jetzt als Ausfall, damit das Failover auf Backbone_two greift.
    return $false
}

# ------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------
function Write-Log ($Message, $Type = "INFO") {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry  = "[$timestamp] [$Type] $Message"

    if ((Test-Path $logFile) -and ((Get-Item $logFile).Length -gt 10MB)) {
        $archive = "$logFile.$(Get-Date -Format 'yyyyMMdd_HHmmss').bak"
        Rename-Item -Path $logFile -NewName $archive -ErrorAction SilentlyContinue
    }

    Add-Content -Path $logFile -Value $logEntry -Encoding UTF8

    $color = switch ($Type) {
        "ERROR" { "Red" }
        "WARN"  { "Yellow" }
        "OK"    { "Green" }
        Default { "Cyan" }
    }
    Write-Host $logEntry -ForegroundColor $color
}

# ------------------------------------------------------------------
# Failover / Failback ausfuehren
# ------------------------------------------------------------------
function Invoke-RouteChange {
    param(
        [string]$Neighbor,
        [string]$Network,
        [string]$NextHop,
        [string]$InterfaceAlias,
        [int]$TimeoutSeconds = 15
    )

    $routeScriptBlock = {
        param($network, $nextHop, $ifAlias)
        try {
            # Prüfen, ob der Adapter auf der Ziel-VM existiert und aktiv ist
            $adapter = Get-NetAdapter -Name $ifAlias -ErrorAction SilentlyContinue
            if (-not $adapter) {
                return @{ Success = $false; Error = "Adapter '$ifAlias' nicht gefunden." }
            }
            if ($adapter.Status -ne 'Up') {
                return @{ Success = $false; Error = "Adapter '$ifAlias' ist nicht aktiv (Status: $($adapter.Status))." }
            }

            Remove-NetRoute -DestinationPrefix $network -Confirm:$false -ErrorAction SilentlyContinue
            New-NetRoute -DestinationPrefix $network -NextHop $nextHop -InterfaceIndex $adapter.ifIndex -RouteMetric 1 -Confirm:$false -ErrorAction Stop
            
            return @{ Success = $true; Error = $null }
        } catch {
            return @{ Success = $false; Error = $_.Exception.Message }
        }
    }

    $job = Invoke-VMJob -VMName $Neighbor -InnerScriptBlock $routeScriptBlock `
             -InnerArgumentList @($Network, $NextHop, $InterfaceAlias) -TimeoutSeconds $TimeoutSeconds

    if (-not $job.Success) {
        return @{ Success = $false; Message = "Verbindung zu $Neighbor fehlgeschlagen: $($job.Error)" }
    }

    $result = $job.Result
    if ($result.Success) {
        return @{ Success = $true; Message = "Route gesetzt (Netz: $Network, Gateway: $NextHop via $InterfaceAlias)" }
    } else {
        return @{ Success = $false; Message = "Route auf $Neighbor NICHT gesetzt - Fehler auf der VM: $($result.Error)" }
    }
}

# ------------------------------------------------------------------
# Status initialisieren
# ------------------------------------------------------------------
$status = @{}
if (-not $KeepStatus -and (Test-Path $statusPath)) {
    Remove-Item $statusPath -Force
    Write-Log "Vorhandener Status wurde verworfen, alle Router starten als ONLINE." "WARN"
}

if ($KeepStatus -and (Test-Path $statusPath)) {
    try {
        $loaded = Get-Content $statusPath -Raw | ConvertFrom-Json
        foreach ($router in $config.Routers) {
            if ($loaded.($router.Name)) {
                $status[$router.Name] = @{
                    State     = $loaded.($router.Name).State
                    FailCount = $loaded.($router.Name).FailCount
                    OkCount   = $loaded.($router.Name).OkCount
                }
            } else {
                $status[$router.Name] = @{ State = "ONLINE"; FailCount = 0; OkCount = 0 }
            }
        }
    } catch {
        foreach ($router in $config.Routers) {
            $status[$router.Name] = @{ State = "ONLINE"; FailCount = 0; OkCount = 0 }
        }
    }
} else {
    foreach ($router in $config.Routers) {
        $status[$router.Name] = @{ State = "ONLINE"; FailCount = 0; OkCount = 0 }
    }
}

function Save-Status {
    $status | ConvertTo-Json -Depth 5 | Set-Content -Path $statusPath
}

Write-Log "Starte Lab-Monitoring... (Intervall: $($config.Settings.IntervalSeconds)s, FailThreshold: $FailThreshold, OkThreshold: $OkThreshold)" "OK"

$HeartbeatEveryNLoops = 6
$loopCounter = 0

# ------------------------------------------------------------------
# Hauptschleife
# ------------------------------------------------------------------
while ($true) {

    if (Test-Path $stopPath) {
        Write-Log "Stop-Datei ($StopFile) gefunden - Monitoring wird sauber beendet." "OK"
        break
    }

    $toFailover = @()
    $toFailback = @()

    # PHASE 1: Remote-Pings über Späher-Router durchführen
    foreach ($router in $config.Routers) {
        $isAlive = Test-HostAlive -TargetRouter $router
        $s = $status[$router.Name]

        if ($isAlive) {
            $s.OkCount++
            $s.FailCount = 0
            if ($s.State -eq "OFFLINE") {
                Write-Log "Router $($router.Name) antwortet wieder ($($s.OkCount)/$OkThreshold für Failback)." "INFO"
            }
        } else {
            $s.FailCount++
            $s.OkCount = 0
            if ($s.State -eq "ONLINE") {
                Write-Log "Router $($router.Name) antwortet nicht ($($s.FailCount)/$FailThreshold für Failover)." "WARN"
            }
        }

        if ($s.State -eq "ONLINE" -and $s.FailCount -ge $FailThreshold) {
            $s.State = "OFFLINE"
            Save-Status
            $toFailover += $router
        }
        elseif ($s.State -eq "OFFLINE" -and $s.OkCount -ge $OkThreshold) {
            $s.State = "ONLINE"
            Save-Status
            $toFailback += $router
        }
    }

    # PHASE 2: Failover-Aktionen ausführen
    foreach ($router in $toFailover) {
        Write-Log "Router $($router.Name) offline! Starte Failover..." "ERROR"

        # 1. HINWEG (Nachbarn informieren)
        foreach ($neighbor in $router.Neighbors) {
            if ((Get-VM -Name $neighbor -ErrorAction SilentlyContinue).State -ne 'Running') { continue }

            $alias  = Get-InterfaceAlias -Neighbor $neighbor -Kind "Failover"
            $result = Invoke-RouteChange -Neighbor $neighbor -Network $router.Network -NextHop $router.BackupIP -InterfaceAlias $alias
            
            if ($result.Success) {
                Write-Log "  -> Hinweg auf $($neighbor): $($result.Message)" "WARN"
            } else {
                Write-Log "  -> FEHLER Hinweg auf $($neighbor): $($result.Message)" "ERROR"
            }
        }

        # 2. RÜCKWEG (Dem ausgefallenen Router sagen, wo die anderen sind)
        if ((Get-VM -Name $router.Name -ErrorAction SilentlyContinue).State -eq 'Running') {
            $fallbackAlias = Get-InterfaceAlias -Neighbor $router.Name -Kind "Failover"
            
            foreach ($other in $config.Routers) {
                if ($other.Name -eq $router.Name) { continue } # Sich selbst ueberspringen
                
                $result = Invoke-RouteChange -Neighbor $router.Name -Network $other.Network -NextHop $other.BackupIP -InterfaceAlias $fallbackAlias
                
                if ($result.Success) {
                    Write-Log "  -> Rückweg auf $($router.Name): $($result.Message)" "WARN"
                } else {
                    Write-Log "  -> FEHLER Rückweg auf $($router.Name): $($result.Message)" "ERROR"
                }
            }
        }
    }

    # PHASE 3: Failback-Aktionen ausführen
    foreach ($router in $toFailback) {
        Write-Log "Router $($router.Name) wieder online! Starte Failback..." "OK"

        # 1. HINWEG zurücksetzen
        foreach ($neighbor in $router.Neighbors) {
            if ((Get-VM -Name $neighbor -ErrorAction SilentlyContinue).State -ne 'Running') { continue }

            $alias  = Get-InterfaceAlias -Neighbor $neighbor -Kind "Failback"
            $result = Invoke-RouteChange -Neighbor $neighbor -Network $router.Network -NextHop $router.PrimaryIP -InterfaceAlias $alias
            
            if ($result.Success) {
                Write-Log "  -> Hinweg auf $($neighbor): $($result.Message)" "INFO"
            } else {
                Write-Log "  -> FEHLER Hinweg auf $($neighbor): $($result.Message)" "ERROR"
            }
        }

        # 2. RÜCKWEG zurücksetzen
        if ((Get-VM -Name $router.Name -ErrorAction SilentlyContinue).State -eq 'Running') {
            $failbackAlias = Get-InterfaceAlias -Neighbor $router.Name -Kind "Failback"
            
            foreach ($other in $config.Routers) {
                if ($other.Name -eq $router.Name) { continue }
                
                $result = Invoke-RouteChange -Neighbor $router.Name -Network $other.Network -NextHop $other.PrimaryIP -InterfaceAlias $failbackAlias
                
                if ($result.Success) {
                    Write-Log "  -> Rückweg auf $($router.Name): $($result.Message)" "INFO"
                } else {
                    Write-Log "  -> FEHLER Rückweg auf $($router.Name): $($result.Message)" "ERROR"
                }
            }
        }
    }

    $loopCounter++
    if ($loopCounter -ge $HeartbeatEveryNLoops) {
        $summary = ($config.Routers | ForEach-Object {
            $rs = $status[$_.Name]
            "$($_.Name)=$($rs.State)(F$($rs.FailCount)/O$($rs.OkCount))"
        }) -join ", "
        Write-Log "Statusübersicht: $summary" "INFO"
        $loopCounter = 0
    }

    Save-Status
    Start-Sleep -Seconds $config.Settings.IntervalSeconds
}