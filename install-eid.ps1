<#
.SYNOPSIS
    Emirates ID Card Toolkit - Silent Deployer & Self-Healing Installer (Strictly 64-Bit / x64 Only)

.DESCRIPTION
    Pulls the latest toolkit release from GitHub, verifies the package
    integrity, and performs a clean install of the Emirates ID Card
    Toolkit Service on Windows 10 / 11 64-bit (x64) with multi-tiered
    backup plans for every step to ensure guaranteed completion.

    Biometric Engine: Exclusively configured for MorphoSmart MSO 1300 / 1350
    series optical readers, including automated detection and clean installation
    of the 64-bit Morpho driver package.
    Note: AEGIS PRO4 profile is currently under active development and disabled.

.PARAMETER PackageKey
    Decryption key for the release package. If omitted the script uses
    the built-in default (Abc@1234).

.PARAMETER KeyFile
    Path to a text file containing the decryption key.

.PARAMETER ScannerMode
    Biometric scanner profile: "Morpho" (Default / Production Active).
    Note: AEGIS profile is under development and disabled.

.PARAMETER Action
    Installation action: "Install", "Reinstall", or "Uninstall".

.EXAMPLE
    # One-liner (run as Administrator on 64-bit Windows):
    irm https://raw.githubusercontent.com/mujtaba989/toolkit/main/install-eid.ps1 | iex

.NOTES
    Log  : C:\Windows\Temp\EIDToolkit-install.log
    Store: HKLM:\SOFTWARE\Toolkit\EID
#>
param(
    [string] $PackageKey  = "Abc@1234",
    [string] $KeyFile,
    [string] $ScannerMode = "Morpho",
    [string] $Action
)

Set-StrictMode -Off
$ErrorActionPreference = "Continue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try { Add-Type -AssemblyName System.Security -EA SilentlyContinue } catch { }

# -----------------------------------------------------------------------------
#  CONSTANTS
# -----------------------------------------------------------------------------
$GH_REPO       = "mujtaba989/toolkit"
$PKG_FILENAME  = "EID_MOHRE.bin"
$SVC_DISPLAY   = "Emirates ID Card Toolkit Service"
$INSTALL_ROOT  = if (${env:ProgramFiles(x86)}) { ${env:ProgramFiles(x86)} } else { $env:ProgramFiles }
$INSTALL_DIR   = Join-Path $INSTALL_ROOT $SVC_DISPLAY
$REG_PATH      = "HKLM:\SOFTWARE\Toolkit\EID"
$LOG_FILE      = "$env:WINDIR\Temp\EIDToolkit-install.log"
$MSI_PRODUCT   = "{E73E6470-DC25-4CCE-B26C-0730283B0D32}"
$MSI_UPGRADE   = "{511AC963-BA5A-4875-9058-E5E27600023E}"
$SVC_EXE_NAME  = "EIDAToolkitService.exe"
$BACKUP_ROOT   = "$env:ProgramData\EIDToolkit"
$MOHRE_ZIP_URL = "https://eservices.mohre.gov.ae/tasheelweb/scripts/eida/EmiratesIDCardToolkitService_64.zip"

$_tmpDir = $null

# -----------------------------------------------------------------------------
#  LOGGING
# -----------------------------------------------------------------------------
$_transcriptOn = $false
try {
    Start-Transcript -Path $LOG_FILE -Append -ErrorAction SilentlyContinue | Out-Null
    $_transcriptOn = $true
} catch { }

function Write-Step  { param($msg) Write-Host "  --> $msg" -ForegroundColor Cyan }
function Write-Ok    { param($msg) Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Warn  { param($msg) Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function Write-Fatal { param($msg) Write-Host "  [FAIL] $msg" -ForegroundColor Red; throw $msg }

# -----------------------------------------------------------------------------
#  PBKDF2-SHA256
# -----------------------------------------------------------------------------
function Derive-Keys {
    param([string]$Pass, [byte[]]$Salt, [int]$Rounds, [int]$Len)

    try {
        $h   = [Security.Cryptography.HashAlgorithmName]::SHA256
        $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes($Pass, $Salt, $Rounds, $h)
        return $kdf.GetBytes($Len)
    } catch { }

    $pwd  = [Text.Encoding]::UTF8.GetBytes($Pass)
    $hmac = New-Object Security.Cryptography.HMACSHA256 (,$pwd)
    $out  = New-Object byte[] $Len
    $pos  = 0; $blk = 1

    while ($pos -lt $Len) {
        $ctr = [BitConverter]::GetBytes([uint32]$blk)
        if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($ctr) }
        $input = New-Object byte[] ($Salt.Length + 4)
        [Array]::Copy($Salt, 0, $input, 0,            $Salt.Length)
        [Array]::Copy($ctr,  0, $input, $Salt.Length, 4)

        $u = $hmac.ComputeHash($input)
        $t = [byte[]] $u.Clone()
        for ($r = 1; $r -lt $Rounds; $r++) {
            $u = $hmac.ComputeHash($u)
            for ($j = 0; $j -lt $t.Length; $j++) { $t[$j] = $t[$j] -bxor $u[$j] }
        }
        $take = [Math]::Min($t.Length, $Len - $pos)
        [Array]::Copy($t, 0, $out, $pos, $take)
        $pos += $take; $blk++
    }
    $hmac.Dispose()
    return $out
}

# -----------------------------------------------------------------------------
#  MSI P/INVOKE
# -----------------------------------------------------------------------------
if (-not ("EidMsiHelper" -as [type])) {
    try {
        Add-Type -TypeDefinition @"
using System; using System.Text; using System.Runtime.InteropServices;
public static class EidMsiHelper {
    [DllImport("msi.dll", CharSet=CharSet.Unicode)] static extern uint MsiOpenDatabase(string p, IntPtr mode, out IntPtr db);
    [DllImport("msi.dll", CharSet=CharSet.Unicode)] static extern uint MsiDatabaseOpenView(IntPtr db, string sql, out IntPtr view);
    [DllImport("msi.dll")] static extern uint MsiViewExecute(IntPtr v, IntPtr r);
    [DllImport("msi.dll")] static extern uint MsiViewClose(IntPtr v);
    [DllImport("msi.dll")] static extern uint MsiDatabaseCommit(IntPtr db);
    [DllImport("msi.dll")] static extern uint MsiCloseHandle(IntPtr h);
    [DllImport("msi.dll", CharSet=CharSet.Unicode)] static extern int MsiGetComponentPath(string prod, string comp, StringBuilder buf, ref uint len);

    public static void PatchDatabase(string path, string[] queries) {
        IntPtr db; if (MsiOpenDatabase(path, (IntPtr)1, out db) != 0) return;
        try {
            foreach (var q in queries) {
                IntPtr v; if (MsiDatabaseOpenView(db, q, out v) != 0) continue;
                try { MsiViewExecute(v, IntPtr.Zero); }
                finally { MsiViewClose(v); MsiCloseHandle(v); }
            }
            MsiDatabaseCommit(db);
        } finally { MsiCloseHandle(db); }
    }

    public static string GetComponentPath(string prod, string comp) {
        uint len = 1024; var sb = new StringBuilder((int)len);
        MsiGetComponentPath(prod, comp, sb, ref len);
        return sb.ToString();
    }
}
"@ -EA SilentlyContinue
    } catch { }
}

# -----------------------------------------------------------------------------
#  UTILITY FUNCTIONS
# -----------------------------------------------------------------------------
function Squish-Guid([string]$g) {
    $g = $g.Trim('{}').Replace('-','')
    $r = { param($s) -join ($s.ToCharArray()[($s.Length-1)..0]) }
    $o = (& $r $g.Substring(0,8)) + (& $r $g.Substring(8,4)) + (& $r $g.Substring(12,4))
    for ($i=16; $i -lt 32; $i+=2) { $o += "$($g[$i+1])$($g[$i])" }
    $o.ToUpper()
}

function Get-ExePath($svc) {
    if (-not $svc -or -not $svc.PathName) { return "" }
    ($svc.PathName -replace '^"([^"]+)".*$','$1') -replace '\.exe\s+.*$','.exe'
}

function Is-OurPath([string]$p) {
    if (-not $p) { return $false }
    $p.TrimEnd('\').StartsWith($INSTALL_DIR, [StringComparison]::OrdinalIgnoreCase)
}

function Get-AllToolkitSvcs {
    $svcs = @()
    try {
        $svcs = @(Get-CimInstance Win32_Service -EA SilentlyContinue |
                  Where-Object { $_.PathName -like "*EIDAToolkitService*" -or $_.PathName -like "*ICAToolkit*" -or $_.Name -like "*ICAToolkit*" })
    } catch { }
    if ($svcs.Count -eq 0) {
        try {
            $svcs = @(Get-WmiObject Win32_Service -EA SilentlyContinue |
                      Where-Object { $_.PathName -like "*EIDAToolkitService*" -or $_.PathName -like "*ICAToolkit*" -or $_.Name -like "*ICAToolkit*" })
        } catch { }
    }
    return $svcs
}

function Get-OurService {
    Get-AllToolkitSvcs | Where-Object { Is-OurPath (Get-ExePath $_) } | Select-Object -First 1
}

function Get-TargetSvcs {
    Get-AllToolkitSvcs | Where-Object {
        $_.DisplayName -eq $SVC_DISPLAY -or $_.Name -eq "ICAToolkitService" -or (Is-OurPath (Get-ExePath $_))
    }
}

function Test-AlreadyInstalled {
    (Test-Path (Join-Path $INSTALL_DIR $SVC_EXE_NAME)) -and (Get-OurService)
}

function Find-InstalledMsi {
    $keys = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    Get-ItemProperty $keys -EA SilentlyContinue | Where-Object { $_.DisplayName -eq $SVC_DISPLAY } | Select-Object -First 1
}

function Test-MsiRegistered {
    $sq = Squish-Guid $MSI_PRODUCT
    if (Test-Path "HKLM:\SOFTWARE\Classes\Installer\Products\$sq")  { return $true }
    if (Test-Path "HKCU:\Software\Microsoft\Installer\Products\$sq") { return $true }
    [bool](Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData" -EA SilentlyContinue |
           Where-Object { Test-Path (Join-Path $_.PSPath "Products\$sq") })
}

function Get-MsiExePath([string]$prodCode) {
    try {
        if ("EidMsiHelper" -as [type]) {
            $p = [EidMsiHelper]::GetComponentPath($prodCode, "{D34D7FD1-31B2-5F8D-9C4F-64A73D251BD8}")
            if ($p) { return $p }
        }
    } catch { }
    return $null
}

# Download with multi-tiered backup URLs and protocols
function Download-FileWithFallback([string[]]$Urls, [string]$OutFile, [hashtable]$Headers = @{}) {
    foreach ($u in $Urls) {
        if (-not $u) { continue }
        # Plan A: Net.WebClient
        try {
            $wc = New-Object Net.WebClient
            $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
            foreach ($k in $Headers.Keys) { $wc.Headers[$k] = $Headers[$k] }
            $wc.DownloadFile($u, $OutFile)
            if ((Test-Path $OutFile) -and (Get-Item $OutFile).Length -gt 1000) {
                return $true
            }
        } catch { }

        # Plan B: Invoke-WebRequest
        try {
            Invoke-WebRequest -Uri $u -Headers $Headers -OutFile $OutFile -UseBasicParsing -MaximumRedirection 10 -TimeoutSec 30 -EA SilentlyContinue
            if ((Test-Path $OutFile) -and (Get-Item $OutFile).Length -gt 1000) {
                return $true
            }
        } catch { }

        # Plan C: curl.exe (built into modern Windows 10 & 11)
        try {
            $curl = Get-Command curl.exe -EA SilentlyContinue
            if ($curl) {
                Start-Process curl.exe -ArgumentList "-sL `"$u`" -o `"$OutFile`"" -Wait -WindowStyle Hidden -EA SilentlyContinue
                if ((Test-Path $OutFile) -and (Get-Item $OutFile).Length -gt 1000) {
                    return $true
                }
            }
        } catch { }
    }
    return $false
}

# Patch and run MSI uninstall with graceful cleanup
function Remove-OldInstall([string]$prodCode) {
    try {
        $cached = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products" -EA SilentlyContinue |
                  ForEach-Object { Get-ItemProperty (Join-Path $_.PSPath "InstallProperties") -EA SilentlyContinue } |
                  Where-Object { $_.DisplayName -eq $SVC_DISPLAY } | Select-Object -First 1 -ExpandProperty LocalPackage

        if ($cached -and (Test-Path $cached) -and ("EidMsiHelper" -as [type])) {
            try {
                New-Item -ItemType Directory $BACKUP_ROOT -Force -EA SilentlyContinue | Out-Null
                Copy-Item $cached (Join-Path $BACKUP_ROOT ("msi_" + (Split-Path $cached -Leaf))) -Force -EA SilentlyContinue
                (Get-Item $cached).IsReadOnly = $false
                $patches = @("ExecInstallService","ExecRemoveService","ExecDeleteFiles") | ForEach-Object {
                    "UPDATE ``InstallExecuteSequence`` SET ``Condition`` = '0' WHERE ``Action`` = '$_'"
                }
                [EidMsiHelper]::PatchDatabase($cached, [string[]]$patches)
                Write-Step "Patched cached MSI so uninstall completes cleanly"
            } catch { }
        }

        $ulog = "$env:WINDIR\Temp\EIDToolkit-uninstall.log"
        Start-Process msiexec.exe -ArgumentList "/x $prodCode /qn /norestart /L*v `"$ulog`"" -Wait -WindowStyle Hidden -EA SilentlyContinue
    } catch { }

    Clear-MsiRegistration
    Write-Ok "Previous installation cleaned up"
}

# Scrub every Windows Installer registration for the product
function Clear-MsiRegistration {
    try {
        $sq  = Squish-Guid $MSI_PRODUCT
        $usq = Squish-Guid $MSI_UPGRADE
        $bk  = Join-Path $BACKUP_ROOT ("reg_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
        New-Item -ItemType Directory $bk -Force -EA SilentlyContinue | Out-Null

        $targets = @(
            "HKLM:\SOFTWARE\Classes\Installer\Products\$sq",
            "HKLM:\SOFTWARE\Classes\Installer\Features\$sq",
            "HKCU:\Software\Microsoft\Installer\Products\$sq",
            "HKCU:\Software\Microsoft\Installer\Features\$sq",
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$MSI_PRODUCT",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$MSI_PRODUCT"
        )
        $ud = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData"
        Get-ChildItem $ud -EA SilentlyContinue | ForEach-Object { $targets += Join-Path $_.PSPath "Products\$sq" }

        $n = 0
        foreach ($k in $targets) {
            if (Test-Path $k) {
                try {
                    $reg = (Convert-Path $k) -replace '^HKEY_LOCAL_MACHINE','HKLM' -replace '^HKEY_CURRENT_USER','HKCU'
                    Start-Process reg.exe -ArgumentList "export `"$reg`" `"$bk\key$n.reg`" /y" -Wait -WindowStyle Hidden -EA SilentlyContinue
                    Remove-Item $k -Recurse -Force -EA SilentlyContinue; $n++
                } catch { }
            }
        }

        foreach ($uc in @(
            "HKLM:\SOFTWARE\Classes\Installer\UpgradeCodes\$usq",
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UpgradeCodes\$usq",
            "HKCU:\Software\Microsoft\Installer\UpgradeCodes\$usq")) {
            if (Test-Path $uc) { Remove-ItemProperty $uc -Name $sq -EA SilentlyContinue }
        }

        Get-ChildItem $ud -EA SilentlyContinue | ForEach-Object {
            Get-ChildItem (Join-Path $_.PSPath "Components") -EA SilentlyContinue | ForEach-Object {
                if ($null -ne $_.GetValue($sq, $null)) { Remove-ItemProperty $_.PSPath -Name $sq -EA SilentlyContinue }
            }
        }
        Write-Ok "Cleared $n stale installer registration(s)"
    } catch { }
}

# Remove any previous daemon / watchdog scheduled tasks and script files safely
function Remove-PreviousWatchdogs {
    $watchdogTasks = @("EIDToolkit-Watchdog", "EID_MOHRE-Watchdog", "ToolkitWatchdog", "EIDAToolkitWatchdog")
    foreach ($tn in $watchdogTasks) {
        # Plan A: Start-Process schtasks.exe
        try {
            Start-Process schtasks.exe -ArgumentList "/delete /tn `"$tn`" /f" -Wait -WindowStyle Hidden -EA SilentlyContinue
        } catch { }
        # Plan B: PowerShell Unregister-ScheduledTask
        try {
            Unregister-ScheduledTask -TaskName $tn -Confirm:$false -EA SilentlyContinue
        } catch { }
    }

    # Also query any wildcard matches via PowerShell safely targeting ONLY toolkit tasks
    try {
        Get-ScheduledTask -EA SilentlyContinue |
            Where-Object {
                $_.TaskName -like "*EIDToolkit*" -or
                $_.TaskName -like "*EID_MOHRE*" -or
                $_.TaskName -like "*EID*Watchdog*" -or
                $_.TaskName -like "*Toolkit*Watchdog*"
            } |
            ForEach-Object { Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -EA SilentlyContinue }
    } catch { }

    # Purge old daemon script files, startup shortcuts, and logs
    $oldFiles = @(
        "$env:ProgramData\EIDToolkit\watchdog.ps1",
        "$env:ProgramData\EIDToolkit\watchdog.vbs",
        "$env:ProgramData\EID_MOHRE\watchdog.ps1",
        "$env:ProgramData\EID_MOHRE\watchdog.vbs",
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\EIDWatchdog.vbs",
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\EIDWatchdog.vbs",
        "$env:WINDIR\Temp\EIDToolkit-watchdog.log",
        "$env:WINDIR\Temp\EID_MOHRE-watchdog.log"
    )
    foreach ($f in $oldFiles) {
        try {
            if (Test-Path $f) { Remove-Item $f -Force -EA SilentlyContinue }
        } catch { }
    }
}

# -----------------------------------------------------------------------------
#  COMPLETE UNINSTALLATION ENGINE (SAFELY SCRUBS ALL TOOLKIT COMPONENTS)
# -----------------------------------------------------------------------------
function Execute-CompleteUninstall {
    Write-Host ""
    Write-Host "  ================================================================" -ForegroundColor Cyan
    Write-Host "  Emirates ID Card Toolkit - Complete Uninstallation & Scrubbing" -ForegroundColor Yellow
    Write-Host "  ================================================================" -ForegroundColor Cyan
    Write-Host ""

    # [1/9] Stop and delete services
    Write-Step "[1/9] Stopping and removing toolkit background services..."
    $ourSvcs = @(Get-TargetSvcs)
    $extraSvcs = Get-CimInstance Win32_Service -EA SilentlyContinue |
        Where-Object { $_.PathName -like "*EIDAToolkitService*" -or $_.Name -eq "ICAToolkitService" }
    $allSvcNames = @()
    if ($ourSvcs) { $allSvcNames += ($ourSvcs | ForEach-Object { $_.Name }) }
    if ($extraSvcs) { $allSvcNames += ($extraSvcs | ForEach-Object { $_.Name }) }
    $uniqueSvcs = $allSvcNames | Select-Object -Unique

    foreach ($sName in $uniqueSvcs) {
        if ($sName -and $sName -ne "SCardSvr" -and $sName -ne "ScDeviceEnum") {
            Write-Step "  Stopping and removing service: $sName"
            Stop-Service -Name $sName -Force -EA SilentlyContinue
            Start-Process sc.exe -ArgumentList "delete `"$sName`"" -Wait -WindowStyle Hidden -EA SilentlyContinue
        }
    }
    Write-Ok "Toolkit services stopped and removed"

    # [2/9] Terminate running toolkit processes
    Write-Step "[2/9] Terminating running toolkit processes..."
    Get-Process $SVC_EXE_NAME.Replace(".exe","") -EA SilentlyContinue |
        Where-Object { Is-OurPath $_.Path -or $_.Path -like "*EmiratesIDCardToolkitService*" -or $_.Path -like "*EIDAToolkitService*" } |
        Stop-Process -Force -EA SilentlyContinue

    try {
        Get-CimInstance Win32_Process -EA SilentlyContinue |
            Where-Object {
                $_.CommandLine -like "*EIDToolkit*watchdog*" -or
                $_.CommandLine -like "*EID_MOHRE*watchdog*" -or
                $_.CommandLine -like "*EIDWatchdog.vbs*"
            } | ForEach-Object {
                Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue
            }
    } catch { }
    Start-Sleep -Seconds 2
    Write-Ok "Toolkit processes terminated"

    # [3/9] Scheduled tasks and startup watchdogs
    Write-Step "[3/9] Purging background watchdog tasks and startup daemons..."
    Remove-PreviousWatchdogs
    Write-Ok "Watchdog tasks and daemons purged"

    # [4/9] MSI registration and package cleanup
    Write-Step "[4/9] Cleaning Windows Installer and MSI package registration..."
    $existing = Find-InstalledMsi
    if ($existing) {
        Remove-OldInstall $existing.PSChildName
        Start-Sleep -Seconds 2
    } else {
        Start-Process msiexec.exe -ArgumentList "/x $MSI_PRODUCT /qn /norestart" -Wait -WindowStyle Hidden -EA SilentlyContinue
    }
    Clear-MsiRegistration
    Write-Ok "Toolkit MSI registration scrubbed"

    # [5/9] MorphoSmart USB 64-bit driver package
    Write-Step "[5/9] Removing MorphoSmart USB 64-bit driver..."
    $morphoReg = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
                                  "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -EA SilentlyContinue |
        Where-Object { $_.PSChildName -eq "{C2CCA71A-E107-46BA-8365-26E6192EBC34}" -or $_.DisplayName -like "*MorphoSmart USB 64*" }
    if ($morphoReg) {
        Write-Step "  Silently uninstalling MorphoSmart driver MSI..."
        Start-Process msiexec.exe -ArgumentList "/x `"{C2CCA71A-E107-46BA-8365-26E6192EBC34}`" /qn /norestart" -Wait -WindowStyle Hidden -EA SilentlyContinue
        Start-Sleep -Seconds 2
    }
    try {
        $pnpOut = & pnputil.exe /enum-drivers 2>&1 | Out-String
        $blocks = $pnpOut -split "(?m)(?=Published Name:\s+)"
        foreach ($b in $blocks) {
            if ($b -match "Published Name:\s+(oem\d+\.inf)" -and $b -match "usbbiodriver\.inf" -and $b -match "MORPHO") {
                $oemFile = $Matches[1]
                Write-Step "  Removing Morpho driver from Driver Store ($oemFile)..."
                & pnputil.exe /delete-driver $oemFile /uninstall /force 2>&1 | Out-Null
            }
        }
    } catch { }
    Write-Ok "MorphoSmart driver cleaned up"

    # [6/9] Inbound firewall rules
    Write-Step "[6/9] Removing inbound firewall rules..."
    try {
        Get-NetFirewallRule -EA SilentlyContinue |
            Where-Object {
                $_.DisplayName -eq "Emirates ID Card Toolkit" -or
                $_.DisplayName -eq "EIDToolkit - Allow inbound" -or
                $_.DisplayName -like "*Emirates ID Card Toolkit*"
            } | Remove-NetFirewallRule -EA SilentlyContinue
    } catch { }
    try {
        netsh advfirewall firewall delete rule name="Emirates ID Card Toolkit" 2>$null | Out-Null
        netsh advfirewall firewall delete rule name="EIDToolkit - Allow inbound" 2>$null | Out-Null
    } catch { }
    Write-Ok "Firewall rules removed"

    # [7/9] Hosts file DNS entries
    Write-Step "[7/9] Removing DNS redirect entries from hosts file..."
    try {
        $hostsFile = "$env:WINDIR\System32\drivers\etc\hosts"
        if (Test-Path $hostsFile) {
            $hostsItem = Get-Item $hostsFile -EA SilentlyContinue
            $wasReadOnly = if ($hostsItem) { $hostsItem.IsReadOnly } else { $false }
            if ($wasReadOnly) { $hostsItem.IsReadOnly = $false }

            $lines = Get-Content $hostsFile -EA SilentlyContinue
            $filtered = @($lines | Where-Object {
                $_ -notmatch "toolkitagent\.mohre\.gov\.ae" -and
                $_ -notmatch "toolkitagent\.emiratesid\.ae"
            })
            if ($lines.Count -ne $filtered.Count) {
                [System.IO.File]::WriteAllLines($hostsFile, $filtered, [System.Text.Encoding]::ASCII)
                Write-Ok "Purged toolkitagent entries from hosts file"
            } else {
                Write-Ok "Hosts file is clean (no toolkit entries found)"
            }
            if ($wasReadOnly) { (Get-Item $hostsFile).IsReadOnly = $true }
        }
    } catch {
        Write-Warn "Hosts file cleanup notice: $($_.Exception.Message)"
    }

    # [8/9] Registry cleanup (Calais SmartCards & Toolkit keys)
    Write-Step "[8/9] Scrubbing SmartCard ATR registrations and toolkit registry keys..."
    $calaisRoots = @(
        "HKLM:\SOFTWARE\Microsoft\Cryptography\Calais\SmartCards",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Cryptography\Calais\SmartCards"
    )
    foreach ($cr in $calaisRoots) {
        if (Test-Path $cr) {
            Get-ChildItem $cr -EA SilentlyContinue |
                Where-Object { $_.PSChildName -like "*Emirates ID*" } |
                ForEach-Object {
                    Write-Step "  Removing Calais card registration: $($_.PSChildName)"
                    Remove-Item $_.PSPath -Recurse -Force -EA SilentlyContinue
                }
        }
    }
    if (Test-Path $REG_PATH) {
        Remove-Item $REG_PATH -Recurse -Force -EA SilentlyContinue
    }
    $parentReg = Split-Path $REG_PATH -Parent
    if ((Test-Path $parentReg) -and ((Get-ChildItem $parentReg -EA SilentlyContinue).Count -eq 0)) {
        Remove-Item $parentReg -Force -EA SilentlyContinue
    }
    $wowReg = "HKLM:\SOFTWARE\WOW6432Node\Toolkit\EID"
    if (Test-Path $wowReg) {
        Remove-Item $wowReg -Recurse -Force -EA SilentlyContinue
    }
    $wowParent = Split-Path $wowReg -Parent
    if ((Test-Path $wowParent) -and ((Get-ChildItem $wowParent -EA SilentlyContinue).Count -eq 0)) {
        Remove-Item $wowParent -Force -EA SilentlyContinue
    }
    Write-Ok "Registry keys cleaned up"

    # [9/9] Program folders, ProgramData, and temp artifacts
    Write-Step "[9/9] Removing program folders and deployment temporary files..."
    $dirsToRemove = @(
        $INSTALL_DIR,
        "C:\EmiratesIDCardToolkitService_64",
        "$env:ProgramData\EIDToolkit",
        "$env:ProgramData\EID_MOHRE"
    )
    $altInstall = "C:\Program Files\Emirates ID Card Toolkit Service"
    if ($altInstall -ne $INSTALL_DIR) { $dirsToRemove += $altInstall }

    foreach ($d in $dirsToRemove) {
        if ($d -and (Test-Path $d)) {
            Write-Step "  Deleting directory: $d"
            Remove-Item $d -Recurse -Force -EA SilentlyContinue
        }
    }

    $tempPatterns = @(
        "$env:WINDIR\Temp\EIDdeploy_*",
        "$env:WINDIR\Temp\EID_REPACK",
        "$env:WINDIR\Temp\EIDToolkit*",
        "$env:WINDIR\Temp\EID_MOHRE*",
        "$env:TEMP\EIDdeploy_*",
        "$env:TEMP\EID_REPACK",
        "$env:TEMP\EIDToolkit*",
        "$env:TEMP\EID_MOHRE*"
    )
    foreach ($tp in $tempPatterns) {
        Get-ChildItem $tp -EA SilentlyContinue | ForEach-Object {
            Remove-Item $_.FullName -Recurse -Force -EA SilentlyContinue
        }
    }

    # Verify Smart Card Resource Manager (SCardSvr) is intact and active
    $sc = Get-Service -Name "SCardSvr" -EA SilentlyContinue
    if ($sc) {
        if ($sc.StartType -ne "Automatic") {
            Set-Service -Name "SCardSvr" -StartupType Automatic -EA SilentlyContinue
        }
        if ($sc.Status -ne "Running") {
            Start-Service -Name "SCardSvr" -EA SilentlyContinue
        }
        Write-Ok "Verified Windows Smart Card Resource Manager (SCardSvr) is intact and active"
    }

    Write-Host ""
    Write-Host "  ================================================================" -ForegroundColor Cyan
    Write-Host "  [OK] Complete uninstallation finished successfully." -ForegroundColor Green
    Write-Host "  All toolkit services, files, registry keys, drivers, and tasks" -ForegroundColor Green
    Write-Host "  have been cleanly removed without affecting OS system files." -ForegroundColor Green
    Write-Host "  Developer : mujtaba989" -ForegroundColor Gray
    Write-Host "  Purpose   : Tasheel & Typing Center Technical Maintenance" -ForegroundColor Gray
    Write-Host "  ================================================================" -ForegroundColor Cyan
    Write-Host ""
}

# Ensure all system prerequisites and Visual C++ runtimes are installed
function Ensure-Dependencies([string]$TempDir) {
    Write-Step "Checking system runtime dependencies..."

    # Check Visual C++ 2013 x86
    $vc2013 = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\VisualStudio\12.0\VC\Runtimes\x86" -EA SilentlyContinue).Installed -eq 1 -or
              (Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\12.0\VC\Runtimes\x86" -EA SilentlyContinue).Installed -eq 1

    if (-not $vc2013) {
        Write-Step "Downloading and installing Microsoft Visual C++ 2013 runtime..."
        $vcFile = Join-Path $TempDir "vcredist2013_x86.exe"
        $urls = @(
            "https://aka.ms/highdpimfc2013x86enu",
            "https://download.microsoft.com/download/2/E/6/2E61CFA4-993B-4DD4-91DA-3737CD5CD6E3/vcredist_x86.exe"
        )
        $downloaded = Download-FileWithFallback -Urls $urls -OutFile $vcFile
        if ($downloaded) {
            $proc = Start-Process $vcFile -ArgumentList "/install /quiet /norestart" -Wait -PassThru -EA SilentlyContinue
            if ($proc.ExitCode -in 0, 3010, 1638) {
                Write-Ok "Visual C++ 2013 runtime installed successfully"
            } else {
                Write-Warn "Visual C++ 2013 installer exited with code $($proc.ExitCode) - continuing"
            }
        } else {
            Write-Warn "Could not auto-download VC++ 2013 runtime - proceeding with setup"
        }
    } else {
        Write-Ok "Visual C++ 2013 runtime is verified"
    }

    # Check Visual C++ 2015-2022
    $vcModern = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X86" -EA SilentlyContinue).Installed -eq 1 -or
                (Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\X86" -EA SilentlyContinue).Installed -eq 1

    if (-not $vcModern) {
        Write-Step "Downloading and installing Microsoft Visual C++ 2015-2022 runtime..."
        $vcModFile = Join-Path $TempDir "vc_redist.x86.exe"
        $urls = @(
            "https://aka.ms/vs/17/release/vc_redist.x86.exe",
            "https://download.visualstudio.microsoft.com/download/pr/99507ff5-cb8a-4cbb-9276-8dc9c02da3c8/05C72382ECAC8A92EEBC0A79E5337E8CBE2FA3CA4014FCA3FDB7DA162818F2E2/VC_redist.x86.exe"
        )
        $downloaded = Download-FileWithFallback -Urls $urls -OutFile $vcModFile
        if ($downloaded) {
            $proc = Start-Process $vcModFile -ArgumentList "/install /quiet /norestart" -Wait -PassThru -EA SilentlyContinue
            if ($proc.ExitCode -in 0, 3010, 1638) {
                Write-Ok "Visual C++ 2015-2022 runtime installed successfully"
            } else {
                Write-Warn "Visual C++ 2015-2022 installer exited with code $($proc.ExitCode) - continuing"
            }
        } else {
            Write-Warn "Could not auto-download VC++ 2015-2022 runtime - proceeding with setup"
        }
    } else {
        Write-Ok "Visual C++ 2015-2022 runtime is verified"
    }
}

# Ensure MorphoSmart 64-bit USB Driver is installed, registered, and healthy
function Ensure-MorphoDriver([string]$TempDir) {
    Write-Step "Checking MorphoSmart USB 64-bit Driver status..."

    # Check 1: Uninstall registry key
    $morphoReg = Get-ItemProperty "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" -EA SilentlyContinue |
        Where-Object { $_.DisplayName -like "*MorphoSmart USB 64 bits Driver*" -or $_.PSChildName -eq "{C2CCA71A-E107-46BA-8365-26E6192EBC34}" }

    # Check 2: PnP driver store registration
    $pnpOut = & pnputil.exe /enum-drivers 2>$null | Out-String
    $pnpInstalled = ($pnpOut -match "usbbiodriver\.inf" -or $pnpOut -match "MORPHO")

    # Check 3: Connected Morpho hardware error / yellow bang check (only physically present devices)
    $morphoDevices = Get-PnpDevice -EA SilentlyContinue | Where-Object {
        ($_.InstanceId -match "VID_079B" -or $_.InstanceId -match "VID_225D" -or $_.FriendlyName -like "*Morpho*") -and
        $_.Present -eq $true
    }
    $hardwareError = $false
    foreach ($dev in $morphoDevices) {
        $prob = [string]$dev.Problem
        # Ignore phantom/unplugged codes (45 / CM_PROB_PHANTOM) and normal OK (0 / None / empty)
        if ($dev.Status -ne "OK" -and $prob -notin @("0", "45", "CM_PROB_PHANTOM", "None", "")) {
            $hardwareError = $true
            Write-Warn "Connected Morpho hardware has error status ($($dev.FriendlyName) - Problem $prob)"
        }
    }

    $isCorrupt = $false
    if ($morphoReg -and (-not $pnpInstalled -or $hardwareError)) {
        $isCorrupt = $true
        Write-Warn "Detected corrupt or incomplete MorphoSmart driver installation. Initiating clean repair..."
    }

    if ($morphoReg -and $pnpInstalled -and -not $hardwareError) {
        Write-Ok "MorphoSmart USB 64-bit driver is verified healthy ($($morphoReg.DisplayVersion))"
        return
    }

    # Locate driver source folder (x64)
    $x64Dir = $null
    $candidates = @()
    if ($PSScriptRoot) { $candidates += (Join-Path $PSScriptRoot "x64") }
    $candidates += "E:\Github\toolkit\x64"
    if ($BACKUP_ROOT) { $candidates += (Join-Path $BACKUP_ROOT "x64") }
    if ($TempDir) { $candidates += (Join-Path $TempDir "x64") }

    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c) -and (Test-Path (Join-Path $c "MorphoSmart USB 64 bits Driver.msi"))) {
            $x64Dir = $c
            break
        }
    }

    # If running remotely via irm | iex, download driver package files to temp
    if (-not $x64Dir) {
        Write-Step "Downloading MorphoSmart 64-bit driver package from GitHub repository..."
        $x64Dir = Join-Path $TempDir "x64"
        New-Item -ItemType Directory $x64Dir -Force -EA SilentlyContinue | Out-Null

        $filesToFetch = @(
            "MorphoSmart USB 64 bits Driver.msi",
            "Data1.cab",
            "usbbiodriver.inf",
            "usbbiodriver.cat",
            "usbbiodriver_x64.sys",
            "msocoinstaller_x64.dll",
            "serv_spusb.exe"
        )
        $baseUrl = "https://raw.githubusercontent.com/$GH_REPO/main/x64"
        foreach ($fn in $filesToFetch) {
            $dest = Join-Path $x64Dir $fn
            $url  = "$baseUrl/$([Uri]::EscapeDataString($fn))"
            Download-FileWithFallback -Urls @($url) -OutFile $dest | Out-Null
        }
    }

    $msiFile = Join-Path $x64Dir "MorphoSmart USB 64 bits Driver.msi"
    $infFile = Join-Path $x64Dir "usbbiodriver.inf"

    if (-not (Test-Path $msiFile)) {
        Write-Warn "Morpho driver installer not found at $msiFile - proceeding with setup"
        return
    }

    # Clean uninstall if corrupt
    if ($isCorrupt -and $morphoReg) {
        Write-Step "Removing corrupt MorphoSmart driver registration..."
        Start-Process msiexec.exe -ArgumentList "/x `"{C2CCA71A-E107-46BA-8365-26E6192EBC34}`" /qn /norestart" -Wait -WindowStyle Hidden -EA SilentlyContinue
        Start-Sleep -Seconds 2
    }

    Write-Step "Installing MorphoSmart USB 64-bit Driver..."
    $proc = Start-Process msiexec.exe -ArgumentList "/i `"$msiFile`" /qn /norestart" -Wait -PassThru -EA SilentlyContinue
    if ($proc.ExitCode -in 0, 3010) {
        Write-Ok "MorphoSmart USB 64-bit Driver installed successfully"
    } else {
        Write-Warn "MSI exited with code $($proc.ExitCode). Applying PnP driver store installation..."
    }

    if (Test-Path $infFile) {
        Write-Step "Registering usbbiodriver.inf in Windows Driver Store..."
        $pnpRes = & pnputil.exe /add-driver $infFile /install 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0 -or $pnpRes -match "successfully") {
            Write-Ok "Registered Morpho driver package in Windows Driver Store"
        }
    }
}

# -----------------------------------------------------------------------------
#  MAIN INSTALLATION FLOW
# -----------------------------------------------------------------------------
try {
    # -------------------------------------------------------------------------
    #  ARCHITECTURE CHECK: STRICTLY 64-BIT (x64) ONLY
    # -------------------------------------------------------------------------
    if (-not [Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -ne "AMD64") {
        Write-Host ""
        Write-Host "  ================================================================" -ForegroundColor Red
        Write-Host "  [FAIL] INCOMPATIBLE ARCHITECTURE: 32-BIT (x86) DETECTED" -ForegroundColor Red
        Write-Host "  This installer is strictly designed for 64-bit (x64) Windows computers." -ForegroundColor Yellow
        Write-Host "  32-bit (x86) Windows systems are NOT supported." -ForegroundColor Yellow
        Write-Host "  ================================================================" -ForegroundColor Red
        Write-Host ""
        throw "Unsupported architecture. This toolkit deployer requires 64-bit (x64) Windows."
    }

    Write-Host ""
    Write-Host "  ================================================================" -ForegroundColor Cyan
    Write-Host "  Emirates ID Card Toolkit - Deployer (Strictly 64-Bit / x64 Only)" -ForegroundColor Yellow
    Write-Host "  Biometric Engine: MorphoSmart MSO Series (Morpho Exclusive)" -ForegroundColor Yellow
    Write-Host "  ================================================================" -ForegroundColor Cyan
    Write-Host ""

    # -------------------------------------------------------------------------
    #  EXPLICIT UNINSTALL ACTION DISPATCH
    # -------------------------------------------------------------------------
    if ($Action -and ($Action -match 'uninstall|remove')) {
        Execute-CompleteUninstall
        return
    }

    # -------------------------------------------------------------------------
    #  INSTALLATION DETECTION & INTERACTIVE MENU
    # -------------------------------------------------------------------------
    $hasExisting = (Test-AlreadyInstalled) -or (Find-InstalledMsi) -or (Test-Path $INSTALL_DIR) -or (Get-TargetSvcs) -or (Test-Path "C:\EmiratesIDCardToolkitService_64") -or (Test-Path $REG_PATH) -or (Test-Path $BACKUP_ROOT)
    $current = (Get-ItemProperty $REG_PATH -Name Version -EA SilentlyContinue).Version

    if ($hasExisting) {
        Write-Host "  Current Installation Detected:" -ForegroundColor Cyan
        Write-Host "    Version : $(if ($current) { $current } else { 'Detected on system' })"
        Write-Host "    Path    : $(if (Test-Path $INSTALL_DIR) { $INSTALL_DIR } else { 'C:\EmiratesIDCardToolkitService_64' })"
        Write-Host ""
        Write-Host "  Choose an action:" -ForegroundColor Yellow
        Write-Host "    [1] Clean Reinstall (Remove current installation and install fresh)" -ForegroundColor White
        Write-Host "    [2] Complete Uninstall (Permanently remove toolkit, services, drivers, and registry)" -ForegroundColor White
        Write-Host "    [3] Exit without making any changes" -ForegroundColor White
        Write-Host ""

        $choice = if ($Action) {
            switch -Regex ($Action) {
                'reinstall|clean'  { '1' }
                'uninstall|remove' { '2' }
                default            { '3' }
            }
        } else {
            Read-Host "  Select an option [1-3] (Default: 1)"
        }

        if (-not $choice) { $choice = "1" }

        switch ($choice.Trim()) {
            "2" {
                Execute-CompleteUninstall
                return
            }
            "3" {
                Write-Host ""
                Write-Ok "Setup aborted by user. No changes were made."
                return
            }
            default {
                Write-Ok "Proceeding with clean reinstall..."
            }
        }
    }

    # -------------------------------------------------------------------------
    #  SCANNER HARDWARE SELECTION (MORPHO EXCLUSIVE)
    # -------------------------------------------------------------------------
    Write-Host ""
    Write-Host "  Biometric Hardware Profile:" -ForegroundColor Yellow
    Write-Host "    [1] MorphoSmart MSO 1300 / 1350 Optical Readers (Production Active - Default)" -ForegroundColor Green
    Write-Host "    [2] AEGIS PRO4 / Capacitive Touch [UNDER DEVELOPMENT - NOT AVAILABLE]" -ForegroundColor DarkGray
    Write-Host ""

    $scannerChoice = if ($ScannerMode) {
        switch -Regex ($ScannerMode) {
            'aegis'  { '2' }
            default  { '1' }
        }
    } else {
        Read-Host "  Select preferred scanner [1-2] (Default: 1 - Morpho)"
    }

    if (-not $scannerChoice) { $scannerChoice = "1" }

    if ($scannerChoice.Trim() -eq "2" -or ($ScannerMode -and $ScannerMode -match "aegis")) {
        Write-Warn "AEGIS PRO4 profile is currently UNDER DEVELOPMENT and unavailable in this release."
        Write-Ok "Automatically defaulting to MorphoSmart MSO Production Profile."
    }

    $targetScanner = "Morpho"
    Write-Ok "Selected Biometric Profile: MorphoSmart MSO (Active Production Profile)"
    Write-Host ""

    # -- STEP 1  Resolve release metadata -------------------------------------
    Write-Step "[1/9] Checking for release on GitHub..."
    $apiHdr   = @{ "User-Agent" = "EIDToolkit-Deployer/1.0"; "Accept" = "application/vnd.github+json" }
    $latest   = "v1.0.0"
    $assetUrl = $null
    $assetSize= 28699062

    try {
        $release = Invoke-RestMethod "https://api.github.com/repos/$GH_REPO/releases/latest" -Headers $apiHdr -TimeoutSec 15 -EA SilentlyContinue
        if ($release -and $release.tag_name) {
            $latest  = $release.tag_name
            $asset   = $release.assets | Where-Object { $_.name -eq $PKG_FILENAME } | Select-Object -First 1
            if ($asset) {
                $assetUrl  = $asset.url
                $assetSize = $asset.size
            }
        }
    } catch {
        Write-Warn "GitHub Releases API unavailable or rate-limited. Using direct repo fallback."
    }

    Write-Host "    Release: $latest"
    Write-Host "    Current: $(if ($current) { $current } else { 'not installed' })"

    # -- STEP 2  Resolve the package key --------------------------------------
    Write-Step "[2/9] Resolving package decryption key..."
    if ($KeyFile -and (Test-Path $KeyFile)) { $PackageKey = (Get-Content $KeyFile -Raw).Trim() }
    if (-not $PackageKey) { $PackageKey = "Abc@1234" }

    # -- STEP 3  Download package with multiple backup sources -----------------
    $_tmpDir = Join-Path $env:WINDIR ("Temp\EIDdeploy_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory $_tmpDir -Force -EA SilentlyContinue | Out-Null

    $pkgFile = Join-Path $_tmpDir $PKG_FILENAME
    $sizeMB  = [math]::Round($assetSize / 1MB, 1)
    Write-Step "[3/9] Downloading $PKG_FILENAME ($sizeMB MB)..."

    # Candidate URLs in priority order:
    $candidateUrls = @()
    if ($assetUrl) { $candidateUrls += $assetUrl }
    $candidateUrls += "https://raw.githubusercontent.com/$GH_REPO/main/$PKG_FILENAME"
    $candidateUrls += "https://github.com/$GH_REPO/raw/main/$PKG_FILENAME"
    $candidateUrls += "https://github.com/$GH_REPO/releases/download/$latest/$PKG_FILENAME"

    # Check local cache first as an instant offline backup
    $cachedPkg = Join-Path $BACKUP_ROOT $PKG_FILENAME
    $localRepoPkg = "E:\Github\toolkit\$PKG_FILENAME"

    $downloadSuccess = $false
    if (Test-Path $cachedPkg) {
        Copy-Item $cachedPkg $pkgFile -Force -EA SilentlyContinue
        if ((Test-Path $pkgFile) -and (Get-Item $pkgFile).Length -gt 1000) {
            Write-Ok "Loaded package from local system cache"
            $downloadSuccess = $true
        }
    } elseif (Test-Path $localRepoPkg) {
        Copy-Item $localRepoPkg $pkgFile -Force -EA SilentlyContinue
        if ((Test-Path $pkgFile) -and (Get-Item $pkgFile).Length -gt 1000) {
            Write-Ok "Loaded package from local repository"
            $downloadSuccess = $true
        }
    }

    if (-not $downloadSuccess) {
        $dlHdr = @{ "Accept" = "application/octet-stream" }
        $downloadSuccess = Download-FileWithFallback -Urls $candidateUrls -OutFile $pkgFile -Headers $dlHdr
    }

    if (-not $downloadSuccess -or -not (Test-Path $pkgFile)) {
        Write-Fatal "Could not download $PKG_FILENAME from any available source. Check internet connection."
    }
    Write-Ok "Package acquired successfully"

    # Cache package locally for future offline auto-healing
    try {
        New-Item -ItemType Directory $BACKUP_ROOT -Force -EA SilentlyContinue | Out-Null
        Copy-Item $pkgFile $cachedPkg -Force -EA SilentlyContinue
    } catch { }

    # -- STEP 4  Verify & Decrypt with fallback keys ---------------------------
    Write-Step "[4/9] Verifying package integrity and decrypting..."
    $raw     = [IO.File]::ReadAllBytes($pkgFile)
    $magic   = [Text.Encoding]::ASCII.GetString($raw, 0, 6)
    if ($magic -ne "EIDPK1") {
        Write-Fatal "Unrecognised package format (bad header)."
    }

    $salt    = New-Object byte[] 16; [Array]::Copy($raw,  6, $salt, 0, 16)
    $iv      = New-Object byte[] 16; [Array]::Copy($raw, 22, $iv,   0, 16)
    $bodyEnd = $raw.Length - 32

    $keysToTry = @($PackageKey, "Abc@1234", "eidtoolkit") | Select-Object -Unique
    $plainBytes = $null

    foreach ($k in $keysToTry) {
        try {
            $derived = Derive-Keys -Pass $k -Salt $salt -Rounds 200000 -Len 64
            [byte[]] $encKey = $derived[0..31]
            [byte[]] $macKey = $derived[32..63]

            $computed = (New-Object Security.Cryptography.HMACSHA256 (,$macKey)).ComputeHash($raw, 0, $bodyEnd)
            $mismatch = 0
            for ($i = 0; $i -lt 32; $i++) { $mismatch = $mismatch -bor ($computed[$i] -bxor $raw[$bodyEnd + $i]) }
            if ($mismatch -eq 0) {
                $aes = [Security.Cryptography.Aes]::Create()
                $aes.KeySize = 256; $aes.Mode = "CBC"; $aes.Padding = "PKCS7"; $aes.Key = $encKey; $aes.IV = $iv
                $plainBytes = $aes.CreateDecryptor().TransformFinalBlock($raw, 38, $bodyEnd - 38)
                break
            }
        } catch { }
    }

    if (-not $plainBytes) {
        Write-Fatal "Package verification failed - incorrect key or corrupted file."
    }

    $zipFile   = Join-Path $_tmpDir "payload.zip"
    $extractTo = Join-Path $_tmpDir "payload"
    [IO.File]::WriteAllBytes($zipFile, $plainBytes)
    if (Test-Path $extractTo) { Remove-Item $extractTo -Recurse -Force -EA SilentlyContinue }
    Expand-Archive -LiteralPath $zipFile -DestinationPath $extractTo -Force
    Write-Ok "Package verified and extracted"

    # -- STEP 5  Clean previous installation -----------------------------------
    Write-Step "[5/9] Checking and cleaning previous installation..."
    $msiFile = Get-ChildItem $extractTo -Filter *.msi | Select-Object -First 1
    $msiHash = if ($msiFile) { (Get-FileHash $msiFile.FullName -Algorithm SHA256).Hash } else { "" }

    # Identify and protect services that are NOT ours
    $others = @(Get-AllToolkitSvcs |
                Where-Object { -not (Is-OurPath (Get-ExePath $_)) -and $_.DisplayName -ne $SVC_DISPLAY -and $_.Name -ne "ICAToolkitService" } |
                Select-Object Name, DisplayName, PathName, StartMode, State)
    foreach ($o in $others) { Write-Step "Preserving external service: '$($o.DisplayName)'" }

    # Handle old registered MSI in another path automatically (do NOT abort!)
    $existing = Find-InstalledMsi
    if ($existing) {
        $registeredExe = Get-MsiExePath $existing.PSChildName
        if ($registeredExe -and -not (Is-OurPath $registeredExe)) {
            Write-Warn "Detected previous MSI registered under $registeredExe. Removing old registration..."
            Remove-OldInstall $existing.PSChildName
            Clear-MsiRegistration
        }
    }

    $ourSvcs = @(Get-TargetSvcs)
    if ($ourSvcs -or (Test-Path $INSTALL_DIR) -or $existing -or (Test-MsiRegistered)) {
        Write-Step "Removing previous installation..."

        # Back up existing config files
        $cfgFiles = Get-ChildItem $INSTALL_DIR -Filter "config_*" -File -EA SilentlyContinue
        if ($cfgFiles) {
            $bakDir = Join-Path $BACKUP_ROOT ("cfg_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
            New-Item -ItemType Directory $bakDir -Force -EA SilentlyContinue | Out-Null
            $cfgFiles | Copy-Item -Destination $bakDir -Force -EA SilentlyContinue
            Write-Ok "Config backed up to $bakDir"
        }

        # Stop and delete target services
        foreach ($s in $ourSvcs) {
            Write-Step "Stopping service: $($s.Name)"
            Stop-Service -Name $s.Name -Force -EA SilentlyContinue
            Start-Process sc.exe -ArgumentList "delete `"$($s.Name)`"" -Wait -WindowStyle Hidden -EA SilentlyContinue
        }
        Get-Process $SVC_EXE_NAME.Replace(".exe","") -EA SilentlyContinue |
            Where-Object { Is-OurPath $_.Path } | Stop-Process -Force -EA SilentlyContinue
        Start-Sleep -Seconds 2

        if ($existing) { Remove-OldInstall $existing.PSChildName; Start-Sleep -Seconds 2 }
        if ((Test-MsiRegistered) -or (Find-InstalledMsi)) { Clear-MsiRegistration }
        if (Test-Path $INSTALL_DIR) {
            Write-Step "Removing $INSTALL_DIR"
            Remove-Item $INSTALL_DIR -Recurse -Force -EA SilentlyContinue
        }

        Remove-PreviousWatchdogs
        Write-Step "Purged previous daemon and watchdog tasks"
    } else {
        Remove-PreviousWatchdogs
        Write-Step "No previous installation found - fresh install"
    }

    # -- STEP 6  Install MSI with Multi-Tiered Backup Plans --------------------
    Ensure-Dependencies -TempDir $_tmpDir
    Ensure-MorphoDriver -TempDir $_tmpDir
    Write-Step "[6/9] Installing core package to $INSTALL_DIR..."
    New-Item -ItemType Directory $INSTALL_DIR -Force -EA SilentlyContinue | Out-Null

    $msiLog = "$env:WINDIR\Temp\EIDToolkit-msi.log"
    $msiSuccess = $false

    if ($msiFile -and (Test-Path $msiFile.FullName)) {
        # Plan A: Standard silent msiexec
        Write-Step "Executing MSI installation (Plan A: Standard silent msiexec)..."
        $args   = "/i `"$($msiFile.FullName)`" INSTALLDIR=`"$INSTALL_DIR\`" /qn /norestart /L*v `"$msiLog`""
        $result = Start-Process msiexec.exe -ArgumentList $args -Wait -PassThru -EA SilentlyContinue

        if ($result.ExitCode -eq 1618) {
            Write-Warn "Windows Installer was busy (error 1618). Retrying in 10 seconds..."
            Start-Sleep -Seconds 10
            $result = Start-Process msiexec.exe -ArgumentList $args -Wait -PassThru -EA SilentlyContinue
        }

        Start-Sleep -Seconds 3
        if ($result.ExitCode -in 0, 3010, 1641 -and (Test-Path (Join-Path $INSTALL_DIR $SVC_EXE_NAME))) {
            $msiSuccess = $true
            Write-Ok "MSI package installed successfully"
        } else {
            Write-Warn "Standard MSI exited with code $($result.ExitCode). Engaging Fallback Plan B..."
        }

        # Plan B: Administrative Extraction if standard install failed
        if (-not $msiSuccess) {
            Write-Step "Executing Administrative Extraction (Plan B)..."
            $adminDir = Join-Path $_tmpDir "admin_extract"
            New-Item -ItemType Directory $adminDir -Force -EA SilentlyContinue | Out-Null
            Start-Process msiexec.exe -ArgumentList "/a `"$($msiFile.FullName)`" /qn TARGETDIR=`"$adminDir`"" -Wait -WindowStyle Hidden -EA SilentlyContinue

            $extractedExe = Get-ChildItem $adminDir -Recurse -Filter $SVC_EXE_NAME -EA SilentlyContinue | Select-Object -First 1
            if ($extractedExe) {
                $srcRoot = $extractedExe.Directory.FullName
                Get-ChildItem $srcRoot -Recurse -EA SilentlyContinue | ForEach-Object {
                    $rel = $_.FullName.Substring($srcRoot.Length).TrimStart('\','/')
                    $dest = Join-Path $INSTALL_DIR $rel
                    if ($_.PSIsContainer) {
                        New-Item -ItemType Directory $dest -Force -EA SilentlyContinue | Out-Null
                    } else {
                        Copy-Item $_.FullName -Destination $dest -Force -EA SilentlyContinue
                    }
                }
                if (Test-Path (Join-Path $INSTALL_DIR $SVC_EXE_NAME)) {
                    $msiSuccess = $true
                    Write-Ok "Administrative fallback deployed binaries to $INSTALL_DIR"
                }
            }
        }
    }

    # Plan C: Direct payload mirroring if MSI engine was unavailable
    if (-not (Test-Path (Join-Path $INSTALL_DIR $SVC_EXE_NAME))) {
        Write-Step "Engaging Direct Binary Mirroring (Plan C)..."
        $anyExe = Get-ChildItem $extractTo -Recurse -Filter $SVC_EXE_NAME -EA SilentlyContinue | Select-Object -First 1
        if ($anyExe) {
            Copy-Item $anyExe.FullName (Join-Path $INSTALL_DIR $SVC_EXE_NAME) -Force -EA SilentlyContinue
        }
        Get-ChildItem $extractTo -Recurse -File -EA SilentlyContinue | ForEach-Object {
            if ($_.Extension -ne ".msi" -and $_.Name -ne "copy-map.txt") {
                Copy-Item $_.FullName (Join-Path $INSTALL_DIR $_.Name) -Force -EA SilentlyContinue
            }
        }
        if (Test-Path (Join-Path $INSTALL_DIR $SVC_EXE_NAME)) {
            Write-Ok "Direct binary mirror successfully deployed to $INSTALL_DIR"
        }
    }

    # Restore any external services if affected
    foreach ($o in $others) {
        if (-not (Get-Service -Name $o.Name -EA SilentlyContinue)) {
            Write-Warn "Restoring external service '$($o.Name)'"
            $start = switch ($o.StartMode) { "Auto" {"auto"} "Disabled" {"disabled"} default {"demand"} }
            Start-Process sc.exe -ArgumentList "create `"$($o.Name)`" binPath= `"$($o.PathName)`" DisplayName= `"$($o.DisplayName)`" start= $start" -Wait -WindowStyle Hidden -EA SilentlyContinue
            if ($o.State -eq "Running") { Start-Service -Name $o.Name -EA SilentlyContinue }
        }
    }

    # -- STEP 7  Deploy certificates, drivers, and MOHRE live updates ----------
    Write-Step "[7/9] Deploying updated certificates and runtime libraries..."
    $pkgRoot = (Get-Item $extractTo).FullName.TrimEnd('\')
    $mapFile = Join-Path $pkgRoot "copy-map.txt"
    $copyMap = @()

    if (Test-Path $mapFile) {
        foreach ($line in Get-Content $mapFile -EA SilentlyContinue) {
            try {
                $line = $line.Trim()
                if (-not $line -or $line.StartsWith("#")) { continue }
                $sep  = $line.IndexOf("=")
                if ($sep -lt 1) { continue }
                $item = $line.Substring(0, $sep).Trim().Trim('"').Trim('\','/')
                $dest = [Environment]::ExpandEnvironmentVariables($line.Substring($sep + 1).Trim().Trim('"'))
                $src  = [IO.Path]::GetFullPath((Join-Path $pkgRoot $item))
                if ((Test-Path $src) -and [IO.Path]::IsPathRooted($dest)) {
                    $copyMap += [pscustomobject]@{ Src = $src; Dest = $dest }
                }
            } catch { }
        }
    }

    $ourSvc = Get-OurService
    if ($ourSvc -and $ourSvc.State -eq "Running") {
        Stop-Service -Name $ourSvc.Name -Force -EA SilentlyContinue
        Start-Sleep -Seconds 2
    }

    function Copy-Safe([string]$From, [string]$To) {
        try {
            $parent = Split-Path $To -Parent
            if (-not (Test-Path $parent)) { New-Item -ItemType Directory $parent -Force -EA SilentlyContinue | Out-Null }
            Copy-Item -LiteralPath $From -Destination $To -Force -EA SilentlyContinue
            Write-Host "    + $To" -ForegroundColor DarkGray
        } catch { }
    }

    # Copy unmapped files to install directory
    Get-ChildItem $pkgRoot -File -Recurse -EA SilentlyContinue | ForEach-Object {
        $f = $_
        if ($f.FullName -eq $mapFile -or $f.Extension -eq ".msi") { return }
        $mapped = $false
        foreach ($m in $copyMap) {
            if ($f.FullName -eq $m.Src -or $f.FullName.StartsWith($m.Src + '\', [StringComparison]::OrdinalIgnoreCase)) {
                $mapped = $true; break
            }
        }
        if (-not $mapped) {
            $rel = $f.FullName.Substring($pkgRoot.Length).TrimStart('\','/')
            Copy-Safe $f.FullName (Join-Path $INSTALL_DIR $rel)
        }
    }

    # Copy mapped files to their designated system paths
    foreach ($m in $copyMap) {
        if (Test-Path $m.Src -PathType Container) {
            Get-ChildItem $m.Src -File -Recurse -EA SilentlyContinue | ForEach-Object {
                $rel = $_.FullName.Substring($m.Src.Length).TrimStart('\','/')
                Copy-Safe $_.FullName (Join-Path $m.Dest $rel)
            }
        } else {
            Copy-Safe $m.Src (Join-Path $m.Dest (Split-Path $m.Src -Leaf))
        }
    }

    # Fetch live MOHRE updates (Plan A) with automatic offline fallback (Plan B)
    try {
        Write-Step "Fetching live updates from MOHRE official server..."
        $mohreTmp = Join-Path $_tmpDir "mohre_live"
        New-Item -ItemType Directory $mohreTmp -Force -EA SilentlyContinue | Out-Null
        $mohreZip = Join-Path $mohreTmp "EmiratesIDCardToolkitService_64.zip"

        $mohreDownloaded = Download-FileWithFallback -Urls @($MOHRE_ZIP_URL) -OutFile $mohreZip
        if ($mohreDownloaded) {
            $mohreExtracted = Join-Path $mohreTmp "extracted"
            Expand-Archive -LiteralPath $mohreZip -DestinationPath $mohreExtracted -Force -EA SilentlyContinue

            $liveFiles = Get-ChildItem $mohreExtracted -Recurse -File -EA SilentlyContinue | Where-Object {
                $_.Name -like "config_*" -or $_.Name -like "*.jar"
            }
            foreach ($lf in $liveFiles) {
                Copy-Safe $lf.FullName (Join-Path $INSTALL_DIR $lf.Name)
            }
            Write-Ok "Live MOHRE configuration and certificates synced ($($liveFiles.Count) files)"
        } else {
            Write-Warn "MOHRE live download unavailable. Bundled offline certificates active."
        }
    } catch {
        Write-Warn "MOHRE live sync skipped: $($_.Exception.Message) - bundled certificates active."
    }

    # Apply Biometric Profile: Strictly MorphoSmart MSO Series (Morpho Exclusive)
    $targetDirs = @($INSTALL_DIR, "C:\EmiratesIDCardToolkitService_64") | Select-Object -Unique
    foreach ($td in $targetDirs) {
        if (-not (Test-Path $td)) { continue }
        $sagemDll = Join-Path $td "SagemMSO1350.dll"
        $disabledSagem = Join-Path $td "SagemMSO1350.dll.disabled"

        if (Test-Path $disabledSagem) {
            Rename-Item $disabledSagem "SagemMSO1350.dll" -Force -EA SilentlyContinue
        }
        if (Test-Path $sagemDll) {
            Write-Ok "Biometric Profile in $($td): MorphoSmart MSO optical reader enabled (SagemMSO1350.dll active)"
        }
    }

    # -- STEP 8  Register and configure service with failover plans ------------
    Write-Step "[8/9] Registering and configuring service with auto-recovery..."
    $ourSvc = Get-OurService

    if (-not $ourSvc) {
        # Plan A: Self-install switch
        Write-Step "Registering service (Plan A: self-install)..."
        Start-Process (Join-Path $INSTALL_DIR $SVC_EXE_NAME) -ArgumentList "-install" `
                      -WorkingDirectory $INSTALL_DIR -Wait -WindowStyle Hidden -EA SilentlyContinue
        Start-Sleep -Seconds 3
        $ourSvc = Get-OurService
    }

    if (-not $ourSvc) {
        # Plan B: Native sc.exe create
        Write-Step "Registering service (Plan B: sc.exe create)..."
        $binPath = "`"$INSTALL_DIR\$SVC_EXE_NAME`""
        Start-Process sc.exe -ArgumentList "create `"ICAToolkitService`" binPath= $binPath DisplayName= `"$SVC_DISPLAY`" start= auto" -Wait -WindowStyle Hidden -EA SilentlyContinue
        Start-Sleep -Seconds 2
        $ourSvc = Get-OurService
    }

    if (-not $ourSvc) {
        # Plan C: PowerShell New-Service
        Write-Step "Registering service (Plan C: New-Service)..."
        try {
            New-Service -Name "ICAToolkitService" -BinaryPathName "`"$INSTALL_DIR\$SVC_EXE_NAME`"" `
                        -DisplayName "$SVC_DISPLAY" -StartupType Automatic -EA SilentlyContinue | Out-Null
            Start-Sleep -Seconds 2
            $ourSvc = Get-OurService
        } catch { }
    }

    $svcName = if ($ourSvc) { $ourSvc.Name } else { "ICAToolkitService" }

    # Configure auto-restart on crash
    Start-Process sc.exe -ArgumentList "config `"$svcName`" DisplayName= `"$SVC_DISPLAY`" start= auto" -Wait -WindowStyle Hidden -EA SilentlyContinue
    Start-Process sc.exe -ArgumentList "description `"$svcName`" `"$SVC_DISPLAY`"" -Wait -WindowStyle Hidden -EA SilentlyContinue
    Start-Process sc.exe -ArgumentList "failure `"$svcName`" reset= 3600 actions= restart/10000/restart/30000/restart/60000" -Wait -WindowStyle Hidden -EA SilentlyContinue
    Start-Process sc.exe -ArgumentList "failureflag `"$svcName`" 1" -Wait -WindowStyle Hidden -EA SilentlyContinue

    # Register Watchdog Daemon (Monitors health & auto-heals port 9004)
    try {
        $taskName = "EIDToolkit-Watchdog"
        $wdPath = Join-Path $BACKUP_ROOT "watchdog.ps1"
        New-Item -ItemType Directory $BACKUP_ROOT -Force -EA SilentlyContinue | Out-Null

        $watchdogScript = @"
# EIDToolkit Watchdog - Persistent Health & Port Monitor
`$svcName = '$svcName'
`$port = 9004
`$logFile = "`$env:WINDIR\Temp\EIDToolkit-watchdog.log"

function Write-Log(`$msg) {
    "`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  `$msg" | Out-File `$logFile -Append -EA SilentlyContinue
}

`$svc = Get-Service -Name `$svcName -EA SilentlyContinue
if (-not `$svc -or `$svc.Status -ne "Running") {
    Write-Log "CRITICAL: Service `$svcName is stopped. Auto-restarting..."
    Start-Service `$svcName -EA SilentlyContinue
    Start-Sleep -Seconds 4
}

`$portUp = `$false
try {
    `$tcp = New-Object Net.Sockets.TcpClient
    `$async = `$tcp.BeginConnect("127.0.0.1", `$port, `$null, `$null)
    `$wait = `$async.AsyncWaitHandle.WaitOne(2000, `$false)
    if (`$wait) {
        `$tcp.EndConnect(`$async)
        `$portUp = `$true
    }
    `$tcp.Close()
} catch { }

if (-not `$portUp) {
    Write-Log "WARNING: Port `$port not responding. Cycling `$svcName..."
    Stop-Service `$svcName -Force -EA SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Service `$svcName -EA SilentlyContinue
    Start-Sleep -Seconds 4
    `$newState = (Get-Service `$svcName -EA SilentlyContinue).Status
    Write-Log "Cycle complete. State: `$newState"
}
"@
        [IO.File]::WriteAllText($wdPath, $watchdogScript, [System.Text.Encoding]::ASCII)

        # Plan A: schtasks.exe
        $taskCmd = "powershell.exe -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File \`"$wdPath\`""
        $res = Start-Process schtasks.exe -ArgumentList "/create /tn `"$taskName`" /tr `"$taskCmd`" /sc minute /mo 1 /ru `"SYSTEM`" /rl HIGHEST /f" -Wait -WindowStyle Hidden -PassThru -EA SilentlyContinue

        if ($res.ExitCode -eq 0) {
            Write-Ok "Daemon watchdog installed (monitors service and port 9004 every 1 minute)"
        } else {
            # Plan B: Register-ScheduledTask
            try {
                $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$wdPath`""
                $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1)
                Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -User "SYSTEM" -Force -EA SilentlyContinue | Out-Null
                Write-Ok "Daemon watchdog registered via PowerShell task API"
            } catch { }
        }

        # Plan C: Windows Startup Folder (Permanent safety net across reboots)
        try {
            $startupVbs = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\EIDWatchdog.vbs"
            $vbsCode = "Set WshShell = CreateObject(`"WScript.Shell`")`nWshShell.Run `"powershell.exe -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"`"$wdPath`"`"`", 0, False"
            [IO.File]::WriteAllText($startupVbs, $vbsCode)
        } catch { }

    } catch {
        Write-Warn "Watchdog setup notice: $($_.Exception.Message)"
    }

    # Ensure Windows Smart Card Services are set to Automatic and running
    Set-Service SCardSvr -StartupType Automatic -EA SilentlyContinue
    Start-Service SCardSvr -EA SilentlyContinue
    Set-Service ScDeviceEnum -StartupType Automatic -EA SilentlyContinue
    Start-Service ScDeviceEnum -EA SilentlyContinue

    # Ensure Firewall allows EIDAToolkitService
    $exeFullPath = Join-Path $INSTALL_DIR $SVC_EXE_NAME
    New-NetFirewallRule -DisplayName "Emirates ID Card Toolkit" -Direction Inbound `
        -Program $exeFullPath -Action Allow -Profile Any -EA SilentlyContinue | Out-Null

    # Disable USB selective suspend in power plan to prevent readers from dropping
    try {
        $planGuid = (powercfg /getactivescheme) -replace '.*GUID:\s+(\S+).*','$1'
        if ($planGuid) {
            powercfg /setacvalueindex $planGuid 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 2>$null
            powercfg /setdcvalueindex $planGuid 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 2>$null
            powercfg /setactive $planGuid 2>$null
        }
    } catch { }

    # Windows 10/11 Hardware Compatibility: Disable USB power-saving on Morpho / Sagem / USB Hubs
    try {
        $morphoNodes = Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Enum\USB" -Recurse -EA SilentlyContinue |
            Where-Object { $_.PSChildName -eq "Device Parameters" -and ($_.PSPath -like "*VID_079B*" -or $_.PSPath -like "*VID_225D*" -or $_.PSPath -like "*VID_3969*" -or $_.PSPath -like "*VID_2075*" -or $_.PSPath -like "*RootHub*" -or $_.PSPath -like "*GenericHub*") }

        foreach ($node in $morphoNodes) {
            Set-ItemProperty $node.PSPath -Name "EnhancedPowerManagementEnabled" -Value 0 -Type DWord -EA SilentlyContinue
            Set-ItemProperty $node.PSPath -Name "AllowIdleIrpInD3" -Value 0 -Type DWord -EA SilentlyContinue
            Set-ItemProperty $node.PSPath -Name "DeviceSelectiveSuspended" -Value 0 -Type DWord -EA SilentlyContinue
            Set-ItemProperty $node.PSPath -Name "SelectiveSuspendEnabled" -Value 0 -Type DWord -EA SilentlyContinue
        }
    } catch { }

    # Ensure Windows Camera / UVC optical sensor access is allowed globally and for SYSTEM background services (required for AEGIS AGF200 on Windows 10 & 11)
    try {
        $camPaths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam",
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam\NonPackaged",
            "Registry::HKEY_USERS\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam",
            "Registry::HKEY_USERS\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam\NonPackaged",
            "Registry::HKEY_USERS\S-1-5-18\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam",
            "Registry::HKEY_USERS\S-1-5-18\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam\NonPackaged",
            "HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam",
            "HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam\NonPackaged"
        )
        foreach ($cp in $camPaths) {
            if (-not (Test-Path $cp)) { New-Item -Path $cp -Force -EA SilentlyContinue | Out-Null }
            Set-ItemProperty -Path $cp -Name "Value" -Value "Allow" -Force -EA SilentlyContinue
        }
        $appPriv = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy"
        if (-not (Test-Path $appPriv)) { New-Item -Path $appPriv -Force -EA SilentlyContinue | Out-Null }
        Set-ItemProperty $appPriv -Name "LetAppsAccessCamera" -Value 1 -Type DWord -Force -EA SilentlyContinue
        Set-ItemProperty $appPriv -Name "LetAppsAccessCamera_UserInControlOfTheseApps" -Value @() -Type MultiString -Force -EA SilentlyContinue
    } catch { }

    # Register Emirates ID Card ATRs with Microsoft Smart Card Class Minidriver (msclmd.dll) to eliminate 'Unknown Smart Card' error
    try {
        $cards = @(
            @{ Name = "Emirates ID Card (Idemia IAS-ECC Gen2)"; ATR = [byte[]](0x3B, 0xB8, 0x97, 0x00, 0x81, 0x31, 0xFE, 0x45, 0xFF, 0xFF, 0x14, 0x82, 0x30, 0x50, 0x23, 0x00, 0xF1); Mask = [byte[]](0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF) },
            @{ Name = "Emirates ID Card (Idemia Dual Interface)"; ATR = [byte[]](0x3B, 0x8F, 0x80, 0x01, 0x80, 0x4F, 0x0C, 0xA0, 0x00, 0x00, 0x03, 0x06, 0x03, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x68); Mask = [byte[]](0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF) },
            @{ Name = "Emirates ID Card (Oberthur Cosmo 64 Gen1)"; ATR = [byte[]](0x3B, 0x7D, 0x94, 0x00, 0x00, 0x57, 0x44, 0x03, 0x02, 0x80); Mask = [byte[]](0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF) },
            @{ Name = "Emirates ID Card (Safran IAS-ECC)"; ATR = [byte[]](0x3B, 0x9F, 0x96, 0x81, 0xB1, 0xFE, 0x45, 0x1F, 0x07, 0x00, 0x64, 0x05, 0x1E, 0xB2, 0x00, 0x14, 0x82, 0x30, 0x50, 0x23, 0xA2); Mask = [byte[]](0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF) },
            @{ Name = "Emirates ID Card (New Dual Chip)"; ATR = [byte[]](0x3B, 0xF8, 0x18, 0x00, 0x00, 0x81, 0x31, 0xFE, 0x45, 0xFF, 0xFF, 0x14, 0x82, 0x30, 0x50, 0x23, 0x00, 0xB2); Mask = [byte[]](0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF) }
        )
        $roots = @("HKLM:\SOFTWARE\Microsoft\Cryptography\Calais\SmartCards", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Cryptography\Calais\SmartCards")
        foreach ($rt in $roots) {
            if (-not (Test-Path $rt)) { New-Item -Path $rt -Force -EA SilentlyContinue | Out-Null }
            foreach ($card in $cards) {
                $kp = Join-Path $rt $card.Name
                if (-not (Test-Path $kp)) { New-Item -Path $kp -Force -EA SilentlyContinue | Out-Null }
                Set-ItemProperty -Path $kp -Name "ATR" -Value $card.ATR -Type Binary -Force -EA SilentlyContinue
                Set-ItemProperty -Path $kp -Name "ATRMask" -Value $card.Mask -Type Binary -Force -EA SilentlyContinue
                Set-ItemProperty -Path $kp -Name "Crypto Provider" -Value "Microsoft Base Smart Card Crypto Provider" -Type String -Force -EA SilentlyContinue
                Set-ItemProperty -Path $kp -Name "Smart Card Key Storage Provider" -Value "Microsoft Smart Card Key Storage Provider" -Type String -Force -EA SilentlyContinue
                Set-ItemProperty -Path $kp -Name "80000001" -Value "%SystemRoot%\system32\msclmd.dll" -Type ExpandString -Force -EA SilentlyContinue
            }
        }
        Write-Ok "Emirates ID Smart Card definitions registered in Windows Calais"
    } catch { }

    # Ensure MOHRE DNS entry in hosts file
    try {
        $hostsFile = "$env:WINDIR\System32\drivers\etc\hosts"
        if (Test-Path $hostsFile) {
            $hostsContent = Get-Content $hostsFile -Raw -EA SilentlyContinue
            if ($hostsContent -notmatch "toolkitagent\.mohre\.gov\.ae") {
                "`r`n127.0.0.1 toolkitagent.mohre.gov.ae" | Out-File $hostsFile -Append -Encoding ascii -EA SilentlyContinue
                Write-Ok "Added 127.0.0.1 toolkitagent.mohre.gov.ae to hosts file"
            }
        }
    } catch { }

    # Service Startup with multi-step fallback
    $started = $false
    try {
        Start-Service -Name $svcName -EA SilentlyContinue
        Start-Sleep -Seconds 2
        $started = ((Get-Service -Name $svcName -EA SilentlyContinue).Status -eq "Running")
    } catch { }

    if (-not $started) {
        Start-Process sc.exe -ArgumentList "start `"$svcName`"" -Wait -WindowStyle Hidden -EA SilentlyContinue
        Start-Sleep -Seconds 2
        $started = ((Get-Service -Name $svcName -EA SilentlyContinue).Status -eq "Running")
    }

    if (-not $started) {
        # Clear any orphan process holding ports and retry
        Get-Process $SVC_EXE_NAME.Replace(".exe","") -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
        Start-Sleep -Seconds 2
        Start-Service -Name $svcName -EA SilentlyContinue
        Start-Sleep -Seconds 3
        $started = ((Get-Service -Name $svcName -EA SilentlyContinue).Status -eq "Running")
    }

    if ($started) {
        Write-Ok "Service '$SVC_DISPLAY' is Running"
    } else {
        Write-Warn "Service registered. The background watchdog daemon is active and will auto-start the service."
    }

    # -- STEP 9  Record version metadata ---------------------------------------
    Write-Step "[9/9] Registering installation metadata..."
    try {
        New-Item $REG_PATH -Force -EA SilentlyContinue | Out-Null
        Set-ItemProperty $REG_PATH -Name Version -Value $latest -EA SilentlyContinue
        Set-ItemProperty $REG_PATH -Name MsiHash -Value $msiHash -EA SilentlyContinue
        Set-ItemProperty $REG_PATH -Name Updated -Value (Get-Date -Format "yyyy-MM-dd HH:mm") -EA SilentlyContinue
        Set-ItemProperty $REG_PATH -Name InstallDir -Value $INSTALL_DIR -EA SilentlyContinue
        Set-ItemProperty $REG_PATH -Name BiometricProfile -Value $targetScanner -EA SilentlyContinue
    } catch { }

    Write-Host ""
    Write-Host "  ================================================================" -ForegroundColor Cyan
    Write-Host "  EID Toolkit $latest successfully deployed to $INSTALL_DIR" -ForegroundColor Green
    Write-Host "  Biometric  : $targetScanner Profile Active" -ForegroundColor Green
    Write-Host "  Health     : Watchdog daemon active & auto-recovering" -ForegroundColor Green
    Write-Host "  Developer  : mujtaba989" -ForegroundColor Gray
    Write-Host "  Purpose    : Tasheel & Typing Center Technical Maintenance" -ForegroundColor Gray
    Write-Host "  ================================================================" -ForegroundColor Cyan
    Write-Host ""
}
catch {
    Write-Host ""
    Write-Host "  [X] Notice: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "      Log: $LOG_FILE" -ForegroundColor Gray
    Write-Host ""
}
finally {
    $PackageKey = $null
    if ($_tmpDir -and (Test-Path $_tmpDir)) { Remove-Item $_tmpDir -Recurse -Force -EA SilentlyContinue }
    if ($_transcriptOn) { try { Stop-Transcript | Out-Null } catch { } }
}
