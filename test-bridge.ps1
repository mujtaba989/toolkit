# ==============================================================================
# Emirates ID & AEGIS PRO 4 Hardware Diagnostic Test Bridge
# Runs as 32-bit PowerShell process to interface with ID_FprCap.dll and WinSCard
# Author: mujtaba989
# ==============================================================================

# Ensure 32-bit execution for 32-bit ID_FprCap.dll
if ([IntPtr]::Size -eq 8) {
    $sysWow64PowerShell = Join-Path $env:windir "SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
    if (Test-Path $sysWow64PowerShell) {
        Write-Host "Switching to 32-bit PowerShell for ID_FprCap.dll compatibility..." -ForegroundColor Cyan
        & $sysWow64PowerShell -NoProfile -ExecutionPolicy Bypass -File $MyInvocation.MyCommand.Path @args
        exit $LASTEXITCODE
    }
}

$PORT = 9005
$DLL_PATH = "C:\EmiratesIDCardToolkitService_64\ID_FprCap.dll"

if (-not (Test-Path $DLL_PATH)) {
    Write-Host "[ERROR] ID_FprCap.dll not found at $DLL_PATH" -ForegroundColor Red
    Write-Host "Please ensure Emirates ID Card Toolkit is installed." -ForegroundColor Yellow
    pause
    exit 1
}

# Define C# P/Invoke signatures
$typeDefinition = @"
using System;
using System.Runtime.InteropServices;

public class AegisFprNative {
    [DllImport(@"$DLL_PATH", CallingConvention = CallingConvention.StdCall)]
    public static extern int LIVESCAN_Init();

    [DllImport(@"$DLL_PATH", CallingConvention = CallingConvention.StdCall)]
    public static extern int LIVESCAN_Close();

    [DllImport(@"$DLL_PATH", CallingConvention = CallingConvention.StdCall)]
    public static extern int SetLedStatus(int status);

    [DllImport(@"$DLL_PATH", CallingConvention = CallingConvention.StdCall)]
    public static extern int LIVESCAN_GetChannelCount();

    [DllImport(@"$DLL_PATH", CallingConvention = CallingConvention.StdCall)]
    public static extern int LIVESCAN_GetMaxImageSize(int channel, ref int pnWidth, ref int pnHeight);

    [DllImport(@"$DLL_PATH", CallingConvention = CallingConvention.StdCall)]
    public static extern int LIVESCAN_BeginCapture(int channel);

    [DllImport(@"$DLL_PATH", CallingConvention = CallingConvention.StdCall)]
    public static extern int LIVESCAN_GetFPRawData(int channel, byte[] pRawData);

    [DllImport(@"$DLL_PATH", CallingConvention = CallingConvention.StdCall)]
    public static extern int LIVESCAN_EndCapture(int channel);

    [DllImport("winscard.dll")]
    public static extern int SCardEstablishContext(uint dwScope, IntPtr pvReserved1, IntPtr pvReserved2, out IntPtr phContext);

    [DllImport("winscard.dll")]
    public static extern int SCardReleaseContext(IntPtr hContext);

    [DllImport("winscard.dll", EntryPoint = "SCardListReadersA", CharSet = CharSet.Ansi)]
    public static extern int SCardListReaders(IntPtr hContext, string mszGroups, byte[] mszReaders, ref int pcchReaders);

    [DllImport("winscard.dll", EntryPoint = "SCardConnectA", CharSet = CharSet.Ansi)]
    public static extern int SCardConnect(IntPtr hContext, string szReader, uint dwShareMode, uint dwPreferredProtocols, out IntPtr phCard, out uint pdwActiveProtocol);

    [DllImport("winscard.dll", EntryPoint = "SCardStatusA", CharSet = CharSet.Ansi)]
    public static extern int SCardStatus(IntPtr hCard, byte[] szReaderName, ref int pcchReaderLen, out uint pdwState, out uint pdwProtocol, byte[] pbAtr, ref int pcbAtrLen);

    [DllImport("winscard.dll")]
    public static extern int SCardDisconnect(IntPtr hCard, uint dwDisposition);
}
"@

try {
    Add-Type -TypeDefinition $typeDefinition -ErrorAction Stop
} catch {
    # Type may already be loaded if re-run in same session
}

function Convert-RawToBmpBase64([byte[]]$raw, [int]$width, [int]$height) {
    $bmp = New-Object byte[] (14 + 40 + 1024 + $raw.Length)
    # File Header (14 bytes)
    $bmp[0] = 0x42; $bmp[1] = 0x4D # 'BM'
    $fileSize = $bmp.Length
    [BitConverter]::GetBytes([int]$fileSize).CopyTo($bmp, 2)
    $pixelOffset = 14 + 40 + 1024
    [BitConverter]::GetBytes([int]$pixelOffset).CopyTo($bmp, 10)

    # Info Header (40 bytes)
    [BitConverter]::GetBytes([int]40).CopyTo($bmp, 14)       # biSize
    [BitConverter]::GetBytes([int]$width).CopyTo($bmp, 18)    # biWidth
    [BitConverter]::GetBytes([int]-$height).CopyTo($bmp, 22)  # biHeight (negative = top-down)
    [BitConverter]::GetBytes([int16]1).CopyTo($bmp, 26)       # biPlanes
    [BitConverter]::GetBytes([int16]8).CopyTo($bmp, 28)       # biBitCount
    [BitConverter]::GetBytes([int]0).CopyTo($bmp, 30)        # biCompression
    [BitConverter]::GetBytes([int]$raw.Length).CopyTo($bmp, 34) # biSizeImage
    [BitConverter]::GetBytes([int]19685).CopyTo($bmp, 38)     # biXPelsPerMeter (500 DPI)
    [BitConverter]::GetBytes([int]19685).CopyTo($bmp, 42)     # biYPelsPerMeter (500 DPI)
    [BitConverter]::GetBytes([int]256).CopyTo($bmp, 46)       # biClrUsed

    # 256 Color Palette (Grayscale)
    $palOff = 54
    for ($i = 0; $i -lt 256; $i++) {
        $p = $palOff + ($i * 4)
        $bmp[$p]     = [byte]$i # B
        $bmp[$p + 1] = [byte]$i # G
        $bmp[$p + 2] = [byte]$i # R
        $bmp[$p + 3] = 0
    }

    # Pixel Data
    [Array]::Copy($raw, 0, $bmp, $pixelOffset, $raw.Length)
    return "data:image/bmp;base64," + [Convert]::ToBase64String($bmp)
}

function Get-SmartCardInfo() {
    $hCtx = [IntPtr]::Zero
    $ret = [AegisFprNative]::SCardEstablishContext(0, [IntPtr]::Zero, [IntPtr]::Zero, [ref]$hCtx)
    if ($ret -ne 0) {
        return @{ success = $false; error = "SCardEstablishContext failed: $ret" }
    }

    $cch = 2048
    $buf = New-Object byte[] $cch
    $ret = [AegisFprNative]::SCardListReaders($hCtx, $null, $buf, [ref]$cch)
    if ($ret -ne 0) {
        [AegisFprNative]::SCardReleaseContext($hCtx) | Out-Null
        return @{ success = $false; error = "SCardListReaders failed: $ret" }
    }

    $rawStr = [System.Text.Encoding]::ASCII.GetString($buf, 0, $cch)
    $readers = $rawStr.Split("`0") | Where-Object { $_.Trim().Length -gt 0 }

    $cardResults = @()
    foreach ($r in $readers) {
        $hCard = [IntPtr]::Zero
        $proto = 0
        $connRet = [AegisFprNative]::SCardConnect($hCtx, $r, 2, 3, [ref]$hCard, [ref]$proto)
        if ($connRet -eq 0) {
            $rName = New-Object byte[] 256
            $rNameLen = 256
            $state = 0
            $atr = New-Object byte[] 36
            $atrLen = 36
            $statRet = [AegisFprNative]::SCardStatus($hCard, $rName, [ref]$rNameLen, [ref]$state, [ref]$proto, $atr, [ref]$atrLen)
            $atrHex = ($atr[0..($atrLen - 1)] | ForEach-Object { "{0:X2}" -f $_ }) -join "-"
            [AegisFprNative]::SCardDisconnect($hCard, 0) | Out-Null
            $cardResults += @{
                reader = $r
                card_inserted = $true
                atr = $atrHex
                status = "Card Present and Powered"
            }
        } else {
            $cardResults += @{
                reader = $r
                card_inserted = $false
                atr = ""
                status = if ($connRet -eq -2146434967) { "No Card Inserted" } else { "Error: $connRet" }
            }
        }
    }

    [AegisFprNative]::SCardReleaseContext($hCtx) | Out-Null
    return @{
        success = $true
        readers = $cardResults
    }
}

# Start HTTP Listener
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$PORT/")
$listener.Prefixes.Add("http://localhost:$PORT/")
$listener.Start()

Write-Host "=========================================================" -ForegroundColor Green
Write-Host "  Emirates ID & AEGIS PRO 4 Hardware Diagnostic Bridge" -ForegroundColor White
Write-Host "  Listening on: http://127.0.0.1:$PORT/" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Green
Write-Host "  Ready to accept browser test requests. Press Ctrl+C to exit.`n" -ForegroundColor Gray

$htmlFilePath = Join-Path $PSScriptRoot "test-eid.html"

while ($listener.IsListening) {
    try {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        $urlPath = $request.Url.AbsolutePath

        # Handle CORS
        $response.AddHeader("Access-Control-Allow-Origin", "*")
        $response.AddHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        $response.AddHeader("Access-Control-Allow-Headers", "Content-Type, Range")
        $response.AddHeader("Access-Control-Allow-Private-Network", "true")

        if ($request.HttpMethod -eq "OPTIONS") {
            $response.StatusCode = 204
            $response.Close()
            continue
        }

        Write-Host "[$([DateTime]::Now.ToString('HH:mm:ss'))] $($request.HttpMethod) $urlPath" -ForegroundColor DarkCyan

        $jsonResponse = $null
        $contentType = "application/json; charset=utf-8"

        switch -Regex ($urlPath) {
            "^/$|^/index\.html$" {
                if (Test-Path $htmlFilePath) {
                    $bytes = [System.IO.File]::ReadAllBytes($htmlFilePath)
                    $response.ContentType = "text/html; charset=utf-8"
                    $response.ContentLength64 = $bytes.Length
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                    $response.Close()
                    continue
                } else {
                    $jsonResponse = @{ error = "test-eid.html not found on disk" }
                }
            }

            "^/api/led/on$" {
                [AegisFprNative]::LIVESCAN_Init() | Out-Null
                $ret = [AegisFprNative]::SetLedStatus(1)
                $jsonResponse = @{
                    success = ($ret -eq 1)
                    led = "ON"
                    ret = $ret
                    message = if ($ret -eq 1) { "Optical scanner LED turned ON" } else { "Failed to turn LED ON" }
                }
            }

            "^/api/led/off$" {
                $ret = [AegisFprNative]::SetLedStatus(0)
                [AegisFprNative]::LIVESCAN_Close() | Out-Null
                $jsonResponse = @{
                    success = ($ret -eq 1)
                    led = "OFF"
                    ret = $ret
                    message = if ($ret -eq 1) { "Optical scanner LED turned OFF" } else { "Failed to turn LED OFF" }
                }
            }

            "^/api/led/blink$" {
                [AegisFprNative]::LIVESCAN_Init() | Out-Null
                for ($b = 0; $b -lt 3; $b++) {
                    [AegisFprNative]::SetLedStatus(1) | Out-Null
                    Start-Sleep -Milliseconds 250
                    [AegisFprNative]::SetLedStatus(0) | Out-Null
                    Start-Sleep -Milliseconds 250
                }
                [AegisFprNative]::LIVESCAN_Close() | Out-Null
                $jsonResponse = @{
                    success = $true
                    led = "BLINK_COMPLETED"
                    message = "Optical scanner LED blinked 3 times successfully"
                }
            }

            "^/api/fingerprint/capture$" {
                [AegisFprNative]::LIVESCAN_Init() | Out-Null
                [AegisFprNative]::SetLedStatus(1) | Out-Null
                $beginRet = [AegisFprNative]::LIVESCAN_BeginCapture(0)
                
                $w = 300; $h = 400
                [AegisFprNative]::LIVESCAN_GetMaxImageSize(0, [ref]$w, [ref]$h) | Out-Null
                $bufSize = $w * $h
                $buf = New-Object byte[] $bufSize

                $capRet = [AegisFprNative]::LIVESCAN_GetFPRawData(0, $buf)
                [AegisFprNative]::LIVESCAN_EndCapture(0) | Out-Null
                [AegisFprNative]::SetLedStatus(0) | Out-Null
                [AegisFprNative]::LIVESCAN_Close() | Out-Null

                if ($capRet -eq 1) {
                    $dataUrl = Convert-RawToBmpBase64 $buf $w $h
                    $jsonResponse = @{
                        success = $true
                        width = $w
                        height = $h
                        image = $dataUrl
                        message = "Fingerprint captured successfully ($w x $h)"
                    }
                } else {
                    $jsonResponse = @{
                        success = $false
                        ret = $capRet
                        message = "Failed to capture fingerprint from optical sensor (code: $capRet)"
                    }
                }
            }

            "^/api/card/status$" {
                $jsonResponse = Get-SmartCardInfo
            }

            default {
                $response.StatusCode = 404
                $jsonResponse = @{ error = "Endpoint not found: $urlPath" }
            }
        }

        $jsonStr = $jsonResponse | ConvertTo-Json -Depth 5 -Compress
        $outBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonStr)
        $response.ContentType = $contentType
        $response.ContentLength64 = $outBytes.Length
        $response.OutputStream.Write($outBytes, 0, $outBytes.Length)
        $response.Close()
    } catch {
        Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    }
}

$listener.Stop()
