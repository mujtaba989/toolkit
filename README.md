# EID MOHRE Toolkit Installer

PowerShell installer for the **Emirates ID Card Toolkit Service**.  
Compatible with **Windows 10** and **Windows 11** (PowerShell 5.1+).

---

## Quick Install

Open **PowerShell as Administrator** and run:

```powershell
irm https://raw.githubusercontent.com/mujtaba989/toolkit/main/install-eid.ps1 | iex
```

---

## What It Does

1. Checks the latest GitHub Release — skips install if already up to date.
2. Downloads `EID_MOHRE.bin`, prompts for the package password, verifies & decrypts it.
3. **Clean reinstall** of `Emirates ID Card Toolkit Service` only — other toolkit services are never touched.
   - Backs up existing config files to `C:\ProgramData\EID_MOHRE\`
   - Removes the old service and install folder
   - Installs the MSI to `C:\Program Files (x86)\Emirates ID Card Toolkit Service\`
4. Copies any extra files from the package (respects `copy-map.txt` for custom destinations).
5. Starts the service and records the installed version in the registry.

**Log file:** `C:\Windows\Temp\EID_MOHRE-deploy.log`

---

## Optional Parameters

| Parameter | Description |
|-----------|-------------|
| `-Password <string>` | Supply the package password directly (skips the prompt) |
| `-PasswordFile <path>` | Read the password from a file (e.g. a restricted network share) |

```powershell
# Example: password from a file
irm https://raw.githubusercontent.com/mujtaba989/toolkit/main/install-eid.ps1 | iex -PasswordFile "\\server\share\eid.pwd"
```

---

## Windows Compatibility

| Feature | Windows 10 | Windows 11 |
|---------|-----------|-----------|
| PowerShell 5.1 | ✅ | ✅ |
| PBKDF2-SHA256 (native .NET 4.7.2+) | ✅ with fallback | ✅ native |
| MSI install via `msiexec` | ✅ | ✅ |
| Service management (`sc.exe`) | ✅ | ✅ |

---

## Files

| File | Description |
|------|-------------|
| `install-eid.ps1` | Main installer script |
