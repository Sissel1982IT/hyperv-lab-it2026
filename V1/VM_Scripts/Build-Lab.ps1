# ==============================================================================
# Zentraler Hyper-V Lab Builder (JSON-basiert, Idempotent mit Sync/Cleanup)
# ==============================================================================

# Admin-Rechte prüfen
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "Keine Administrator-Rechte! Bitte starte die PowerShell als Administrator."
    exit
}

$ConfigPath = Join-Path $PSScriptRoot "config.json"
if (-not (Test-Path $ConfigPath)) {
    Write-Error "Konfigurationsdatei nicht gefunden unter: $ConfigPath"
    exit
}

$Config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
Write-Host "Lese Lab-Konfiguration..." -ForegroundColor Cyan

# ------------------------------------------------------------------------------
# 1. Virtuelle Switches synchronisieren (Erstellen, Pruefen & Loeschen)
# ------------------------------------------------------------------------------
Write-Host "`n--- Synchronisiere Virtuelle Switches ---" -ForegroundColor Cyan
$DesiredSwitchConfigs = $Config.GlobalSettings.Switches
$DesiredSwitchNames = $DesiredSwitchConfigs.Name
$ExistingSwitches = Get-VMSwitch -ErrorAction SilentlyContinue

foreach ($swConf in $DesiredSwitchConfigs) {
    $existingSwitch = $ExistingSwitches | Where-Object { $_.Name -eq $swConf.Name }

    if (-not $existingSwitch) {
        Write-Host "Erstelle Switch: $($swConf.Name) (Typ: $($swConf.Type))" -ForegroundColor Green
        if ($swConf.Type -eq 'External') {
            if (-not $swConf.NetAdapterName) {
                Write-Warning "Switch $($swConf.Name) ist 'External', aber 'NetAdapterName' fehlt in der JSON!"
            } else {
                New-VMSwitch -Name $swConf.Name -NetAdapterName $swConf.NetAdapterName -AllowManagementOS $true | Out-Null
            }
        } else {
            New-VMSwitch -Name $swConf.Name -SwitchType $swConf.Type | Out-Null
        }
    } else {
        if ($existingSwitch.SwitchType -ne $swConf.Type) {
            Write-Warning "Achtung: Switch '$($swConf.Name)' existiert als '$($existingSwitch.SwitchType)', soll aber '$($swConf.Type)' sein."
        } else {
            Write-Host "Switch '$($swConf.Name)' ist aktuell." -ForegroundColor Yellow
        }
    }
}

foreach ($exSwitch in $ExistingSwitches) {
    if (($exSwitch.SwitchType -eq 'Internal' -or $exSwitch.SwitchType -eq 'Private') -and $exSwitch.Name -ne 'Default Switch' -and $DesiredSwitchNames -notcontains $exSwitch.Name) {
        Write-Host "Entferne nicht mehr benoetigten Switch: $($exSwitch.Name)" -ForegroundColor Red
        Remove-VMSwitch -Name $exSwitch.Name -Force | Out-Null
    }
}

# ------------------------------------------------------------------------------
# 2. Unattend.xml Templates
# ------------------------------------------------------------------------------
# ComputerName ist absichtlich NICHT Mandatory: Ein Mandatory-Parameter, der zur
# Laufzeit $null bekommt, laesst PowerShell interaktiv nach einem Wert fragen und
# das Skript lautlos haengen bleiben (kein Fehlertext, einfach ein blockierender
# Prompt). Fehlt der Name, wird das <ComputerName>-Element einfach weggelassen -
# Sysprep vergibt dann automatisch einen Zufallsnamen, statt den Lauf zu blockieren.
function Get-RouterUnattend {
    param([string]$ComputerName)

    $computerNameXml = ""
    if ($ComputerName) {
        $computerNameXml = "<ComputerName>$ComputerName</ComputerName>"
    }

    return @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ProductKey>VDYBN-27WPP-V4HQT-9VMD4-VMK7H</ProductKey>
      $computerNameXml
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>0407:00000407</InputLocale>
      <SystemLocale>de-DE</SystemLocale>
      <UILanguage>de-DE</UILanguage>
      <UserLocale>de-DE</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword>
          <Value>P@ssw0rd</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>
    </component>
  </settings>
</unattend>
"@
}

function Get-ClientUnattend {
    param([string]$ComputerName)

    $computerNameXml = ""
    if ($ComputerName) {
        $computerNameXml = "<ComputerName>$ComputerName</ComputerName>"
    }

    return @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ProductKey>VK7JG-NPHTM-C97JM-9MPGT-3V66T</ProductKey>
      $computerNameXml
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>0407:00000407</InputLocale>
      <SystemLocale>de-DE</SystemLocale>
      <UILanguage>de-DE</UILanguage>
      <UserLocale>de-DE</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword>
          <Value>P@ssw0rd</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>
      <AutoLogon>
        <Password>
          <Value>P@ssw0rd</Value>
          <PlainText>true</PlainText>
        </Password>
        <Enabled>true</Enabled>
        <Username>Administrator</Username>
        <LogonCount>1</LogonCount>
      </AutoLogon>
    </component>
  </settings>
</unattend>
"@
}

# ------------------------------------------------------------------------------
# 3. Synchronisierung der Router
# ------------------------------------------------------------------------------
Write-Host "`n--- Synchronisiere Router ---" -ForegroundColor Cyan
$DesiredRouterNames = $Config.Routers.Name
$BackboneSwitches = @($Config.GlobalSettings.BackboneSwitches)

foreach ($router in $Config.Routers) {
    $vmName = $router.Name
    try {
        $vhdPath = $router.VhdPath
        $masterPath = $Config.GlobalSettings.RouterMasterPath
        $existingVM = Get-VM -Name $vmName -ErrorAction SilentlyContinue

        if (-not $existingVM) {
            Write-Host "Erstelle neuen Router: $vmName" -ForegroundColor Green

            if (-not (Test-Path $vhdPath)) {
                New-VHD -Path $vhdPath -ParentPath $masterPath -Differencing | Out-Null
            }

            $Mount = Mount-VHD -Path $vhdPath -PassThru
            try {
                Start-Sleep -Seconds 2
                $Disk = Get-Disk -Number $Mount.DiskNumber
                $Part = $Disk | Get-Partition | Sort-Object Size -Descending | Select-Object -First 1
                if (-not $Part.DriveLetter) {
                    $Part | Add-PartitionAccessPath -AssignDriveLetter
                    Start-Sleep -Seconds 2
                    $Part = $Disk | Get-Partition | Where-Object PartitionNumber -eq $Part.PartitionNumber
                }
                if ($Part.DriveLetter) {
                    $PantherPath = "$($Part.DriveLetter):\Windows\Panther"
                    if (-not (Test-Path $PantherPath)) { New-Item -ItemType Directory -Path $PantherPath -Force | Out-Null }
                    $computerName = if ($router.NewPCName) { $router.NewPCName } else { $vmName }
                    Get-RouterUnattend -ComputerName $computerName | Out-File -FilePath "$PantherPath\unattend.xml" -Encoding UTF8
                }
            } finally {
                Dismount-VHD -Path $vhdPath
            }

            New-VM -Name $vmName -MemoryStartupBytes ($router.MemoryStartMB * 1MB) -Generation 2 -VHDPath $vhdPath -SwitchName $router.StadtSwitch | Out-Null
            Set-VMMemory -VMName $vmName -DynamicMemoryEnabled $true -MinimumBytes ($router.MemoryMinMB * 1MB) -MaximumBytes ($router.MemoryMaxMB * 1MB)
            Set-VMProcessor -VMName $vmName -Count $router.CpuCount
            Set-VM -Name $vmName -CheckpointType Disabled

            Get-VMNetworkAdapter -VMName $vmName | Rename-VMNetworkAdapter -NewName "NIC-Stadt"

            $bbIndex = 1
            foreach ($bbSwitch in $BackboneSwitches) {
                Add-VMNetworkAdapter -VMName $vmName -SwitchName $bbSwitch -Name "NIC-BB$bbIndex" | Out-Null
                $bbIndex++
            }
            Start-VM -Name $vmName
        } else {
            $DesiredStartupBytes = $router.MemoryStartMB * 1MB
            $DesiredMinBytes = $router.MemoryMinMB * 1MB
            $DesiredMaxBytes = $router.MemoryMaxMB * 1MB

            $nicStadt = Get-VMNetworkAdapter -VMName $vmName -Name "NIC-Stadt" -ErrorAction SilentlyContinue
            $currentStadtSwitch = if ($nicStadt) { $nicStadt.SwitchName } else { $null }

            $HardwareUpdateNeeded = $false
            $NetworkUpdateNeeded = $false

            if ($existingVM.ProcessorCount -ne $router.CpuCount) { $HardwareUpdateNeeded = $true }
            if ($existingVM.MemoryStartup -ne $DesiredStartupBytes) { $HardwareUpdateNeeded = $true }
            if ($existingVM.MemoryMinimum -ne $DesiredMinBytes) { $HardwareUpdateNeeded = $true }
            if ($existingVM.MemoryMaximum -ne $DesiredMaxBytes) { $HardwareUpdateNeeded = $true }
            if ($nicStadt -and $currentStadtSwitch -ne $router.StadtSwitch) { $NetworkUpdateNeeded = $true }

            if ($HardwareUpdateNeeded -or $NetworkUpdateNeeded) {
                Write-Host "Aktualisiere bestehenden Router: $vmName" -ForegroundColor Yellow
                $wasRunning = $existingVM.State -eq 'Running'

                if ($HardwareUpdateNeeded -and $wasRunning) { Stop-VM -Name $vmName -Force }
                if ($HardwareUpdateNeeded) {
                    Set-VMMemory -VMName $vmName -DynamicMemoryEnabled $true -StartupBytes $DesiredStartupBytes -MinimumBytes $DesiredMinBytes -MaximumBytes $DesiredMaxBytes
                    Set-VMProcessor -VMName $vmName -Count $router.CpuCount
                }
                if ($NetworkUpdateNeeded) { $nicStadt | Connect-VMNetworkAdapter -SwitchName $router.StadtSwitch }
                if ($HardwareUpdateNeeded -and $wasRunning) { Start-VM -Name $vmName }
            } else {
                Write-Host "Router '$vmName' ist auf dem neuesten Stand." -ForegroundColor DarkGreen
            }
        }
    } catch {
        Write-Error "Fehler beim Verarbeiten von Router '$vmName': $($_.Exception.Message)"
        Write-Warning "Ueberspringe '$vmName' und fahre mit der naechsten VM fort."
        continue
    }
}

# ------------------------------------------------------------------------------
# 4. Synchronisierung der Clients
# ------------------------------------------------------------------------------
Write-Host "`n--- Synchronisiere Clients ---" -ForegroundColor Cyan
$DesiredClientNames = $Config.Clients.Name

foreach ($client in $Config.Clients) {
    $vmName = $client.Name
    try {
        $vhdPath = $client.VhdPath
        $masterPath = $Config.GlobalSettings.ClientMasterPath
        $existingVM = Get-VM -Name $vmName -ErrorAction SilentlyContinue

        if (-not $existingVM) {
            Write-Host "Erstelle neuen Client: $vmName" -ForegroundColor Green

            if (-not (Test-Path $vhdPath)) {
                New-VHD -Path $vhdPath -ParentPath $masterPath -Differencing | Out-Null
            }

            $Mount = Mount-VHD -Path $vhdPath -PassThru
            try {
                Start-Sleep -Seconds 2
                $Disk = Get-Disk -Number $Mount.DiskNumber
                $Part = $Disk | Get-Partition | Sort-Object Size -Descending | Select-Object -First 1
                if (-not $Part.DriveLetter) {
                    $Part | Add-PartitionAccessPath -AssignDriveLetter
                    Start-Sleep -Seconds 2
                    $Part = $Disk | Get-Partition | Where-Object PartitionNumber -eq $Part.PartitionNumber
                }
                if ($Part.DriveLetter) {
                    $PantherPath = "$($Part.DriveLetter):\Windows\Panther"
                    if (-not (Test-Path $PantherPath)) { New-Item -ItemType Directory -Path $PantherPath -Force | Out-Null }
                    $computerName = if ($client.NewPCName) { $client.NewPCName } else { $vmName }
                    Get-ClientUnattend -ComputerName $computerName | Out-File -FilePath "$PantherPath\unattend.xml" -Encoding UTF8
                }
            } finally {
                Dismount-VHD -Path $vhdPath
            }

            New-VM -Name $vmName -MemoryStartupBytes ($client.MemoryStartMB * 1MB) -Generation 2 -VHDPath $vhdPath -SwitchName $client.Switch | Out-Null
            Set-VMMemory -VMName $vmName -DynamicMemoryEnabled $true -MinimumBytes ($client.MemoryMinMB * 1MB) -MaximumBytes ($client.MemoryMaxMB * 1MB)
            Set-VMProcessor -VMName $vmName -Count $client.CpuCount
            Set-VM -Name $vmName -CheckpointType Disabled

            Get-VMNetworkAdapter -VMName $vmName | Rename-VMNetworkAdapter -NewName "NIC-Client"
            Start-VM -Name $vmName
        } else {
            $DesiredStartupBytes = $client.MemoryStartMB * 1MB
            $DesiredMinBytes = $client.MemoryMinMB * 1MB
            $DesiredMaxBytes = $client.MemoryMaxMB * 1MB

            $nicClient = Get-VMNetworkAdapter -VMName $vmName -Name "NIC-Client" -ErrorAction SilentlyContinue
            $currentClientSwitch = if ($nicClient) { $nicClient.SwitchName } else { $null }

            $HardwareUpdateNeeded = $false
            $NetworkUpdateNeeded = $false

            if ($existingVM.ProcessorCount -ne $client.CpuCount) { $HardwareUpdateNeeded = $true }
            if ($existingVM.MemoryStartup -ne $DesiredStartupBytes) { $HardwareUpdateNeeded = $true }
            if ($existingVM.MemoryMinimum -ne $DesiredMinBytes) { $HardwareUpdateNeeded = $true }
            if ($existingVM.MemoryMaximum -ne $DesiredMaxBytes) { $HardwareUpdateNeeded = $true }
            if ($nicClient -and $currentClientSwitch -ne $client.Switch) { $NetworkUpdateNeeded = $true }

            if ($HardwareUpdateNeeded -or $NetworkUpdateNeeded) {
                Write-Host "Aktualisiere bestehenden Client: $vmName" -ForegroundColor Yellow
                $wasRunning = $existingVM.State -eq 'Running'

                if ($HardwareUpdateNeeded -and $wasRunning) { Stop-VM -Name $vmName -Force }
                if ($HardwareUpdateNeeded) {
                    Set-VMMemory -VMName $vmName -DynamicMemoryEnabled $true -StartupBytes $DesiredStartupBytes -MinimumBytes $DesiredMinBytes -MaximumBytes $DesiredMaxBytes
                    Set-VMProcessor -VMName $vmName -Count $client.CpuCount
                }
                if ($NetworkUpdateNeeded) { $nicClient | Connect-VMNetworkAdapter -SwitchName $client.Switch }
                if ($HardwareUpdateNeeded -and $wasRunning) { Start-VM -Name $vmName }
            } else {
                Write-Host "Client '$vmName' ist auf dem neuesten Stand." -ForegroundColor DarkGreen
            }
        }
    } catch {
        Write-Error "Fehler beim Verarbeiten von Client '$vmName': $($_.Exception.Message)"
        Write-Warning "Ueberspringe '$vmName' und fahre mit der naechsten VM fort."
        continue
    }
}

# ------------------------------------------------------------------------------
# 5. Cleanup
# ------------------------------------------------------------------------------
Write-Host "`n--- Fuehre Cleanup durch (Entferne verwaiste VMs) ---" -ForegroundColor Cyan
$AllActiveLabVMs = @($Config.Routers.Name) + @($Config.Clients.Name)
$ExistingLabVMs = Get-VM -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "^Router_|^CL_" }

foreach ($vm in $ExistingLabVMs) {
    if ($AllActiveLabVMs -notcontains $vm.Name) {
        Write-Host "VM '$($vm.Name)' ist nicht mehr in der config.json definiert. Raeume auf..." -ForegroundColor Red
        if ($vm.State -eq 'Running') { Stop-VM -Name $vm.Name -TurnOff -Force }
        $vhds = (Get-VMHardDiskDrive -VMName $vm.Name).Path
        Remove-VM -Name $vm.Name -Force
        foreach ($vhd in $vhds) {
            if (Test-Path $vhd) { Remove-Item $vhd -Force }
        }
    }
}

Write-Host "`n=========================================================" -ForegroundColor Cyan
Write-Host "Lab-Infrastruktur erfolgreich synchronisiert!" -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Cyan