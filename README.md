# Modular Hyper-V Lab Builder

An automated, idempotent PowerShell framework for provisioning and configuring a local Hyper-V test lab (routers and clients) based on JSON configuration files.

## Included Scripts

- **`Build-Lab.ps1`**: Creates virtual switches, synchronizes master VHDX differencing disks, injects `unattend.xml` files, and builds/updates the VMs.
- **`IPConfig.ps1`**: Configures network adapters (IPs and gateways) via PowerShell Direct based on `netconfig.json` and subsequently disables the Windows Firewall on all VMs.
- **`netconfig.json`**: Central network configuration for routers and clients.
- **Batch Starters (`.bat`)**: Facilitates convenient execution with automatic administrator privileges.

## Usage

1. Build lab infrastructure: Run `Run-Lab.bat` (or `Build-Lab.ps1`).
2. Assign IPs & disable firewall: Run `IPConfig.bat`.

## License

This project is licensed under the terms specified in the repository's license file. Please review the terms before use.

---
*Developed with support from AI collaboration for code structuring and optimization.*
