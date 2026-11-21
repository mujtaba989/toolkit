# Emirates ID Card Toolkit (MOHRE / Tasheel) 🚀

Automated silent installer, deployer, and troubleshooter for the **Emirates ID Card Toolkit Service** on **Windows 10 & Windows 11**.

Specially configured for MOHRE / Tasheel portal services (`https://eservices.mohre.gov.ae/tasheelweb/eidaservice.aspx`), smart card readers (AEGIS PRO4 / Richmond Technologies), and biometric modules.

---

## ⚡ Quick Start (Run in PowerShell as Administrator)

### 1. Fresh Install / Update
Installs or upgrades the Emirates ID Toolkit Service with all current configuration certificates, DLLs, and drivers:

```powershell
irm https://raw.githubusercontent.com/mujtaba989/toolkit/main/install-eid.ps1 | iex
```

### 2. Troubleshooter & WSS Auto-Fixer
Use this if the browser disconnects from WebSocket (`wss://`), card reader is not detected, or you get *"Failed to capture fingerprint image"*:

```powershell
irm https://raw.githubusercontent.com/mujtaba989/toolkit/main/troubleshoot-eid.ps1 | iex
```

---

## 🛠️ What This Toolkit Does

* **Automated Installation & Upgrade:**
  * Downloads and verifies encrypted package integrity via SHA-256 / AES-256.
  * Cleanly removes previous faulty versions without corrupting Windows Installer cache.
  * Deploys the latest valid Validation Gateway (`config_vg_prod`) and license certificates.
  * Registers and starts the Windows Service with auto-start settings.

* **WebSocket & Browser Stability:**
  * Automatically binds the local agent to WebSocket port `9004`.
  * Fixes service termination caused by expired gateway signing certificates.
  * Adds auto-restart recovery rules so the service never remains dead after system sleep.
  * Creates an optional watchdog task to keep the localhost connection alive during long portal sessions.

* **Hardware & Reader Integration:**
  * Automatically starts and sets the Windows Smart Card Service (`SCardSvr`) to Automatic.
  * Fully supports contact and contactless (NFC) smart card readers (AEGIS PRO4, Richmond Technologies, NCR, CCID).
  * Disables USB Selective Suspend so fingerprint readers and smart card terminals don't drop power mid-transaction.

---

## 💻 System Compatibility

| Operating System | Compatibility | PowerShell Version |
| :--- | :---: | :---: |
| **Windows 11** (All Editions, 64-bit) | ✅ 100% Verified | 5.1 / 7+ |
| **Windows 10** (All Editions, 64-bit / 32-bit) | ✅ 100% Verified | 5.1+ |

---

## 📂 Repository Structure

| File | Description |
| :--- | :--- |
| `install-eid.ps1` | Core deployment script for downloading, unpacking, and installing the toolkit. |
| `troubleshoot-eid.ps1` | Full diagnostic utility checking services, certs, USB ports, firewall, and smart cards. |
| `EID_MOHRE.bin` | Encrypted package containing the 3.1.6 MSI, DLLs, and configuration files. |

---

## 📝 Diagnostic Logs

In case of any local system issues, logs can be reviewed at:
* **Deployment Log:** `C:\Windows\Temp\EIDToolkit-install.log`
* **Toolkit Runtime Log:** `C:\EmiratesIDCardToolkitService_64\EIDAToolkit_*.log`
* **Watchdog Log:** `C:\Windows\Temp\EIDToolkit-watchdog.log`

---
*Created and maintained by [mujtaba989](https://github.com/mujtaba989)*
