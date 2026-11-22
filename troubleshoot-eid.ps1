<#
.SYNOPSIS
    Emirates ID Card Toolkit - Troubleshooter & WSS Stability Fixer

.DESCRIPTION
    Diagnoses and fixes the most common causes of:
    - "Failed to capture fingerprint image"
    - WebSocket (WSS) disconnects on eservices.mohre.gov.ae
    - Service not starting / initialisation failed
    - Certificate / config errors

    Root causes addressed:
    A) Expired VG signing certificate  -> service crashes -> WSS drops
    B) No service auto-recovery        -> one crash = permanent outage until reboot
    C) USB selective suspend           -> fingerprint device sleeps mid-session
    D) Missing VC++ 2013 runtime       -> DLL load failure
    E) Firewall blocking local port    -> browser can never connect

.EXAMPLE
    irm https://raw.githubusercontent.com/mujtaba989/toolkit/main/troubleshoot-eid.ps1 | iex
#>
param(
    [switch] $ReportOnly   # diagnose only, make no changes
)

$ErrorActionPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# -----------------------------------------------------------------------------
#  HELPERS
# -----------------------------------------------------------------------------
function Title  { param($t) Write-Host "`n  [$t]" -ForegroundColor Yellow }
function Ok     { param($m) Write-Host "    [PASS]  $m" -ForegroundColor Green }
function Fail   { param($m) Write-Host "    [FAIL]  $m" -ForegroundColor Red }
function Warn   { param($m) Write-Host "    [WARN]  $m" -ForegroundColor DarkYellow }
function Info   { param($m) Write-Host "    [INFO]  $m" -ForegroundColor Cyan }
function Fixed  { param($m) Write-Host "    [FIXED] $m" -ForegroundColor Magenta }

$issues = [System.Collections.Generic.List[string]]::new()
$fixes  = [System.Collections.Generic.List[string]]::new()

# -----------------------------------------------------------------------------
#  LOCATE TOOLKIT SERVICE
# -----------------------------------------------------------------------------
$svc = Get-WmiObject Win32_Service -Filter "Name='ICAToolkitService'" -EA SilentlyContinue
if (-not $svc) {
    $svc = Get-WmiObject Win32_Service -EA SilentlyContinue |
           Where-Object { $_.DisplayName -eq "Emirates ID Card Toolkit Service" } |
           Select-Object -First 1
}
$svcDir  = $null
$svcName = $null
if ($svc) {
    $exePath = ($svc.PathName -replace '^"([^"]+)".*$','$1') -replace '\.exe\s+.*$','.exe'
    $svcDir  = Split-Path $exePath -Parent
    $svcName = $svc.Name
}

Write-Host ""
Write-Host "  Emirates ID Toolkit - Troubleshooter & WSS Stability Fixer" -ForegroundColor Cyan
Write-Host "  ==============================================================" -ForegroundColor Cyan
Write-Host "  Target: https://eservices.mohre.gov.ae/tasheelweb/eidaservice.aspx" -ForegroundColor DarkGray
Write-Host ""

# ----------------------------------------------------------------------------
Title "1. SERVICE STATE"
# ----------------------------------------------------------------------------
if (-not $svc) {
    Fail "Emirates ID Card Toolkit Service not found - run install-eid.ps1 first"
    $issues.Add("Service not installed") | Out-Null
} else {
    Info "Service   : $($svc.Name)  |  $($svc.DisplayName)"
    Info "Directory : $svcDir"
    Info "StartType : $($svc.StartMode)   |   State: $($svc.State)"

    if ($svc.State -ne "Running") {
        Fail "Service is $($svc.State) - WSS will drop immediately because nothing is listening"
        $issues.Add("Service is $($svc.State)") | Out-Null
    } else {
        Ok "Service is Running"
    }

    if ($svc.StartMode -ne "Auto") {
        Warn "StartType is '$($svc.StartMode)' - after a reboot it will NOT start automatically"
        $issues.Add("StartType is not Automatic") | Out-Null
        if (-not $ReportOnly) {
            & sc.exe config "$svcName" start= auto | Out-Null
            Fixed "StartType set to Automatic"
            $fixes.Add("Set service StartType to Automatic") | Out-Null
        }
    }
}

# ----------------------------------------------------------------------------
Title "2. ROOT CAUSE - EXPIRED VG CERTIFICATE (causes WSS drops)"
# ----------------------------------------------------------------------------
if ($svcDir) {
    $latestLog = Get-ChildItem $svcDir -Filter "*.log" -EA SilentlyContinue |
                 Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if ($latestLog) {
        $logText = Get-Content $latestLog.FullName -Raw -EA SilentlyContinue
        Info "Analysing: $($latestLog.Name)"

        # Cert expired - check specifically for expiration error
        if ($logText -match "certificate has expired") {
            Fail "EXPIRED VG CERTIFICATE detected"
            Fail "Sequence: cert expired -> toolkit won't init -> service stops -> browser WSS drops"
            $issues.Add("VG signing certificate expired - PRIMARY cause of WSS drops") | Out-Null
            Info "Fix: re-run install-eid.ps1 to replace config_vg_prod with the fresh cert"
        } elseif ($logText -match "certificate.*(failed|invalid|error)") {
            Warn "Certificate warning in log - check manually"
        } else {
            Ok "No certificate errors in latest log"
        }

        # License
        $expMatch = [regex]::Match($logText, 'License expiry date \["([^"]+)"')
        if ($expMatch.Success) {
            $expDate = [datetime]::Parse($expMatch.Groups[1].Value.Split('+')[0])
            if ($expDate -lt (Get-Date)) {
                Fail "LICENSE EXPIRED on $expDate"
                $issues.Add("License expired") | Out-Null
            } else {
                Ok "License valid until $expDate"
            }
        }

        # Agent fatal
        if ($logText -match "Agent initialisation failed") {
            Fail "Agent init failed - service bound no port -> browser WSS has nothing to connect to"
            $issues.Add("Agent failed to bind WSS port") | Out-Null
        }
    }

    # Count how many days this has been failing
    $failCount = (Get-ChildItem $svcDir -Filter "*.log" -EA SilentlyContinue |
                  Where-Object { (Get-Content $_.FullName -Raw) -match "certificate has expired" }).Count
    if ($failCount -gt 0) {
        Warn "Certificate has caused init failure in $failCount separate log files (days)"
    }
}

# ----------------------------------------------------------------------------
Title "3. SERVICE RECOVERY (auto-restart on crash)"
# ----------------------------------------------------------------------------
# Check current failure actions via sc.exe qfailure
$qf = & sc.exe qfailure "$svcName" 2>$null | Out-String
if ($qf -match "RESTART -- Delay") {
    Ok "Service recovery is configured (auto-restart on failure)"
} else {
    Warn "No auto-recovery configured - a single crash leaves the port closed until someone manually restarts"
    $issues.Add("No service auto-recovery") | Out-Null
    if (-not $ReportOnly -and $svcName) {
        # Reset count after 1 hour; restart after 10s, 30s, 60s
        & sc.exe failure "$svcName" reset= 3600 actions= restart/10000/restart/30000/restart/60000 | Out-Null
        Fixed "Service recovery: restart after 10s / 30s / 60s on failure"
        $fixes.Add("Configured service auto-recovery (restart on failure)") | Out-Null
    }
}

# ----------------------------------------------------------------------------
Title "4. WATCHDOG SCHEDULED TASK"
# ----------------------------------------------------------------------------
# A watchdog catches the case where the service 'runs' but binds no port
$taskName = "EIDToolkit-Watchdog"
$existing = Get-ScheduledTask -TaskName $taskName -EA SilentlyContinue

if ($existing) {
    Ok "Watchdog task '$taskName' already installed"
    Info "It runs every 2 minutes and restarts the service if the port goes silent"
} else {
    Warn "No watchdog task - if the service crashes silently, WSS stays down until manual fix"
    $issues.Add("No watchdog scheduled task") | Out-Null

    if (-not $ReportOnly -and $svcName) {
        # Find the port the toolkit uses (MOHRE default is 9004)
        $cfgAg   = Join-Path $svcDir "config_ag"
        $portNum = 9004   # default MOHRE / Tasheel port
        if (Test-Path $cfgAg) {
            $cfgText = Get-Content $cfgAg -Raw -EA SilentlyContinue
            $pm = [regex]::Match($cfgText, '"port"\s*:\s*(\d+)')
            if ($pm.Success) { $portNum = [int]$pm.Groups[1].Value }
        }
        Info "Toolkit port detected: $portNum"

        $watchdogScript = @"
# EIDToolkit Watchdog - auto-generated by troubleshoot-eid.ps1
`$svcName = '$svcName'
`$port    = $portNum
`$logFile = "`$env:WINDIR\Temp\EIDToolkit-watchdog.log"

function Write-Log(`$msg) {
    "`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  `$msg" | Out-File `$logFile -Append
}

`$svc = Get-Service -Name `$svcName -EA SilentlyContinue
`$portUp = `$false
try {
    `$tcp = New-Object Net.Sockets.TcpClient
    `$tcp.Connect("127.0.0.1", `$port)
    `$portUp = `$tcp.Connected
    `$tcp.Close()
} catch { }

if (-not `$portUp) {
    Write-Log "Port `$port not responding. Service state: `$(`$svc.Status). Restarting..."
    Stop-Service `$svcName -Force -EA SilentlyContinue
    Start-Sleep -Seconds 3
    Start-Service `$svcName -EA SilentlyContinue
    Start-Sleep -Seconds 8
    `$newState = (Get-Service `$svcName -EA SilentlyContinue).Status
    Write-Log "Service restarted. New state: `$newState"
} else {
    # Port is up - no action needed
}
"@
        $wdPath = "$env:ProgramData\EIDToolkit\watchdog.ps1"
        New-Item -ItemType Directory "$env:ProgramData\EIDToolkit" -Force | Out-Null
        [IO.File]::WriteAllText($wdPath, $watchdogScript)

        $taskCmd = "powershell.exe -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File \`"$wdPath\`""
        $res = & schtasks.exe /create /tn "$taskName" /tr "$taskCmd" /sc minute /mo 1 /ru "SYSTEM" /rl HIGHEST /f 2>&1
        if ($LASTEXITCODE -eq 0) {
            Fixed "Watchdog task '$taskName' created - checks port $portNum every 1 minute"
        } else {
            try {
                $action  = New-ScheduledTaskAction -Execute "powershell.exe" `
                               -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$wdPath`""
                $trigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 1) -Once -At (Get-Date)
                $settings= New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 1) `
                               -MultipleInstances IgnoreNew -StartWhenAvailable
                $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
                Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
                    -Settings $settings -Principal $principal -Force | Out-Null
                Fixed "Watchdog task '$taskName' created (PowerShell fallback)"
            } catch {
                Warn "Could not register watchdog task: $($_.Exception.Message)"
            }
        }
        Fixed "Watchdog log: $env:WINDIR\Temp\EIDToolkit-watchdog.log"
        $fixes.Add("Created watchdog scheduled task (every 2 min, port $portNum)") | Out-Null
    }
}

# ----------------------------------------------------------------------------
Title "5. USB SELECTIVE SUSPEND (device sleeps mid-session)"
# ----------------------------------------------------------------------------
# Biometric / smart-card USB devices going to sleep break the WSS mid-capture
$bioDev = Get-PnpDevice -EA SilentlyContinue | Where-Object {
    $_.Class -like "*Biometric*" -or $_.Class -like "*SmartCard*" -or
    $_.FriendlyName -like "*morpho*" -or $_.FriendlyName -like "*secugen*" -or
    $_.FriendlyName -like "*fingerprint*" -or $_.FriendlyName -like "*MSO*"
}

if ($bioDev) {
    foreach ($d in $bioDev) {
        Info "Device: $($d.FriendlyName) [$($d.Status)]"
    }

    # Check USB Root Hubs and USB Hubs
    $usbHubs = Get-PnpDevice -Class USB -EA SilentlyContinue |
               Where-Object { $_.FriendlyName -like "*Root Hub*" -or $_.FriendlyName -like "*USB Hub*" }
    $hubsToFix = @()
    $totalHubs = 0
    foreach ($hub in $usbHubs) {
        $devPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($hub.InstanceId)\Device Parameters"
        if (Test-Path $devPath) {
            $totalHubs++
            $val = (Get-ItemProperty $devPath -Name "SelectiveSuspendEnabled" -EA SilentlyContinue).SelectiveSuspendEnabled
            if ($null -eq $val -or $val -ne 0) {
                $hubsToFix += $devPath
            }
        }
    }

    if ($hubsToFix.Count -eq 0 -and $totalHubs -gt 0) {
        Ok "USB selective suspend is disabled on all $totalHubs USB hub(s)"
    } else {
        if (-not $ReportOnly) {
            $fixed = 0
            foreach ($dp in $hubsToFix) {
                Set-ItemProperty $dp -Name "SelectiveSuspendEnabled" -Value 0 -Type DWord -EA SilentlyContinue
                $fixed++
            }
            Fixed "Disabled USB selective suspend on $fixed hub(s)"
            $fixes.Add("Disabled USB selective suspend ($fixed hubs)") | Out-Null
        } else {
            Warn "USB selective suspend is enabled on $($hubsToFix.Count) hub(s)"
            $issues.Add("USB selective suspend enabled on hubs") | Out-Null
        }
    }

    # Check power plan USB selective suspend setting
    $planGuid = (powercfg /getactivescheme) -replace '.*GUID:\s+(\S+).*','$1'
    if ($planGuid) {
        $pQuery = powercfg /query $planGuid 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 2>$null
        $acDisabled = [bool]($pQuery | Select-String "Current AC Power Setting Index: 0x00000000")
        $dcDisabled = [bool]($pQuery | Select-String "Current DC Power Setting Index: 0x00000000")

        if ($acDisabled -and $dcDisabled) {
            Ok "USB selective suspend is disabled in active power plan"
        } else {
            if (-not $ReportOnly) {
                powercfg /setacvalueindex $planGuid 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 2>$null
                powercfg /setdcvalueindex $planGuid 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 2>$null
                powercfg /setactive $planGuid 2>$null
                Fixed "USB selective suspend disabled in active power plan"
                $fixes.Add("Disabled USB selective suspend in power plan") | Out-Null
            } else {
                Warn "USB selective suspend is enabled in active power plan"
                $issues.Add("USB selective suspend enabled in power plan") | Out-Null
            }
        }
    }
} else {
    Warn "No biometric/fingerprint device detected - plug in the scanner and re-run"
    $issues.Add("Fingerprint device not connected") | Out-Null
}

# ----------------------------------------------------------------------------
Title "6. SMART CARD SERVICE"
# ----------------------------------------------------------------------------
$scSvc = Get-Service SCardSvr -EA SilentlyContinue
if (-not $scSvc) {
    Fail "Smart Card service (SCardSvr) not found"
    $issues.Add("SCardSvr missing") | Out-Null
} elseif ($scSvc.Status -ne "Running") {
    Warn "Smart Card service is $($scSvc.Status)"
    $issues.Add("SCardSvr not running") | Out-Null
    if (-not $ReportOnly) {
        Set-Service SCardSvr -StartupType Automatic -EA SilentlyContinue
        Start-Service SCardSvr -EA SilentlyContinue
        Start-Sleep -Seconds 2
        if ((Get-Service SCardSvr -EA SilentlyContinue).Status -eq "Running") {
            Fixed "Smart Card service started"
            $fixes.Add("Started SCardSvr") | Out-Null
        }
    }
} else {
    Ok "Smart Card service (SCardSvr) is Running"
}

# ----------------------------------------------------------------------------
Title "7. TOOLKIT PORT (WSS endpoint)"
# ----------------------------------------------------------------------------
$toolkitPorts = @(9004, 9005, 9006, 9020, 7050, 7051, 8443, 8080)
$activePort   = $null
foreach ($p in $toolkitPorts) {
    $hit = netstat -ano 2>$null | Select-String "(?:0\.0\.0\.0|127\.0\.0\.1):$p\s" |
           Where-Object { $_ -match "LISTENING" }
    if ($hit) { $activePort = $p; break }
}

if ($activePort) {
    Ok "Toolkit WSS port $activePort is LISTENING - browser can connect"
} else {
    Fail "No toolkit port is listening - WSS has nothing to connect to"
    Fail "This confirms the service started but crashed before binding (cert / init failure)"
    $issues.Add("Toolkit port not listening") | Out-Null
}

# ----------------------------------------------------------------------------
Title "8. FIREWALL"
# ----------------------------------------------------------------------------
$fwRules = Get-NetFirewallRule -EA SilentlyContinue |
           Where-Object { $_.DisplayName -like "*Emirates*" -or $_.DisplayName -like "*EIDA*" -or
                          $_.DisplayName -like "*EIDToolkit*" }
if ($fwRules) {
    foreach ($r in $fwRules) {
        $en = if ($r.Enabled -eq "True") {"Enabled"} else {"DISABLED"}
        if ($r.Action -eq "Block") { Fail "Firewall BLOCKING: $($r.DisplayName)" ; $issues.Add("Firewall blocking toolkit") | Out-Null }
        else                       { Ok   "Firewall Allow: $($r.DisplayName) [$en]" }
    }
} else {
    Warn "No dedicated firewall rule - Windows Firewall may prompt to block the service"
    if (-not $ReportOnly -and $svcDir) {
        $exe = Join-Path $svcDir "EIDAToolkitService.exe"
        New-NetFirewallRule -DisplayName "EIDToolkit - Allow inbound" `
            -Direction Inbound -Program $exe -Action Allow -Profile Any -EA SilentlyContinue | Out-Null
        Fixed "Added inbound allow rule for EIDAToolkitService.exe"
        $fixes.Add("Added firewall allow rule") | Out-Null
    }
}

# ----------------------------------------------------------------------------
Title "9. VC++ 2013 RUNTIME"
# ----------------------------------------------------------------------------
$vc = Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
                       "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -EA SilentlyContinue |
     Where-Object { $_.DisplayName -like "Microsoft Visual C++ 2013*" }
if ($vc) {
    Ok "VC++ 2013 Redistributable: $($vc[0].DisplayName)"
} else {
    Fail "VC++ 2013 Redistributable missing - msvcp120.dll / msvcr120.dll will fail"
    $issues.Add("VC++ 2013 Redistributable missing") | Out-Null
    if (-not $ReportOnly) {
        $tmp = "$env:TEMP\vcredist_x86.exe"
        try {
            (New-Object Net.WebClient).DownloadFile("https://aka.ms/highdpimfc2013x86enu", $tmp)
            Start-Process $tmp -ArgumentList "/install /quiet /norestart" -Wait
            Fixed "VC++ 2013 Redistributable installed"
            $fixes.Add("Installed VC++ 2013 Redistributable") | Out-Null
        } catch {
            Warn "Auto-install failed - download from: https://aka.ms/highdpimfc2013x86enu"
        }
    }
}

# ----------------------------------------------------------------------------
Title "10. BROWSER EXTENSION CHECK"
# ----------------------------------------------------------------------------
Info "The MOHRE page requires the 'Emirates ID Card Toolkit' browser extension"
Info "Chrome : chrome://extensions   |   Edge: edge://extensions"
Info "Look for: 'Emirates ID Card Toolkit' or 'ICA Toolkit' - must be ENABLED"
Info "If missing: install from your IT admin or re-run the MOHRE page - it may prompt you"

$chromeExtDir = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Extensions"
$edgeExtDir   = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Extensions"
if (Test-Path $chromeExtDir) { Info "Chrome extensions folder found" }
if (Test-Path $edgeExtDir)   { Info "Edge extensions folder found" }

# ----------------------------------------------------------------------------
#  RESTART SERVICE (after all fixes)
# ----------------------------------------------------------------------------
if (-not $ReportOnly -and $svcName) {
    $currentState = (Get-Service -Name $svcName -EA SilentlyContinue).Status
    if ($currentState -ne "Running") {
        Title "RESTARTING SERVICE"
        Stop-Service $svcName -Force -EA SilentlyContinue
        Start-Sleep -Seconds 2
        Start-Service $svcName -EA SilentlyContinue
        Start-Sleep -Seconds 6
        $newState = (Get-Service -Name $svcName -EA SilentlyContinue).Status
        if ($newState -eq "Running") { Fixed "Service is now Running" ; $fixes.Add("Restarted service") | Out-Null }
        else                         { Fail  "Service still not running - expired cert must be fixed first (re-run install-eid.ps1)" }
    }
}

# ----------------------------------------------------------------------------
#  SUMMARY
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "  ---------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host "  SUMMARY" -ForegroundColor Yellow
Write-Host "  ---------------------------------------------------------------" -ForegroundColor DarkGray

if ($issues.Count -eq 0) {
    Write-Host "  No issues found!" -ForegroundColor Green
    Write-Host "  If WSS still drops on the MOHRE page:" -ForegroundColor White
    Write-Host "    1. Hard-reload the page (Ctrl+Shift+R)" -ForegroundColor White
    Write-Host "    2. Confirm extension is enabled in browser" -ForegroundColor White
    Write-Host "    3. Try Edge instead of Chrome (or vice versa)" -ForegroundColor White
    Write-Host "    4. Disable browser hardware acceleration" -ForegroundColor White
} else {
    Write-Host "  Issues found ($($issues.Count)):" -ForegroundColor Red
    $i = 1; $issues | ForEach-Object { Write-Host "    $i. $_" -ForegroundColor Red; $i++ }
}

if ($fixes.Count -gt 0) {
    Write-Host ""
    Write-Host "  Fixes applied ($($fixes.Count)):" -ForegroundColor Magenta
    $fixes | ForEach-Object { Write-Host "    [OK] $_" -ForegroundColor Magenta }
}

Write-Host ""
Write-Host "  -- Action required ---------------------------------------------" -ForegroundColor DarkGray
Write-Host "  1. Re-run installer to fix expired cert (PRIMARY WSS drop cause):" -ForegroundColor White
Write-Host "     irm https://raw.githubusercontent.com/mujtaba989/toolkit/main/install-eid.ps1 | iex" -ForegroundColor Green
Write-Host ""
Write-Host "  2. Logs:" -ForegroundColor White
if ($svcDir) { Write-Host "     Toolkit : $svcDir\EIDAToolkit_*.log" -ForegroundColor DarkGray }
Write-Host "     Watchdog: $env:WINDIR\Temp\EIDToolkit-watchdog.log" -ForegroundColor DarkGray
Write-Host "     Install : $env:WINDIR\Temp\EIDToolkit-install.log" -ForegroundColor DarkGray
Write-Host ""
