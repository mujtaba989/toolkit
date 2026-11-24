# Emirates ID Card Toolkit (MOHRE / Tasheel Deployer) - Strictly 64-Bit (x64) Only

Automated deployment and patch utility for the official Emirates ID Card Toolkit Service on 64-bit Windows 10 and Windows 11 (x64). Exclusively engineered for MorphoSmart MSO 1300 / 1350 series optical biometric scanners.

Engineered specifically for UAE typing centers and Tasheel business centers to simplify workstation setup, restore broken smart card / biometric services, eliminate expired validation certificates, and ensure rock-solid stability for MOHRE portal transactions (`https://eservices.mohre.gov.ae/tasheelweb/eidaservice.aspx`).

Disclaimer: This tool is strictly developed for administrative convenience and technical maintenance in authorized typing centers and Tasheel service points. It performs sanctioned service configuration, driver stack checks, and standard certificate updates to maintain operational compliance.

---

## Supported Workstation Architecture & Biometric Hardware

* **Operating System Architecture:** **STRICTLY 64-bit (x64) Windows 10 / 11**. 32-bit (x86) systems are not supported.
* **Biometric Hardware Engine:** **MorphoSmart MSO 1300 / 1350 Series Optical Scanners (Exclusive Production Engine)**.
* **Morpho 64-Bit Driver Auto-Healing:** Bundled in the `x64/` package (`MorphoSmart USB 64 bits Driver.msi` + WHQL signed `usbbiodriver.inf`). The installer automatically checks if the Morpho driver is missing, corrupt, or out of sync, and performs a clean silent install and Driver Store registration.
* **AEGIS PRO4 Status:** The AEGIS PRO4 capacitive terminal integration is currently **UNDER ACTIVE DEVELOPMENT** and disabled in this release. All setups automatically default to Morpho.

---

## Step-by-Step Setup Guide

### Step 1: Hardware Pre-check
1. Connect your smart card reader (Richmond Technologies, Identiv, or Morpho combo) directly into a motherboard USB port.
2. Connect your MorphoSmart MSO 1300 / 1350 optical fingerprint reader to a direct USB port.
3. Ensure the physical smart card contacts and fingerprint scanner prism glass are clean.

### Step 2: Run Deployment One-Liner
1. Open PowerShell as Administrator on the 64-bit workstation (Win + X -> Windows PowerShell / Terminal (Admin)).
2. Paste and run the deployment script:
   ```powershell
   irm https://raw.githubusercontent.com/mujtaba989/toolkit/main/install-eid.ps1 | iex
   ```
3. The automated deployment pipeline executes in clean phases:
   * Step 1: Validates strictly 64-bit (x64) architecture and queries release from GitHub.
   * Step 2: Validates the security key and decrypts the service payload.
   * Step 3: Downloads the package with integrity verification.
   * Step 4: Verifies AES-256 and HMAC-SHA256 package authenticity.
   * Step 5: Cleans prior broken MSI/registry state without touching third-party services.
   * Step 6: Verifies system runtime prerequisites (VC++ 2013 & 2015-2022 runtimes), validates the 64-bit Morpho driver (auto-repairing from `x64/` if missing/corrupt), and installs the official core MSI service package.
   * Step 7: Deploys updated runtime DLLs, enables `SagemMSO1350.dll`, and automatically syncs live certificates and configs directly from MOHRE official server (`EmiratesIDCardToolkitService_64.zip`).
   * Step 8: Configures service recovery, auto-starts `SCardSvr`, enables firewall access, and disables USB selective suspend on Morpho devices and USB hubs.
   * Step 9: Records version registration and verifies port status.

### Step 3: Confirm Service Port
Once completed, verify the local WebSocket listener is active:
```powershell
netstat -ano | findstr 9004
```
Expected output: `TCP 127.0.0.1:9004 ... LISTENING`.

### Step 4: Open MOHRE Tasheel Portal
1. Open Google Chrome or Microsoft Edge.
2. Access the MOHRE Tasheel portal:
   `https://eservices.mohre.gov.ae/tasheelweb/eidaservice.aspx`
3. Insert the Emirates ID card into the card reader (chip facing up and forward).
4. Execute card reading and biometric authentication when prompted.

---

## Diagnostic Utility

If an existing workstation experiences drops, card communication timeouts, or service interruptions:

```powershell
irm https://raw.githubusercontent.com/mujtaba989/toolkit/main/troubleshoot-eid.ps1 | iex
```

This scans 10 subsystem checks, starts any stopped background services, verifies reader bus connectivity, and applies auto-fixes immediately.

---

## Technical Highlights

1. **Validation Gateway Certificate Maintenance:**
   Updates the internal `config_vg_prod` certificates, preventing sudden agent termination and service drops.

2. **Persistent WebSocket Bridge (`127.0.0.1:9004`):**
   Configures automatic Windows service failure recovery (restart intervals at 10s, 30s, and 60s) and Windows Firewall allowances.

3. **PC/SC Subsystem (`SCardSvr`):**
   Configures the Windows Smart Card Resource Manager to Automatic startup, preventing card read failure codes (`SCARD_E_NO_SERVICE`).

4. **USB Power Management:**
   Disables USB selective suspend in the active power profile, keeping readers and biometric scanners responsive across long typing shifts.

---

## Hardware Compatibility (Morpho Exclusive)

* **Biometric Scanners:** Exclusively supports **MorphoSmart MSO 1300 / 1350** optical readers via `SagemMSO1350.dll` and WHQL 64-bit `usbbiodriver.inf`.
* **Smart Cards (PC/SC Interface):** Powered by `PCSCLib.dll`. Detects card presence across all standard contact and contactless CCID readers.
* **AEGIS PRO4 Terminal:** Status: **UNDER ACTIVE DEVELOPMENT**. Not selectable in current release.

---

## System Requirements

* **Operating System:** Windows 10 / Windows 11 (**Strictly 64-bit / x64 Only**)
* **Shell:** Windows PowerShell 5.1 or PowerShell Core 7.x (Run as Administrator)
* **Port Requirements:** Local TCP 9004 / 9006
* **Runtime Dependencies:** VC++ 2013 runtimes, SCard CCID drivers, MorphoSmart USB 64-bit Driver (bundled in `x64/`)

---

## Hardware Diagnostic & Verification Suite

To verify that your smart card reader and optical fingerprint scanner are operating properly before launching MOHRE:
1. Double-click `run-test-tool.bat` in the repository folder.
2. The interactive diagnostic dashboard opens in your browser at `http://127.0.0.1:9005/`:
   * **Smart Card Test:** Shows detected contact & contactless readers, checks card insertion, and validates Emirates ID ATR.
   * **Optical Scanner & LED Test:** Turn light ON, turn light OFF, blink light (3x), or capture a live biometric fingerprint scan rendered directly on screen.
   * **Toolkit Service Test:** Verifies live WebSocket communication with `ICAToolkitService` on port 9004.

---

## Log Paths

* Service runtime logs: `C:\EmiratesIDCardToolkitService_64\EIDAToolkit_*.log`
* Installer log: `C:\Windows\Temp\EIDToolkit-install.log`
* Troubleshooter log: `C:\Windows\Temp\EIDToolkit-troubleshoot.log`

---
Developed by mujtaba989 for Tasheel & Typing Center Technical Operations
