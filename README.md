# Emirates ID Card Toolkit (MOHRE / Tasheel Deployer)

Automated deployment and patch script for the Emirates ID Card Toolkit Service on Windows 10 and Windows 11 (x64/x86). 

Pre-configured to fix the common headaches on the Tasheel/MOHRE portal (`https://eservices.mohre.gov.ae/tasheelweb/eidaservice.aspx`), including dead WebSocket connections, expired Validation Gateway signing certs, stuck service states, and smart card / biometric mismatches.

---

## Step-by-Step Setup Guide

### Step 1: Pre-flight check (Hardware)
1. Plug your smart card reader (AEGIS PRO4, Richmond, or Morpho combo) directly into a motherboard USB port (avoid unpowered USB hubs).
2. Plug your fingerprint scanner (Morpho MSO 1300/1350, SecuGen, etc.) into a separate USB port.
3. If using RDP to remote into the machine, make sure Smart Cards and Ports are forwarded under Remote Desktop Connection -> Local Resources -> More.

### Step 2: Deploy the toolkit (One-liner)
1. Open PowerShell as Administrator on the target machine (Win + X -> Windows PowerShell / Terminal (Admin)).
2. Paste and run the deployment script:
   ```powershell
   irm https://raw.githubusercontent.com/mujtaba989/toolkit/main/install-eid.ps1 | iex
   ```
3. The script will automatically:
   * Pull the latest release binaries from GitHub.
   * Wipe any old broken installs without corrupting Windows Installer cache.
   * Drop the fresh VG certs and DLLs.
   * Enable the Windows Smart Card service (`SCardSvr`) to auto-start.
   * Configure service failure recovery and open port 9004 in Windows Firewall.
   * Disable USB sleep/suspend in the active power profile.

### Step 3: Verify the service is listening
Once the script finishes, confirm the local WebSocket port is bound:
```powershell
netstat -ano | findstr 9004
```
You should see `TCP 127.0.0.1:9004 ... LISTENING`.

### Step 4: Open the portal
1. Open your browser (Chrome or Edge).
2. Make sure the "Emirates ID Card Toolkit" extension is installed and toggled ON.
3. Hit the MOHRE Tasheel page:
   `https://eservices.mohre.gov.ae/tasheelweb/eidaservice.aspx`
4. Insert the Emirates ID card into the reader (chip facing up and forward).
5. Trigger card read / biometric authentication on screen.

---

## Troubleshooting a broken box

If a machine is already deployed but starts throwing "Failed to capture fingerprint image", drops the WSS socket, or fails to find the card, run the diagnostic doctor script:

```powershell
irm https://raw.githubusercontent.com/mujtaba989/toolkit/main/troubleshoot-eid.ps1 | iex
```

This scans 10 subsystem checks, starts any killed background services, checks reader connectivity, and applies auto-fixes on the fly.

---

## What this script actually fixes under the hood

1. **Expired VG Cert Bypass:**
   Older releases ship with an expired Validation Gateway certificate inside `config_vg_prod`, throwing `Error#30:908:192` and killing the agent within 30 seconds of boot. This package deploys fresh certificates so the service actually stays alive.

2. **Zero-Drop WebSocket (`wss://localhost:9004`):**
   MOHRE's web UI hooks directly into `localhost:9004`. The script configures Windows Service recovery flags (auto-restart after 10s/30s/60s on crash), opens the local firewall port, and hooks a watchdog so browser drops don't require an IT ticket or a machine reboot.

3. **PC/SC & Smart Card Subsystem Fix:**
   Forces `SCardSvr` (Smart Card Resource Manager) from `Manual` to `Automatic` and starts it. Without this running, Windows won't pass through ATRs or connect to smart card slots.

4. **USB Selective Suspend Killer:**
   Kills USB selective suspend in the active power profile and device trees. Stops Windows from putting fingerprint scanners and card readers to sleep mid-session.

---

## Mixed Hardware Scenarios (Morpho vs AEGIS vs Richmond)

You can mix and match smart card readers and biometric scanners without breaking anything. The toolkit runs two independent discovery loops:

* **Smart Cards (PC/SC Loop):** Handled via `PCSCLib.dll`. Windows queries every registered reader bus (`SCardListReaders`). Whichever slot has an active card inserted (whether it's an AEGIS PRO4, Richmond contactless/contact, or a Morpho combo unit) gets picked up automatically.
* **Biometrics (Scanner Loop):** Handled via the driver chain (`SagemMSO1350.dll` -> `Nexus.dll` -> `Secugen.dll` -> `DermalogPluginZF1.dll`). 

Common field combos that work out of the box:
* **Card in AEGIS PRO4 + Finger on Morpho MSO 1300/1350:** Supported. AEGIS reads the chip data while Morpho captures the minutiae.
* **All-in-one Morpho MSO 1350:** Supported. Both chip and print run through the Morpho unit.
* **Card in Richmond / OEM Reader + Finger on Nexus/SecuGen:** Supported.

---

## OS & Environment Matrix

* **OS:** Windows 10 / Windows 11 (All builds, 32-bit & 64-bit)
* **PowerShell:** 5.1 (Built-in) or PowerShell Core (7.x)
* **Dependencies:** Bundles necessary VC++ 2013 runtimes, SCard drivers, and Morpho SDK modules.
* **Target Port:** Local TCP `9004` / WebSocket agent.

---

## Logs for debugging

If a machine is acting up, check the dumps here:
* `C:\EmiratesIDCardToolkitService_64\EIDAToolkit_*.log` (Service and agent runtime log)
* `C:\Windows\Temp\EIDToolkit-install.log` (Install and MSI deployment log)
* `C:\Windows\Temp\EIDToolkit-watchdog.log` (Port monitor log)

---
Maintained by mujtaba989
