# Modular Hyper-V Lab Builder & Monitor

An automated, idempotent PowerShell framework for provisioning, configuring, and monitoring a local Hyper-V test lab (routers and clients) based on JSON configuration files.

## Included Scripts & Files

- **`Build-Lab.ps1`**: Creates virtual switches, synchronizes master VHDX differencing disks, injects `unattend.xml` files, and builds/updates the VMs.
- **`IPConfig.ps1`**: Configures network adapters (IPs and gateways) via PowerShell Direct based on `netconfig.json` and subsequently disables the Windows Firewall on all VMs.
- **`Build-SimpleRoutes.ps1`**: Sets up clean static routes between router VMs based on the network configuration without enforcing hard metrics.
- **`Monitor.ps1`**: Dynamic health-check and automated failover engine. Uses an intelligent "scout" neighbor mechanism to test backbone link availability and dynamically reroutes traffic between primary (`Backbone_one`) and backup (`Backbone_two`) paths.
- **`netconfig.json`**: Central network configuration file defining VM network adapters, IP assignments, and virtual switches.
- **`monitor.json`**: Configuration for the live monitoring engine, defining check intervals, hysteresis thresholds, primary/backup backbone IPs, and router neighbor topologies.
- **Batch Starters (`.bat`)**: Facilitate convenient execution with automatic administrator privileges.

## Network Plan & Configuration (`.json`)

### 1. `netconfig.json`
Defines the structural blueprint for your VMs and their interfaces, mapping them to virtual switches (city networks and redundant backbones) along with their respective IP addresses and prefix lengths.

### 2. `monitor.json`
Configures the high-availability monitoring behavior:
- **Settings**: Polling intervals, failure/success counts (`FailThreshold` / `OkThreshold`), and interface alias fallbacks.
- **Routers**: Maps each router name, its local city network CIDR, `PrimaryIP` (Backbone 1), `BackupIP` (Backbone 2), and its `Neighbors` used for external scout-pings.

## Usage

1. **Build lab infrastructure**: Run `Run-Lab.bat` (or `Build-Lab.ps1`).
2. **Assign IPs & firewall settings**: Run `IPConfig.bat`.
3. **Set up initial routes**: Run `Build-SimpleRoutes.ps1`.
4. **Run Live Monitoring & Redundancy**: Run `Monitor.ps1`.

## License

This project is licensed under the terms specified in the repository's license file. Please review the terms before use.

---
*Developed with support from AI collaboration for code structuring and optimization.*
