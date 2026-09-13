# ==============================================================================
# Idempotent IP Configuration, Static Routing & Firewall Disabler for Hyper-V VMs
# File: IPConfig.ps1
#
# Macht in einem Lauf, gegen dieselbe netconfig.json:
#   1. IP-Adressen auf allen VMs (Router + Clients) setzen/aktualisieren
#      (auf Clients zusaetzlich: Desktop-Verknuepfung zu den Netzwerk-
#      verbindungen anlegen, damit man die Adapter schnell erreicht)
#   2. Auf allen Router-VMs: IP-Forwarding aktivieren + statische Routen zu
#      allen anderen Router-Stadt-Netzen anlegen. Aenderungen an Gateway-IPs
#      ODER am Zielnetz selbst werden erkannt: jeder Router fuehrt eine kleine
#      State-Datei (LabRoutes.state.json), in der die zuletzt gesetzten
#      Zielnetze stehen - vor dem Neuanlegen werden ALLE davon entfernt, nicht
#      nur die, die in der aktuellen netconfig.json noch vorkommen.
#   3. Firewall auf allen laufenden VMs deaktivieren
# ==============================================================================

$username = "Administrator"
$password = ConvertTo-SecureString "P@ssw0rd" -AsPlainText -Force
$cred     = New-Object System.Management.Automation.PSCredential ($username, $password)

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "   VM Network, Routing & Security Setup - Start   " -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

$jsonFile = Join-Path $PSScriptRoot "netconfig.json"
if (-not (Test-Path $jsonFile)) {
    Write-Error "Die JSON-Datei wurde unter folgendem Pfad nicht gefunden:`n$jsonFile"
    exit
}

Write-Host "Lese Konfiguration aus 'netconfig.json'..." -ForegroundColor Yellow
$jsonContent = Get-Content -Path $jsonFile -Raw | ConvertFrom-Json
$vmConfigurations = @{}
foreach ($property in $jsonContent.psobject.properties) {
    # @() erzwingt Array-Kontext, damit .Count/[$i] auch bei genau EINER
    # Netzwerkkonfiguration pro VM korrekt funktionieren.
    $vmConfigurations[$property.Name] = @($property.Value)
}

# ------------------------------------------------------------------------------
# Hilfsfunktionen
# ------------------------------------------------------------------------------

# Aktiv auf PowerShell-Direct-Bereitschaft warten statt einen fixen Sleep zu raten.
function Wait-VMReady {
    param(
        [Parameter(Mandatory = $true)][string]$VMName,
        [Parameter(Mandatory = $true)][System.Management.Automation.PSCredential]$Credential,
        [int]$MaxWaitSeconds = 180,
        [int]$PollIntervalSeconds = 5
    )
    $waited = 0
    while ($waited -lt $MaxWaitSeconds) {
        try {
            Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock { $true } -ErrorAction Stop | Out-Null
            return $true
        } catch {
            Start-Sleep -Seconds $PollIntervalSeconds
            $waited += $PollIntervalSeconds
        }
    }
    return $false
}

# Berechnet aus IP + Prefix die Netzwerkadresse in CIDR-Schreibweise,
# z.B. 192.168.30.1 / 24 -> "192.168.30.0/24"
function Get-NetworkCidr {
    param([string]$IP, [int]$Prefix)
    $ipBytes = ([System.Net.IPAddress]::Parse($IP)).GetAddressBytes()
    [Array]::Reverse($ipBytes)
    $ipUInt = [BitConverter]::ToUInt32($ipBytes, 0)
    $maskUInt = if ($Prefix -le 0) { 0 } else { [UInt32]::MaxValue -shl (32 - $Prefix) }
    $networkUInt = $ipUInt -band $maskUInt
    $networkBytes = [BitConverter]::GetBytes($networkUInt)
    [Array]::Reverse($networkBytes)
    $networkIP = [System.Net.IPAddress]::new($networkBytes)
    return "$($networkIP.ToString())/$Prefix"
}

# ------------------------------------------------------------------------------
# 1. IP-Adressen setzen
# ------------------------------------------------------------------------------
Write-Host "`n--- Abschnitt 1: IP-Adressen ---" -ForegroundColor Cyan

foreach ($vmName in $vmConfigurations.Keys) {
    $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-Warning "VM '$vmName' wurde auf dem Host nicht gefunden. Ueberspringe..."
        continue
    }

    if ($vm.State -ne 'Running') {
        Write-Warning "VM '$vmName' laeuft nicht. Starte VM..."
        Start-VM -Name $vmName
    }

    Write-Host "`nWarte auf PowerShell-Direct-Bereitschaft von '$vmName'..." -ForegroundColor DarkCyan
    if (-not (Wait-VMReady -VMName $vmName -Credential $cred -MaxWaitSeconds 180)) {
        Write-Warning "VM '$vmName' war nach 180 Sekunden nicht ueber PowerShell Direct erreichbar. Ueberspringe..."
        continue
    }

    Write-Host "Konfiguriere Netzwerke fuer VM: $vmName" -ForegroundColor Cyan
    $netConfigs = $vmConfigurations[$vmName]
    $adapters = @(Get-VMNetworkAdapter -VMName $vmName)

    foreach ($config in $netConfigs) {
        # Zuordnung ueber den Ziel-Switch statt ueber Array-Index: Get-VMNetworkAdapter
        # garantiert keine stabile Reihenfolge, ein Index-Mapping kann daher stillschweigend
        # den falschen Adapter auf den falschen Switch umklemmen.
        $adapter = $adapters | Where-Object { $_.SwitchName -eq $config.Switch } | Select-Object -First 1

        if (-not $adapter) {
            $desiredSwitches = $netConfigs.Switch
            $adapter = $adapters | Where-Object { $desiredSwitches -notcontains $_.SwitchName } | Select-Object -First 1

            if ($adapter) {
                Write-Host "  -> Verbinde vorhandenen Adapter '$($adapter.Name)' mit Switch '$($config.Switch)'" -ForegroundColor DarkYellow
                Connect-VMNetworkAdapter -VMNetworkAdapter $adapter -SwitchName $config.Switch
            } else {
                Write-Host "  -> Kein freier Adapter vorhanden, lege neuen fuer Switch '$($config.Switch)' an" -ForegroundColor DarkYellow
                Add-VMNetworkAdapter -VMName $vmName -SwitchName $config.Switch | Out-Null
                $adapters = @(Get-VMNetworkAdapter -VMName $vmName)
                $adapter = $adapters | Where-Object { $_.SwitchName -eq $config.Switch } | Select-Object -First 1
            }
        }

        if (-not $adapter) {
            Write-Warning "  -> Konnte fuer Switch '$($config.Switch)' auf '$vmName' keinen Adapter ermitteln. Ueberspringe diese Konfiguration."
            continue
        }

        $macAddress = $adapter.MacAddress

        $ipScriptBlock = {
            param($ip, $prefix, $gateway, $mac, $switchName)
            $formattedMac = ($mac -replace '..(?!$)', '$0-')
            $netAdapter = Get-NetAdapter | Where-Object { $_.MacAddress -eq $formattedMac }

            if ($netAdapter) {
                if ($netAdapter.Name -ne $switchName) {
                    Rename-NetAdapter -Name $netAdapter.Name -NewName $switchName -ErrorAction SilentlyContinue
                }

                # Bestehende IPs auf diesem Adapter entfernen (unabhaengig vom alten Wert -
                # der Adapter wird ueber die MAC identifiziert, nicht ueber die alte IP,
                # daher werden auch IP-AENDERUNGEN hier zuverlaessig uebernommen).
                Get-NetIPAddress -InterfaceAlias $switchName -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.IPAddress -notmatch '^127\.' -and $_.IPAddress -notmatch '^169\.254\.' } |
                    Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

                Get-NetRoute -InterfaceAlias $switchName -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                    Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

                if ([string]::IsNullOrWhiteSpace($gateway)) {
                    New-NetIPAddress -InterfaceAlias $switchName -IPAddress $ip -PrefixLength $prefix | Out-Null
                } else {
                    New-NetIPAddress -InterfaceAlias $switchName -IPAddress $ip -PrefixLength $prefix -DefaultGateway $gateway | Out-Null
                }
            }
        }

        try {
            Invoke-Command -VMName $vmName -Credential $cred -ScriptBlock $ipScriptBlock -ArgumentList $config.IP, $config.Prefix, $config.Gateway, $macAddress, $config.Switch -ErrorAction Stop

            if ([string]::IsNullOrWhiteSpace($config.Gateway)) {
                Write-Host "  -> Adapter '$($config.Switch)' konfiguriert mit IP: $($config.IP)" -ForegroundColor Green
            } else {
                Write-Host "  -> Adapter '$($config.Switch)' konfiguriert mit IP: $($config.IP) (Gateway: $($config.Gateway))" -ForegroundColor Green
            }
        } catch {
            Write-Warning "  -> Fehler bei VM $vmName auf Switch $($config.Switch): $($_.Exception.Message)"
        }
    }

    # Auf Clients zusaetzlich eine Desktop-Verknuepfung zu den Netzwerkverbindungen
    # anlegen (ncpa.cpl) - schneller Zugriff auf die Adapter, ohne durch die
    # Windows-Einstellungen navigieren zu muessen. Idempotent: ueberschreibt die
    # bestehende Verknuepfung bei jedem Lauf einfach neu.
    if ($vmName -match '^CL_') {
        $shortcutScriptBlock = {
            $desktopPath = "$env:Public\Desktop"
            if (-not (Test-Path $desktopPath)) { New-Item -ItemType Directory -Path $desktopPath -Force | Out-Null }
            $shortcutPath = Join-Path $desktopPath "Netzwerkverbindungen.lnk"

            $wshShell = New-Object -ComObject WScript.Shell
            $shortcut = $wshShell.CreateShortcut($shortcutPath)
            $shortcut.TargetPath = "control.exe"
            $shortcut.Arguments = "ncpa.cpl"
            $shortcut.IconLocation = "netshell.dll,0"
            $shortcut.Description = "Netzwerkverbindungen"
            $shortcut.Save()
        }

        try {
            Invoke-Command -VMName $vmName -Credential $cred -ScriptBlock $shortcutScriptBlock -ErrorAction Stop
            Write-Host "  -> Desktop-Verknuepfung 'Netzwerkverbindungen' auf '$vmName' angelegt." -ForegroundColor Green
        } catch {
            Write-Warning "  -> Konnte Verknuepfung auf '$vmName' nicht anlegen: $($_.Exception.Message)"
        }
    }
}

# ------------------------------------------------------------------------------
# 2. Statische Routen zwischen den Router-VMs
# ------------------------------------------------------------------------------
Write-Host "`n--- Abschnitt 2: Statische Routen (Router) ---" -ForegroundColor Cyan

$routerNames = @($vmConfigurations.Keys | Where-Object { $_ -match '^Router_' })

if ($routerNames.Count -eq 0) {
    Write-Warning "Keine Router (Namen beginnend mit 'Router_') in der netconfig.json gefunden. Ueberspringe Routing."
} else {
    # Pro Router: Stadt-Netz (nicht-Backbone) + Backbone_one-IP ermitteln
    $routerInfo = @{}
    foreach ($routerName in $routerNames) {
        $configs = $vmConfigurations[$routerName]
        $stadtEntry = $configs | Where-Object { $_.Switch -notlike 'Backbone_*' } | Select-Object -First 1
        $bb1Entry   = $configs | Where-Object { $_.Switch -eq 'Backbone_one' } | Select-Object -First 1

        if (-not $stadtEntry -or -not $bb1Entry) {
            Write-Warning "Router '$routerName' hat keinen Stadt- oder Backbone_one-Eintrag in der netconfig.json. Ueberspringe fuer Routing."
            continue
        }

        $routerInfo[$routerName] = [PSCustomObject]@{
            StadtCidr  = Get-NetworkCidr -IP $stadtEntry.IP -Prefix $stadtEntry.Prefix
            BackboneIP = $bb1Entry.IP
            Interface  = $bb1Entry.Switch
        }
    }

    foreach ($routerName in $routerInfo.Keys) {
        $vm = Get-VM -Name $routerName -ErrorAction SilentlyContinue
        if (-not $vm -or $vm.State -ne 'Running') {
            Write-Warning "Router '$routerName' laeuft nicht (mehr). Ueberspringe Routing fuer diesen Router."
            continue
        }

        if (-not (Wait-VMReady -VMName $routerName -Credential $cred -MaxWaitSeconds 60)) {
            Write-Warning "Router '$routerName' nicht erreichbar. Ueberspringe Routing fuer diesen Router."
            continue
        }

        # IP-Forwarding aktivieren - ohne das leitet Windows trotz korrekter
        # Routing-Tabelle keine Pakete zwischen den Interfaces weiter.
        $enableForwardingBlock = {
            Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.InterfaceAlias -notlike 'Loopback*' } |
                Set-NetIPInterface -Forwarding Enabled -ErrorAction SilentlyContinue
        }
        try {
            Invoke-Command -VMName $routerName -Credential $cred -ScriptBlock $enableForwardingBlock -ErrorAction Stop
            Write-Host "  -> IP-Forwarding auf '$routerName' aktiviert." -ForegroundColor Green
        } catch {
            Write-Warning "  -> Konnte IP-Forwarding auf '$routerName' nicht aktivieren: $($_.Exception.Message)"
        }

        $myInfo = $routerInfo[$routerName]
        $routes = @()

        foreach ($otherName in $routerInfo.Keys) {
            if ($otherName -eq $routerName) { continue }
            $otherInfo = $routerInfo[$otherName]

            $routes += [PSCustomObject]@{
                Destination = $otherInfo.StadtCidr
                NextHop     = $otherInfo.BackboneIP
                Interface   = $myInfo.Interface   # lokale Schnittstelle DIESES Routers
            }
        }

        if ($routes.Count -eq 0) {
            Write-Host "  -> Keine Routen zu anderen Routern noetig." -ForegroundColor DarkGreen
            continue
        }

        $routeScriptBlock = {
            param($routesToApply)

            $stateFile = "$env:SystemDrive\LabRoutes.state.json"

            # Schritt 1: ALLE beim letzten Lauf gesetzten Zielnetze entfernen -
            # unabhaengig davon, ob sie im aktuellen Lauf ueberhaupt noch vorkommen.
            # Faengt den Fall ab, dass sich ein Zielnetz selbst aendert (z.B.
            # 192.168.70.0/24 -> 192.168.30.0/24), nicht nur das Gateway.
            if (Test-Path $stateFile) {
                try {
                    $previousDestinations = @(Get-Content $stateFile -Raw | ConvertFrom-Json)
                } catch {
                    $previousDestinations = @()
                }
                foreach ($oldDest in $previousDestinations) {
                    Get-NetRoute -DestinationPrefix $oldDest -ErrorAction SilentlyContinue |
                        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
                }
            }

            # Schritt 2: aktuelle Routen frisch anlegen
            foreach ($route in $routesToApply) {
                try {
                    # Sicherheitsnetz: falls zu dieser exakten Destination noch eine
                    # nicht ueber das State-File erfasste Route existiert, auch entfernen.
                    Get-NetRoute -DestinationPrefix $route.Destination -ErrorAction SilentlyContinue |
                        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

                    $adapter = Get-NetAdapter -Name $route.Interface -ErrorAction SilentlyContinue
                    if (-not $adapter) {
                        Write-Warning "    Adapter '$($route.Interface)' nicht gefunden - Route zu $($route.Destination) uebersprungen."
                        continue
                    }

                    New-NetRoute -DestinationPrefix $route.Destination -NextHop $route.NextHop `
                        -InterfaceIndex $adapter.ifIndex -Confirm:$false -ErrorAction Stop | Out-Null
                } catch {
                    Write-Warning "    Route zu $($route.Destination) fehlgeschlagen: $($_.Exception.Message)"
                }
            }

            # Schritt 3: neuen Stand als State-File sichern
            $routesToApply | Select-Object -ExpandProperty Destination -Unique |
                ConvertTo-Json | Set-Content -Path $stateFile -Encoding UTF8
        }

        try {
            Invoke-Command -VMName $routerName -Credential $cred -ScriptBlock $routeScriptBlock -ArgumentList (,$routes) -ErrorAction Stop
            Write-Host "  -> Routen auf '$routerName' erfolgreich neu gesetzt (alte Ziele zuvor vollstaendig entfernt):" -ForegroundColor Green
            foreach ($r in $routes) {
                Write-Host "     $($r.Destination) via $($r.NextHop)" -ForegroundColor Green
            }
        } catch {
            Write-Warning "  -> Fehler beim Setzen der Routen auf '$routerName': $($_.Exception.Message)"
        }
    }
}

# ------------------------------------------------------------------------------
# 3. Firewall auf allen konfigurierten VMs deaktivieren
# ------------------------------------------------------------------------------
Write-Host "`n--- Abschnitt 3: Firewall deaktivieren ---" -ForegroundColor Cyan

foreach ($vmName in $vmConfigurations.Keys) {
    $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if ($vm -and $vm.State -eq 'Running') {
        if (-not (Wait-VMReady -VMName $vmName -Credential $cred -MaxWaitSeconds 30)) {
            Write-Warning "  -> [FEHLER] '$vmName' ueber PowerShell Direct nicht erreichbar. Ueberspringe Firewall-Deaktivierung."
            continue
        }

        $firewallScriptBlock = {
            Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
        }

        try {
            Invoke-Command -VMName $vmName -Credential $cred -ScriptBlock $firewallScriptBlock -ErrorAction Stop
            Write-Host "  -> [OK] Firewall auf '$vmName' ist AUS." -ForegroundColor Green
        } catch {
            Write-Warning "  -> [FEHLER] Konnte Firewall auf '$vmName' nicht deaktivieren: $($_.Exception.Message)"
        }
    }
}

Write-Host "`nKomplettes Netzwerk-, Routing- und Security-Setup erfolgreich abgeschlossen!" -ForegroundColor Green