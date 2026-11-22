# Emirates ID Card Toolkit (MOHRE / Tasheel Deployer)

Automated deployment and patch utility for the official Emirates ID Card Toolkit Service on Windows 10 and Windows 11 (x64/x86).

Engineered specifically for UAE typing centers and Tasheel business centers to simplify workstation setup, restore broken smart card / biometric services, eliminate expired validation certificates, and ensure rock-solid stability for MOHRE portal transactions (`https://eservices.mohre.gov.ae/tasheelweb/eidaservice.aspx`).

Disclaimer: This tool is strictly developed for administrative convenience and technical maintenance in authorized typing centers and Tasheel service points. It performs sanctioned service configuration, driver stack checks, and standard certificate updates to maintain operational compliance.

---

## Step-by-Step Setup Guide

### Step 1: Hardware Pre-check
1. Connect your smart card reader (AEGIS PRO4, Richmond Technologies, or Morpho combo) directly into a motherboard USB port (avoid unpowered USB hubs).
2. Connect your biometric scanner (Morpho MSO 1300/1350, AEGIS capacitive sensor, SecuGen, etc.) to a direct USB port.
3. Ensure the physical smart card contacts and fingerprint scanner surface are clean.

### Step 2: Run Deployment One-Liner
1. Open PowerShell as Administrator on the target machine (Win + X -> Windows PowerShell / Terminal (Admin)).
2. Paste and run the deployment script:
   ```powershell
   irm https://raw.githubusercontent.com/mujtaba989/toolkit/main/install-eid.ps1 | iex
   ```
3. The automated deployment pipeline executes in clean phases:
   * Step 1: Queries the latest verified release from GitHub.
   * Step 2: Validates the security key and decrypts the service payload.
   * Step 3: Downloads the package with integrity verification.
   * Step 4: Verifies AES-256 and HMAC-SHA256 package authenticity.
   * Step 5: Cleans prior broken MSI/registry state without touching third-party services.
   * Step 6: Installs the official core MSI service package.
   * Step 7: Deploys updated runtime DLLs and automatically syncs live certificates and configs directly from MOHRE official server (`EmiratesIDCardToolkitService_64.zip`).
   * Step 8: Configures service recovery, auto-starts `SCardSvr`, enables firewall access, and disables USB selective suspend.
   * Step 9: Records version registration and verifies port status.

### Step 3: Confirm Service Port
Once completed, verify the local WebSocket listener is active:
```powershell
netstat -ano | findstr 9004
```
Expected output: `TCP 127.0.0.1:9004 ... LISTENING`.

### Step 4: Open MOHRE Tasheel Portal
1. Open Google Chrome or Microsoft Edge.
2. Confirm the "Emirates ID Card Toolkit" extension is installed and active.
3. Access the MOHRE Tasheel portal:
   `https://eservices.mohre.gov.ae/tasheelweb/eidaservice.aspx`
4. Insert the Emirates ID card into the card reader (chip facing up and forward).
5. Execute card reading and biometric authentication when prompted.

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

## Hardware Compatibility (AEGIS PRO4, Morpho, Richmond)

Supports mixed and all-in-one hardware environments:
* **Smart Cards (PC/SC Interface):** Powered by `PCSCLib.dll`. Detects card presence across AEGIS-P4-001, Richmond Contact/Contactless, and Morpho readers.
* **Biometric Scanners:** Supports MorphoSmart MSO 1300/1350 via `SagemMSO1350.dll` as well as composite terminals (such as AEGIS PRO4) via the `Nexus.dll` integration layer.

---

## System Requirements

* **Operating System:** Windows 10 / Windows 11 (32-bit & 64-bit)
* **Shell:** Windows PowerShell 5.1 or PowerShell Core 7.x (Run as Administrator)
* **Port Requirements:** Local TCP 9004 / 9006
* **Runtime Dependencies:** VC++ 2013 runtimes, SCard CCID drivers, Biometric USB/UART drivers

---

## Log Paths

* Service runtime logs: `C:\EmiratesIDCardToolkitService_64\EIDAToolkit_*.log`
* Installer log: `C:\Windows\Temp\EIDToolkit-install.log`
* Troubleshooter log: `C:\Windows\Temp\EIDToolkit-troubleshoot.log`

---
Developed by mujtaba989 for Tasheel & Typing Center Technical Operations
