<#
.SYNOPSIS
    Emirates ID Card Toolkit - Silent Deployer

.DESCRIPTION
    Pulls the latest toolkit release from GitHub, verifies the package
    integrity, and performs a clean install of the Emirates ID Card
    Toolkit Service on Windows 10 / 11.

.PARAMETER PackageKey
    Decryption key for the release package. If omitted the script uses
    the built-in default.

.PARAMETER KeyFile
    Path to a text file containing the decryption key (alternative to
    typing it interactively).

.EXAMPLE
    # One-liner (run as Administrator):
    irm https://raw.githubusercontent.com/mujtaba989/toolkit/main/install-eid.ps1 | iex

.NOTES
    Log  : C:\Windows\Temp\EIDToolkit-install.log
    Store: HKLM:\SOFTWARE\Toolkit\EID
#>
param(
    [string] $PackageKey  = "Abc@1234",
    [string] $KeyFile,
    [string] $ScannerMode,  # "Morpho", "AEGIS", or "Auto"
    [string] $Action        # "Install", "Reinstall", "Uninstall"
)

Set-StrictMode -Off
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Security

# -----------------------------------------------------------------------------
#  CONSTANTS
# -----------------------------------------------------------------------------
$GH_REPO      = "mujtaba989/toolkit"
$PKG_FILENAME = "EID_MOHRE.bin"
$SVC_DISPLAY  = "Emirates ID Card Toolkit Service"
$INSTALL_ROOT = if (${env:ProgramFiles(x86)}) { ${env:ProgramFiles(x86)} } else { $env:ProgramFiles }
$INSTALL_DIR  = Join-Path $INSTALL_ROOT $SVC_DISPLAY
$REG_PATH     = "HKLM:\SOFTWARE\Toolkit\EID"
$LOG_FILE     = "$env:WINDIR\Temp\EIDToolkit-install.log"
$MSI_PRODUCT  = "{E73E6470-DC25-4CCE-B26C-0730283B0D32}"
$MSI_UPGRADE  = "{511AC963-BA5A-4875-9058-E5E27600023E}"
$SVC_EXE_NAME = "EIDAToolkitService.exe"
$BACKUP_ROOT  = "$env:ProgramData\EIDToolkit"
$MOHRE_ZIP_URL = "https://eservices.mohre.gov.ae/tasheelweb/scripts/eida/EmiratesIDCardToolkitService_64.zip"

$_tmpDir = $null   # cleaned up in finally

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
function Write-Warn  { param($msg) Write-Warning $msg }
function Write-Fatal { param($msg) throw $msg }

# -----------------------------------------------------------------------------
#  PBKDF2-SHA256  (native .NET 4.7.2+ with PS 5.1 fallback)
# -----------------------------------------------------------------------------
function Derive-Keys {
    param([string]$Pass, [byte[]]$Salt, [int]$Rounds, [int]$Len)

    # Try the modern overload first
    try {
        $h   = [Security.Cryptography.HashAlgorithmName]::SHA256
        $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes($Pass, $Salt, $Rounds, $h)
        return $kdf.GetBytes($Len)
    } catch { }

    # Manual PBKDF2-HMAC-SHA256 fallback (PS 5.1 / early Win10 builds)
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
#  MSI P/INVOKE  (avoids COM "Type mismatch" in PowerShell 5.1)
# -----------------------------------------------------------------------------
if (-not ("EidMsiHelper" -as [type])) {
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
        IntPtr db; if (MsiOpenDatabase(path, (IntPtr)1, out db) != 0) throw new Exception("MsiOpenDatabase failed");
        try {
            foreach (var q in queries) {
                IntPtr v; if (MsiDatabaseOpenView(db, q, out v) != 0) throw new Exception("MsiDatabaseOpenView failed");
                try { if (MsiViewExecute(v, IntPtr.Zero) != 0) throw new Exception("MsiViewExecute failed"); }
                finally { MsiViewClose(v); MsiCloseHandle(v); }
            }
            if (MsiDatabaseCommit(db) != 0) throw new Exception("MsiDatabaseCommit failed");
        } finally { MsiCloseHandle(db); }
    }

    public static string GetComponentPath(string prod, string comp) {
        uint len = 1024; var sb = new StringBuilder((int)len);
        MsiGetComponentPath(prod, comp, sb, ref len);
        return sb.ToString();
    }
}
"@
}

# -----------------------------------------------------------------------------
#  UTILITY FUNCTIONS
# -----------------------------------------------------------------------------

# GUID -> Windows Installer "squished" form
function Squish-Guid([string]$g) {
    $g = $g.Trim('{}').Replace('-','')
    $r = { param($s) -join ($s.ToCharArray()[($s.Length-1)..0]) }
    $o = (& $r $g.Substring(0,8)) + (& $r $g.Substring(8,4)) + (& $r $g.Substring(12,4))
    for ($i=16; $i -lt 32; $i+=2) { $o += "$($g[$i+1])$($g[$i])" }
    $o.ToUpper()
}

# Strip service arguments to get the bare exe path
function Get-ExePath($svc) {
    ($svc.PathName -replace '^"([^"]+)".*$','$1') -replace '\.exe\s+.*$','.exe'
}

# Is a path inside our install folder?
function Is-OurPath([string]$p) {
    $p -and $p.TrimEnd('\').StartsWith($INSTALL_DIR, [StringComparison]::OrdinalIgnoreCase)
}

# All EID-family services on this machine
function Get-AllToolkitSvcs {
    try   { Get-CimInstance Win32_Service -EA Stop | Where-Object { $_.PathName -like "*EIDAToolkitService*" -or $_.PathName -like "*ICAToolkit*" } }
    catch { Get-WmiObject  Win32_Service -EA SilentlyContinue | Where-Object { $_.PathName -like "*EIDAToolkitService*" -or $_.PathName -like "*ICAToolkit*" } }
}

# Only the service installed in OUR folder
function Get-OurService {
    Get-AllToolkitSvcs | Where-Object { Is-OurPath (Get-ExePath $_) } | Select-Object -First 1
}

# Services that match by display name or live in our folder
function Get-TargetSvcs {
    Get-AllToolkitSvcs | Where-Object {
        $_.DisplayName -eq $SVC_DISPLAY -or $_.Name -eq "ICAToolkitService" -or (Is-OurPath (Get-ExePath $_))
    }
}

# Is the toolkit already fully installed?
function Test-AlreadyInstalled {
    (Test-Path (Join-Path $INSTALL_DIR $SVC_EXE_NAME)) -and (Get-OurService)
}

# Registry lookup for installed MSI
function Find-InstalledMsi {
    $keys = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    Get-ItemProperty $keys -EA SilentlyContinue | Where-Object { $_.DisplayName -eq $SVC_DISPLAY } | Select-Object -First 1
}

# Has Windows Installer cached the product?
function Test-MsiRegistered {
    $sq = Squish-Guid $MSI_PRODUCT
    if (Test-Path "HKLM:\SOFTWARE\Classes\Installer\Products\$sq")  { return $true }
    if (Test-Path "HKCU:\Software\Microsoft\Installer\Products\$sq") { return $true }
    [bool](Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData" -EA SilentlyContinue |
           Where-Object { Test-Path (Join-Path $_.PSPath "Products\$sq") })
}

# Where did the MSI install the service exe?
function Get-MsiExePath([string]$prodCode) {
    try {
        $p = [EidMsiHelper]::GetComponentPath($prodCode, "{D34D7FD1-31B2-5F8D-9C4F-64A73D251BD8}")
        if ($p) { $p } else { $null }
    } catch { $null }
}

# Download with WebClient (handles S3 redirects better than IWR on PS 5.1)
function Download-File([string]$Url, [hashtable]$Headers, [string]$Out) {
    try {
        $wc = New-Object Net.WebClient
        foreach ($k in $Headers.Keys) { $wc.Headers[$k] = $Headers[$k] }
        $wc.DownloadFile($Url, $Out)
    } catch {
        Invoke-WebRequest -Uri $Url -Headers $Headers -OutFile $Out -UseBasicParsing -MaximumRedirection 10
    }
}

# Patch and run MSI uninstall (works around MOHRE's broken custom actions)
function Remove-OldInstall([string]$prodCode) {
    $cached = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products" -EA SilentlyContinue |
              ForEach-Object { Get-ItemProperty (Join-Path $_.PSPath "InstallProperties") -EA SilentlyContinue } |
              Where-Object { $_.DisplayName -eq $SVC_DISPLAY } | Select-Object -First 1 -ExpandProperty LocalPackage

    if ($cached -and (Test-Path $cached)) {
        New-Item -ItemType Directory $BACKUP_ROOT -Force | Out-Null
        Copy-Item $cached (Join-Path $BACKUP_ROOT ("msi_" + (Split-Path $cached -Leaf))) -Force
        (Get-Item $cached).IsReadOnly = $false
        $patches = @("ExecInstallService","ExecRemoveService","ExecDeleteFiles") | ForEach-Object {
            "UPDATE ``InstallExecuteSequence`` SET ``Condition`` = '0' WHERE ``Action`` = '$_'"
        }
        [EidMsiHelper]::PatchDatabase($cached, [string[]]$patches)
        Write-Step "Patched cached MSI so uninstall completes cleanly"
    } else {
        Write-Warn "Cached MSI not found - attempting standard uninstall"
    }

    $ulog = "$env:WINDIR\Temp\EIDToolkit-uninstall.log"
    $p = Start-Process msiexec.exe -ArgumentList "/x $prodCode /qn /norestart /L*v `"$ulog`"" -Wait -PassThru
    if ($p.ExitCode -notin 0, 3010, 1605, 1603) {
        Write-Warn "MSI uninstall returned code $($p.ExitCode). Proceeding with forced cleanup."
    }
    Clear-MsiRegistration
    Write-Ok "Previous installation cleaned up"
}

# Scrub every Windows Installer registration for the product
function Clear-MsiRegistration {
    $sq  = Squish-Guid $MSI_PRODUCT
    $usq = Squish-Guid $MSI_UPGRADE
    $bk  = Join-Path $BACKUP_ROOT ("reg_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
    New-Item -ItemType Directory $bk -Force | Out-Null

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
            $reg = (Convert-Path $k) -replace '^HKEY_LOCAL_MACHINE','HKLM' -replace '^HKEY_CURRENT_USER','HKCU'
            & reg.exe export "$reg" (Join-Path $bk "key$n.reg") /y | Out-Null
            Remove-Item $k -Recurse -Force; $n++
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
    Write-Ok "Cleared $n stale installer registration(s)  (backup: $bk)"
}

# Ensure all system prerequisites and Visual C++ runtimes are installed
function Ensure-Dependencies([string]$TempDir) {
    Write-Step "Checking system runtime dependencies..."

    # Check Visual C++ 2013 x86 (Required by EIDAToolkitService.exe and core DLLs)
    $vc2013 = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\VisualStudio\12.0\VC\Runtimes\x86" -EA SilentlyContinue).Installed -eq 1 -or
              (Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\12.0\VC\Runtimes\x86" -EA SilentlyContinue).Installed -eq 1

    if (-not $vc2013) {
        Write-Step "Downloading and installing Microsoft Visual C++ 2013 runtime..."
        $vcFile = Join-Path $TempDir "vcredist2013_x86.exe"
        try {
            $wc = New-Object System.Net.WebClient
            $wc.DownloadFile("https://aka.ms/highdpimfc2013x86enu", $vcFile)
            $proc = Start-Process $vcFile -ArgumentList "/install /quiet /norestart" -Wait -PassThru
            if ($proc.ExitCode -in 0, 3010, 1638) {
                Write-Ok "Visual C++ 2013 runtime installed successfully"
            } else {
                Write-Warn "Visual C++ 2013 installer exited with code $($proc.ExitCode)"
            }
        } catch {
            Write-Warn "Could not auto-download VC++ 2013: $($_.Exception.Message)"
        }
    } else {
        Write-Ok "Visual C++ 2013 runtime is verified"
    }

    # Check Visual C++ 2015-2022 (Required by modern SmartCard and Biometric drivers)
    $vcModern = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X86" -EA SilentlyContinue).Installed -eq 1 -or
                (Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\X86" -EA SilentlyContinue).Installed -eq 1

    if (-not $vcModern) {
        Write-Step "Downloading and installing Microsoft Visual C++ 2015-2022 runtime..."
        $vcModFile = Join-Path $TempDir "vc_redist.x86.exe"
        try {
            $wc = New-Object System.Net.WebClient
            $wc.DownloadFile("https://aka.ms/vs/17/release/vc_redist.x86.exe", $vcModFile)
            $proc = Start-Process $vcModFile -ArgumentList "/install /quiet /norestart" -Wait -PassThru
            if ($proc.ExitCode -in 0, 3010, 1638) {
                Write-Ok "Visual C++ 2015-2022 runtime installed successfully"
            } else {
                Write-Warn "Visual C++ 2015-2022 installer exited with code $($proc.ExitCode)"
            }
        } catch {
            Write-Warn "Could not auto-download VC++ 2015-2022: $($_.Exception.Message)"
        }
    } else {
        Write-Ok "Visual C++ 2015-2022 runtime is verified"
    }
}

# -----------------------------------------------------------------------------
#  MAIN
# -----------------------------------------------------------------------------
try {
    Write-Host ""
    Write-Host "  Emirates ID Card Toolkit - Deployer" -ForegroundColor Yellow
    Write-Host "  =====================================" -ForegroundColor Yellow
    Write-Host ""

    # -------------------------------------------------------------------------
    #  INSTALLATION DETECTION & INTERACTIVE MENU
    # -------------------------------------------------------------------------
    $hasExisting = (Test-AlreadyInstalled) -or (Find-InstalledMsi) -or (Test-Path $INSTALL_DIR) -or (Get-TargetSvcs) -or (Test-Path "C:\EmiratesIDCardToolkitService_64")
    $current = (Get-ItemProperty $REG_PATH -Name Version -EA SilentlyContinue).Version

    if ($hasExisting) {
        Write-Host "  Current Installation Detected:" -ForegroundColor Cyan
        Write-Host "    Version : $(if ($current) { $current } else { 'Detected on system' })"
        Write-Host "    Path    : $(if (Test-Path $INSTALL_DIR) { $INSTALL_DIR } else { 'C:\EmiratesIDCardToolkitService_64' })"
        Write-Host ""
        Write-Host "  Choose an action:" -ForegroundColor Yellow
        Write-Host "    [1] Clean Reinstall (Remove current installation and install fresh)" -ForegroundColor White
        Write-Host "    [2] Complete Uninstall (Permanently remove toolkit, services, and registry)" -ForegroundColor White
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
                Write-Host ""
                Write-Step "Executing complete uninstallation..."
                $ourSvcs = @(Get-TargetSvcs)
                foreach ($s in $ourSvcs) {
                    Write-Step "Stopping and removing service: $($s.Name)"
                    Stop-Service -Name $s.Name -Force -EA SilentlyContinue
                    & sc.exe delete "$($s.Name)" | Out-Null
                }
                Get-Process $SVC_EXE_NAME.Replace(".exe","") -EA SilentlyContinue |
                    Where-Object { Is-OurPath $_.Path -or $_.Path -like "*EmiratesIDCardToolkitService*" } | Stop-Process -Force -EA SilentlyContinue
                Start-Sleep -Seconds 2

                $existing = Find-InstalledMsi
                if ($existing) { Remove-OldInstall $existing.PSChildName; Start-Sleep -Seconds 2 }
                Clear-MsiRegistration

                if (Test-Path $INSTALL_DIR) {
                    Write-Step "Removing $INSTALL_DIR"
                    Remove-Item $INSTALL_DIR -Recurse -Force -EA SilentlyContinue
                }
                if (Test-Path "C:\EmiratesIDCardToolkitService_64") {
                    Write-Step "Removing legacy folder C:\EmiratesIDCardToolkitService_64"
                    Remove-Item "C:\EmiratesIDCardToolkitService_64" -Recurse -Force -EA SilentlyContinue
                }
                if (Test-Path $REG_PATH) {
                    Remove-Item $REG_PATH -Recurse -Force -EA SilentlyContinue
                }

                Write-Host ""
                Write-Host "  ================================================================" -ForegroundColor Cyan
                Write-Host "  [OK] Complete uninstallation finished successfully." -ForegroundColor Green
                Write-Host "  Developer : mujtaba989" -ForegroundColor Gray
                Write-Host "  Purpose   : Tasheel & Typing Center Technical Maintenance" -ForegroundColor Gray
                Write-Host "  ================================================================" -ForegroundColor Cyan
                Write-Host ""
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
    #  SCANNER HARDWARE SELECTION
    # -------------------------------------------------------------------------
    Write-Host ""
    Write-Host "  Select Biometric Hardware Configuration:" -ForegroundColor Yellow
    Write-Host "    [1] AEGIS PRO4 / Capacitive Touch Terminals (Default - Disables Morpho override)" -ForegroundColor White
    Write-Host "    [2] MorphoSmart MSO 1300 / 1350 Optical Readers" -ForegroundColor White
    Write-Host "    [3] Auto-Detect / Both (Morpho prioritized if connected)" -ForegroundColor White
    Write-Host ""

    $scannerChoice = if ($ScannerMode) {
        switch -Regex ($ScannerMode) {
            'aegis'  { '1' }
            'morpho' { '2' }
            default  { '3' }
        }
    } else {
        Read-Host "  Select preferred scanner [1-3] (Default: 1)"
    }

    if (-not $scannerChoice) { $scannerChoice = "1" }

    $targetScanner = switch ($scannerChoice.Trim()) {
        "2" { "Morpho" }
        "3" { "Auto" }
        default { "AEGIS" }
    }
    Write-Ok "Selected Biometric Profile: $targetScanner"
    Write-Host ""

    # -- STEP 1  Check for a newer release ------------------------------------
    Write-Step "[1/9] Checking for latest release on GitHub..."
    $apiHdr  = @{ "User-Agent" = "EIDToolkit-Deployer/1.0"; "Accept" = "application/vnd.github+json" }
    $release = Invoke-RestMethod "https://api.github.com/repos/$GH_REPO/releases/latest" -Headers $apiHdr
    $latest  = $release.tag_name

    Write-Host "    Latest : $latest"
    Write-Host "    Current: $(if ($current) { $current } else { 'not installed' })"

    $asset = $release.assets | Where-Object { $_.name -eq $PKG_FILENAME } | Select-Object -First 1
    if (-not $asset) { Write-Fatal "Release $latest does not contain $PKG_FILENAME" }

    # -- STEP 2  Resolve the package key --------------------------------------
    Write-Step "[2/9] Resolving package decryption key..."
    if ($KeyFile) { $PackageKey = (Get-Content $KeyFile -Raw).Trim() }
    if (-not $PackageKey) {
        $ss = Read-Host "Enter package key" -AsSecureString
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
        try   { $PackageKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    }

    # -- STEP 3  Download ------------------------------------------------------
    $_tmpDir = Join-Path $env:WINDIR ("Temp\EIDdeploy_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory $_tmpDir -Force | Out-Null

    $pkgFile = Join-Path $_tmpDir $PKG_FILENAME
    $sizeMB  = [math]::Round($asset.size / 1MB, 1)
    Write-Step "[3/9] Downloading $PKG_FILENAME ($sizeMB MB)..."

    $dlHdr = @{}; foreach ($k in $apiHdr.Keys) { $dlHdr[$k] = $apiHdr[$k] }
    $dlHdr["Accept"] = "application/octet-stream"
    Download-File -Url $asset.url -Headers $dlHdr -Out $pkgFile
    Write-Ok "Download complete"

    # -- STEP 4  Verify & decrypt ----------------------------------------------
    # Package format: "EIDPK1" (6) | salt (16) | IV (16) | AES-256-CBC ciphertext | HMAC-SHA256 (32)
    Write-Step "[4/9] Verifying package integrity and decrypting..."
    $raw     = [IO.File]::ReadAllBytes($pkgFile)
    $magic   = [Text.Encoding]::ASCII.GetString($raw, 0, 6)
    if ($magic -ne "EIDPK1") { Write-Fatal "Unrecognised package format (bad header)." }

    $salt    = New-Object byte[] 16; [Array]::Copy($raw,  6, $salt, 0, 16)
    $iv      = New-Object byte[] 16; [Array]::Copy($raw, 22, $iv,   0, 16)
    $bodyEnd = $raw.Length - 32

    $derived = Derive-Keys -Pass $PackageKey -Salt $salt -Rounds 200000 -Len 64
    [byte[]] $encKey = $derived[0..31]
    [byte[]] $macKey = $derived[32..63]

    $computed = (New-Object Security.Cryptography.HMACSHA256 (,$macKey)).ComputeHash($raw, 0, $bodyEnd)
    $mismatch = 0
    for ($i = 0; $i -lt 32; $i++) { $mismatch = $mismatch -bor ($computed[$i] -bxor $raw[$bodyEnd + $i]) }
    if ($mismatch -ne 0) { Write-Fatal "Package verification failed - wrong key or corrupted file." }

    $aes = [Security.Cryptography.Aes]::Create()
    $aes.KeySize = 256; $aes.Mode = "CBC"; $aes.Padding = "PKCS7"; $aes.Key = $encKey; $aes.IV = $iv
    $plainBytes = $aes.CreateDecryptor().TransformFinalBlock($raw, 38, $bodyEnd - 38)

    $zipFile   = Join-Path $_tmpDir "payload.zip"
    $extractTo = Join-Path $_tmpDir "payload"
    [IO.File]::WriteAllBytes($zipFile, $plainBytes)
    if (Test-Path $extractTo) { Remove-Item $extractTo -Recurse -Force }
    Expand-Archive -LiteralPath $zipFile -DestinationPath $extractTo -Force
    Write-Ok "Package verified and extracted"

    # -- STEP 5  Remove existing installation ---------------------------------
    Write-Step "[5/9] Checking and cleaning previous installation..."
    $msiFile = Get-ChildItem $extractTo -Filter *.msi | Select-Object -First 1
    if (-not $msiFile) { Write-Fatal "No MSI found in package." }
    $msiHash = (Get-FileHash $msiFile.FullName -Algorithm SHA256).Hash

    # Identify and protect services that are NOT ours
    $others = @(Get-AllToolkitSvcs |
                Where-Object { -not (Is-OurPath (Get-ExePath $_)) -and $_.DisplayName -ne $SVC_DISPLAY } |
                Select-Object Name, DisplayName, PathName, StartMode, State)
    foreach ($o in $others) { Write-Step "Preserving service: '$($o.DisplayName)'" }

    # Abort if MSI is registered elsewhere
    $existing = Find-InstalledMsi
    if ($existing) {
        $registeredExe = Get-MsiExePath $existing.PSChildName
        if ($registeredExe -and -not (Is-OurPath $registeredExe)) {
            Write-Fatal "This MSI is registered under a different folder ($(Split-Path $registeredExe -Parent)). Remove it manually first."
        }
    }

    $ourSvcs = @(Get-TargetSvcs)
    if ($ourSvcs -or (Test-Path $INSTALL_DIR) -or $existing -or (Test-MsiRegistered)) {
        Write-Step "Removing previous installation..."

        # Back up config files
        $cfgFiles = Get-ChildItem $INSTALL_DIR -Filter "config_*" -File -EA SilentlyContinue
        if ($cfgFiles) {
            $bakDir = Join-Path $BACKUP_ROOT ("cfg_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
            New-Item -ItemType Directory $bakDir -Force | Out-Null
            $cfgFiles | Copy-Item -Destination $bakDir -Force
            Write-Ok "Config backed up to $bakDir"
        }

        # Stop and delete our services
        foreach ($s in $ourSvcs) {
            Write-Step "Stopping service: $($s.Name)"
            Stop-Service -Name $s.Name -Force -EA SilentlyContinue
            & sc.exe delete "$($s.Name)" | Out-Null
        }
        Get-Process $SVC_EXE_NAME.Replace(".exe","") -EA SilentlyContinue |
            Where-Object { Is-OurPath $_.Path } | Stop-Process -Force
        Start-Sleep -Seconds 2

        if ($existing)           { Remove-OldInstall $existing.PSChildName; Start-Sleep -Seconds 3 }
        if ((Test-MsiRegistered) -or (Find-InstalledMsi)) { Clear-MsiRegistration }
        if (Test-Path $INSTALL_DIR) {
            Write-Step "Removing $INSTALL_DIR"
            Remove-Item $INSTALL_DIR -Recurse -Force -EA SilentlyContinue
        }
    } else {
        Write-Step "No previous installation found - fresh install"
    }

    # -- STEP 6  Install MSI ---------------------------------------------------
    Ensure-Dependencies -TempDir $_tmpDir
    Write-Step "[6/9] Installing official MSI package to $INSTALL_DIR..."
    $msiLog = "$env:WINDIR\Temp\EIDToolkit-msi.log"
    $args   = "/i `"$($msiFile.FullName)`" INSTALLDIR=`"$INSTALL_DIR\`" /qn /norestart /L*v `"$msiLog`""
    $result = Start-Process msiexec.exe -ArgumentList $args -Wait -PassThru
    if ($result.ExitCode -notin 0, 3010, 1641) { Write-Fatal "MSI install failed (code $($result.ExitCode)) - see $msiLog" }
    Start-Sleep -Seconds 5
    if (-not (Test-Path (Join-Path $INSTALL_DIR $SVC_EXE_NAME))) {
        Write-Fatal "MSI finished but $SVC_EXE_NAME was not found in $INSTALL_DIR - see $msiLog"
    }
    Write-Ok "MSI package installed successfully"

    # Restore any protected service that the MSI may have removed
    foreach ($o in $others) {
        if (-not (Get-Service -Name $o.Name -EA SilentlyContinue)) {
            Write-Warn "Restoring service '$($o.Name)' which was removed by the MSI"
            $start = switch ($o.StartMode) { "Auto" {"auto"} "Disabled" {"disabled"} default {"demand"} }
            & sc.exe create "$($o.Name)" binPath= "$($o.PathName)" DisplayName= "$($o.DisplayName)" start= $start | Out-Null
            if ($o.State -eq "Running") { Start-Service -Name $o.Name -EA SilentlyContinue }
        }
    }

    # -- STEP 7  Copy extra files from the package -----------------------------
    Write-Step "[7/9] Deploying updated certificates and runtime libraries..."
    $pkgRoot = (Get-Item $extractTo).FullName.TrimEnd('\')
    $mapFile = Join-Path $pkgRoot "copy-map.txt"
    $copyMap = @()

    if (Test-Path $mapFile) {
        foreach ($line in Get-Content $mapFile) {
            $line = $line.Trim()
            if (-not $line -or $line.StartsWith("#")) { continue }
            $sep  = $line.IndexOf("=")
            if ($sep -lt 1) { Write-Fatal "copy-map.txt: invalid line - '$line'" }
            $item = $line.Substring(0, $sep).Trim().Trim('"').Trim('\','/')
            $dest = [Environment]::ExpandEnvironmentVariables($line.Substring($sep + 1).Trim().Trim('"'))
            $src  = [IO.Path]::GetFullPath((Join-Path $pkgRoot $item))
            if (-not $src.StartsWith($pkgRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { Write-Fatal "copy-map.txt: '$item' escapes package root" }
            if (-not (Test-Path $src))                                                        { Write-Fatal "copy-map.txt: '$item' not found in package" }
            if (-not [IO.Path]::IsPathRooted($dest) -or $dest.Contains('%'))                  { Write-Fatal "copy-map.txt: destination must be a full path (got '$dest')" }
            $copyMap += [pscustomobject]@{ Src = $src; Dest = $dest }
        }
    }

    $ourSvc = Get-OurService
    if ($ourSvc -and $ourSvc.State -eq "Running") { Stop-Service -Name $ourSvc.Name -Force; Start-Sleep -Seconds 2 }

    function Copy-OneFile([string]$From, [string]$To) {
        New-Item -ItemType Directory (Split-Path $To -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $From -Destination $To -Force
        Write-Host "    + $To" -ForegroundColor DarkGray
    }

    # Files not in copy-map -> install folder
    foreach ($f in Get-ChildItem $pkgRoot -File -Recurse) {
        if ($f.FullName -eq $mapFile)                                   { continue }
        if ($f.DirectoryName -eq $pkgRoot -and $f.Extension -eq ".msi") { continue }
        $mapped = $false
        foreach ($m in $copyMap) {
            if ($f.FullName -eq $m.Src -or $f.FullName.StartsWith($m.Src + '\', [StringComparison]::OrdinalIgnoreCase)) {
                $mapped = $true; break
            }
        }
        if (-not $mapped) { Copy-OneFile $f.FullName (Join-Path $INSTALL_DIR $f.FullName.Substring($pkgRoot.Length + 1)) }
    }

    # Files in copy-map -> their own destinations
    foreach ($m in $copyMap) {
        if (Test-Path $m.Src -PathType Container) {
            Get-ChildItem $m.Src -File -Recurse | ForEach-Object {
                Copy-OneFile $_.FullName (Join-Path $m.Dest $_.FullName.Substring($m.Src.Length + 1))
            }
        } else {
            Copy-OneFile $m.Src (Join-Path $m.Dest (Split-Path $m.Src -Leaf))
        }
    }

    # Pull latest official files from MOHRE live zip
    try {
        Write-Step "Fetching live updates from MOHRE official server..."
        $mohreTmp = Join-Path $_tmpDir "mohre_live"
        New-Item -ItemType Directory $mohreTmp -Force | Out-Null
        $mohreZip = Join-Path $mohreTmp "EmiratesIDCardToolkitService_64.zip"

        $mohreWc = New-Object System.Net.WebClient
        $mohreWc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
        $mohreWc.DownloadFile($MOHRE_ZIP_URL, $mohreZip)

        $mohreExtracted = Join-Path $mohreTmp "extracted"
        Expand-Archive -LiteralPath $mohreZip -DestinationPath $mohreExtracted -Force

        # Sync updated config files and signature provider
        $liveFiles = Get-ChildItem $mohreExtracted -Recurse -File | Where-Object {
            $_.Name -like "config_*" -or $_.Name -like "*.jar"
        }

        foreach ($lf in $liveFiles) {
            $destFile = Join-Path $INSTALL_DIR $lf.Name
            Copy-OneFile $lf.FullName $destFile
        }
        Write-Ok "Live MOHRE configuration and certificates synced ($($liveFiles.Count) files)"
    } catch {
        Write-Warn "Could not reach MOHRE live server - using bundled offline certificates: $($_.Exception.Message)"
    }

    # Apply selected Biometric Profile (Morpho vs AEGIS)
    $sagemDll = Join-Path $INSTALL_DIR "SagemMSO1350.dll"
    if ($targetScanner -eq "AEGIS") {
        if (Test-Path $sagemDll) {
            Rename-Item $sagemDll "SagemMSO1350.dll.disabled" -Force -EA SilentlyContinue
            Write-Ok "Biometric Profile set to AEGIS: Morpho override disabled, direct binding active."
        }
    } elseif ($targetScanner -eq "Morpho" -or $targetScanner -eq "Auto") {
        $disabledSagem = Join-Path $INSTALL_DIR "SagemMSO1350.dll.disabled"
        if (Test-Path $disabledSagem) {
            Rename-Item $disabledSagem "SagemMSO1350.dll" -Force -EA SilentlyContinue
            Write-Ok "Biometric Profile set to $($targetScanner): Morpho optical reader enabled."
        }
    }

    # -- STEP 8  Register & start the service ----------------------------------
    Write-Step "[8/9] Configuring service recovery and security policies..."
    $ourSvc = Get-OurService
    if (-not $ourSvc) {
        Write-Step "Self-registering toolkit service..."
        Start-Process (Join-Path $INSTALL_DIR $SVC_EXE_NAME) -ArgumentList "-install" `
                      -WorkingDirectory $INSTALL_DIR -Wait -WindowStyle Hidden
        Start-Sleep -Seconds 3
        $ourSvc = Get-OurService
    }
    if (-not $ourSvc) { Write-Fatal "Service was not created. Check $INSTALL_DIR" }

    & sc.exe config      "$($ourSvc.Name)" DisplayName= "$SVC_DISPLAY" start= auto | Out-Null
    & sc.exe description "$($ourSvc.Name)" "$SVC_DISPLAY"              | Out-Null

    # Configure auto-recovery (restart service automatically on failure)
    & sc.exe failure "$($ourSvc.Name)" reset= 3600 actions= restart/10000/restart/30000/restart/60000 | Out-Null
    & sc.exe failureflag "$($ourSvc.Name)" 1 | Out-Null

    # Install persistent Watchdog task (daemon health monitor)
    try {
        $taskName = "EIDToolkit-Watchdog"
        $wdPath = Join-Path $BACKUP_ROOT "watchdog.ps1"
        New-Item -ItemType Directory $BACKUP_ROOT -Force | Out-Null

        $watchdogScript = @"
# EIDToolkit Watchdog - Persistent Health & Port Monitor
`$svcName = '$($ourSvc.Name)'
`$port = 9004
`$logFile = "`$env:WINDIR\Temp\EIDToolkit-watchdog.log"

function Write-Log(`$msg) {
    "`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  `$msg" | Out-File `$logFile -Append
}

`$svc = Get-Service -Name `$svcName -EA SilentlyContinue
if (-not `$svc -or `$svc.Status -ne "Running") {
    Write-Log "CRITICAL: Service `$svcName is stopped. Auto-restarting..."
    Start-Service `$svcName -EA SilentlyContinue
    Start-Sleep -Seconds 5
}

`$portUp = `$false
try {
    `$tcp = New-Object Net.Sockets.TcpClient
    `$tcp.Connect("127.0.0.1", `$port)
    `$portUp = `$tcp.Connected
    `$tcp.Close()
} catch { }

if (-not `$portUp) {
    Write-Log "WARNING: Port `$port not responding. Cycling `$svcName..."
    Stop-Service `$svcName -Force -EA SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Service `$svcName -EA SilentlyContinue
    Start-Sleep -Seconds 5
    `$newState = (Get-Service `$svcName -EA SilentlyContinue).Status
    Write-Log "Cycle complete. New state: `$newState"
}
"@
        [IO.File]::WriteAllText($wdPath, $watchdogScript, [System.Text.Encoding]::ASCII)

        # Use native schtasks.exe (100% universal across Windows 10 & 11 without CIM/PowerShell type-binding quirks)
        $taskCmd = "powershell.exe -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File \`"$wdPath\`""
        $res = & schtasks.exe /create /tn "$taskName" /tr "$taskCmd" /sc minute /mo 1 /ru "SYSTEM" /rl HIGHEST /f 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "Daemon watchdog installed (monitors service & port 9004 every 1 minute across Windows 10 & 11)"
        } else {
            # Fallback to PowerShell ScheduledTask cmdlet
            $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$wdPath`""
            $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 2)
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -User "SYSTEM" -Force | Out-Null
            Write-Ok "Daemon watchdog registered via fallback"
        }
    } catch {
        Write-Warn "Could not register watchdog task: $($_.Exception.Message)"
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
    $planGuid = (powercfg /getactivescheme) -replace '.*GUID:\s+(\S+).*','$1'
    if ($planGuid) {
        powercfg /setacvalueindex $planGuid 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 2>$null
        powercfg /setdcvalueindex $planGuid 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 2>$null
        powercfg /setactive $planGuid 2>$null
    }

    # Windows 10 Hardware Compatibility: Disable USB power-saving on AEGIS / Richmond / AGF200 & USB Hubs
    $aegisNodes = Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Enum\USB" -Recurse -EA SilentlyContinue |
        Where-Object { $_.PSChildName -eq "Device Parameters" -and ($_.PSPath -like "*VID_3969*" -or $_.PSPath -like "*VID_2075*" -or $_.PSPath -like "*RootHub*" -or $_.PSPath -like "*GenericHub*") }

    foreach ($node in $aegisNodes) {
        Set-ItemProperty $node.PSPath -Name "EnhancedPowerManagementEnabled" -Value 0 -Type DWord -EA SilentlyContinue
        Set-ItemProperty $node.PSPath -Name "AllowIdleIrpInD3" -Value 0 -Type DWord -EA SilentlyContinue
        Set-ItemProperty $node.PSPath -Name "DeviceSelectiveSuspended" -Value 0 -Type DWord -EA SilentlyContinue
        Set-ItemProperty $node.PSPath -Name "SelectiveSuspendEnabled" -Value 0 -Type DWord -EA SilentlyContinue
    }

    # Ensure Windows Camera / UVC optical sensor access is allowed (required for AEGIS AGF200 on Windows 10)
    $camPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam"
    )
    foreach ($cp in $camPaths) {
        if (-not (Test-Path $cp)) { New-Item -Path $cp -Force -EA SilentlyContinue | Out-Null }
        Set-ItemProperty $cp -Name "Value" -Value "Allow" -EA SilentlyContinue
    }
    Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" -Name "LetAppsAccessCamera" -Value 1 -Type DWord -EA SilentlyContinue

    $conflict = Get-Service ICAToolkit -EA SilentlyContinue
    if ($conflict -and $conflict.Status -eq "Running") {
        Write-Warn "ICAToolkit service is also running - only one instance can be active at a time."
    }

    try {
        Start-Service -Name $ourSvc.Name
        Start-Sleep -Seconds 3
        $status = (Get-Service -Name $ourSvc.Name).Status
        Write-Ok "Service '$SVC_DISPLAY' is $status"
    } catch {
        Write-Warn "Service installed but could not start: $($_.Exception.Message)"
    }

    # -- STEP 9  Record version ------------------------------------------------
    Write-Step "[9/9] Registering installation metadata..."
    New-Item $REG_PATH -Force | Out-Null
    Set-ItemProperty $REG_PATH -Name Version -Value $latest
    Set-ItemProperty $REG_PATH -Name MsiHash -Value $msiHash
    Set-ItemProperty $REG_PATH -Name Updated -Value (Get-Date -Format "yyyy-MM-dd HH:mm")
    Set-ItemProperty $REG_PATH -Name InstallDir -Value $INSTALL_DIR

    Write-Host ""
    Write-Host "  ================================================================" -ForegroundColor Cyan
    Write-Host "  EID Toolkit $latest successfully deployed to $INSTALL_DIR" -ForegroundColor Green
    Write-Host "  Biometric  : $targetScanner Profile Active" -ForegroundColor Green
    Write-Host "  Developer  : mujtaba989" -ForegroundColor Gray
    Write-Host "  Purpose    : Tasheel & Typing Center Technical Maintenance" -ForegroundColor Gray
    Write-Host "  ================================================================" -ForegroundColor Cyan
    Write-Host ""
}
catch {
    Write-Host ""
    Write-Host "  [X]  ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "     Log: $LOG_FILE" -ForegroundColor Red
    Write-Host ""
    $global:LASTEXITCODE = 1
}
finally {
    $PackageKey = $null
    if ($_tmpDir -and (Test-Path $_tmpDir)) { Remove-Item $_tmpDir -Recurse -Force -EA SilentlyContinue }
    if ($_transcriptOn) { try { Stop-Transcript | Out-Null } catch { } }
}
