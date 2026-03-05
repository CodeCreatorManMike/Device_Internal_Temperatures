<#
.SYNOPSIS
  Admin-only remediation: WMI repository health and Dell Command | Monitor (DCM) presence for Dell-native temperature telemetry.

.DESCRIPTION
  Run as Administrator. Ensures:
  1) WMI repository is consistent (verify -> salvage -> reset if needed).
  2) Dell Command | Monitor (not Dell Command | Update) is detected; if missing, instructs install from Dell Support.
  3) After fixes, validates that DCIM_* classes exist in root\dcim\sysman.

  Dell Command | Monitor is the Dell-supported component that exposes system health telemetry (including sensors) via DCIM_* classes.
  Dell Command | Update is for driver/BIOS updates and does NOT provide sensor/WMI provider support.

.EXAMPLE
  Run as Administrator: .\Repair-DellWmiAndDcm.ps1
#>

[CmdletBinding()]
param()

# ---------- Require elevation ----------
$isAdmin = $false
try {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {}

if (-not $isAdmin) {
  Write-Error "This script must be run as Administrator. Right-click PowerShell -> Run as administrator, then run this script."
  exit 1
}

$ns = "root\dcim\sysman"
$ErrorActionPreference = 'Stop'

Write-Host "`n========== Dell WMI & DCM Remediation (Admin) ==========" -ForegroundColor Cyan
Write-Host ""

# ---------- 1) WMI repository ----------
Write-Host "[1] WMI repository verification" -ForegroundColor Yellow
$verifyOut = & winmgmt /verifyrepository 2>&1 | Out-String
Write-Host $verifyOut

$wmiInconsistent = $verifyOut -match "WARN|inconsistent|corrupt|error" -or $LASTEXITCODE -ne 0
if ($wmiInconsistent) {
  Write-Host "    Repository reported issue. Attempting salvage..." -ForegroundColor Yellow
  $salvageOut = & winmgmt /salvagerepository 2>&1 | Out-String
  Write-Host $salvageOut
  $verify2 = & winmgmt /verifyrepository 2>&1 | Out-String
  Write-Host "    Re-verify after salvage:" -ForegroundColor Gray
  Write-Host $verify2
  $stillBad = $verify2 -match "WARN|inconsistent|corrupt|error"
  if ($stillBad) {
    Write-Host "    Still inconsistent. Attempting reset (destructive)..." -ForegroundColor Yellow
    $resetOut = & winmgmt /resetrepository 2>&1 | Out-String
    Write-Host $resetOut
    $verify3 = & winmgmt /verifyrepository 2>&1 | Out-String
    Write-Host "    Re-verify after reset:" -ForegroundColor Gray
    Write-Host $verify3
  }
} else {
  Write-Host "    WMI repository OK." -ForegroundColor Green
}

# ---------- 2) Dell Command | Monitor (not Update) ----------
Write-Host "`n[2] Dell Command | Monitor installation check" -ForegroundColor Yellow
Write-Host "    (Required for sensors. Dell Command | Update does NOT provide WMI/sensor support.)" -ForegroundColor Gray

$dcmFound = $false
$dcmDisplayName = $null
$dcmVersion = $null

try {
  $uninst = @(Get-ItemProperty "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue)
  $uninst64 = @(Get-ItemProperty "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue)
  $all = @($uninst + $uninst64)
  # Explicitly require "Monitor" and exclude "Update"
  $monitor = $all | Where-Object {
    $_.DisplayName -match "Dell Command\s*\|\s*Monitor|Command Monitor" -and
    $_.DisplayName -notmatch "Update|Configure"
  }
  if ($monitor) {
    $dcmFound = $true
    $dcmDisplayName = ($monitor | Select-Object -First 1).DisplayName
    $dcmVersion = ($monitor | Select-Object -First 1).DisplayVersion
  }
} catch {
  Write-Host "    Registry check error: $($_.Exception.Message)" -ForegroundColor Red
}

# Common install paths (optional evidence)
$dcmPaths = @(
  "${env:ProgramFiles}\Dell\Command Monitor",
  "${env:ProgramFiles(x86)}\Dell\Command Monitor"
)
foreach ($p in $dcmPaths) {
  if (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue) {
    $dcmFound = $true
    Write-Host "    Found path: $p" -ForegroundColor Green
  }
}

if ($dcmFound) {
  Write-Host "    Dell Command | Monitor is present. DisplayName: $dcmDisplayName  Version: $dcmVersion" -ForegroundColor Green
} else {
  Write-Host "    Dell Command | Monitor is NOT installed (no uninstall entry, no common paths)." -ForegroundColor Red
  Write-Host "    Required action: Install Dell Command | Monitor from Dell Support (product: Dell Command | Monitor)." -ForegroundColor Yellow
  Write-Host "    Do not rely on Dell Command | Update for temperature/sensor telemetry." -ForegroundColor Gray
}

# ---------- 3) DCIM_* classes validation ----------
Write-Host "`n[3] DCIM_* classes in root\dcim\sysman" -ForegroundColor Yellow
$dcimClasses = @()
try {
  $dcimClasses = @(Get-CimClass -Namespace $ns -ErrorAction Stop | Where-Object { $_.CimClassName -like "DCIM_*" })
} catch {
  Write-Host "    Error enumerating classes: $($_.Exception.Message)" -ForegroundColor Red
}

$dcimCount = $dcimClasses.Count
if ($dcimCount -gt 0) {
  Write-Host "    $dcimCount DCIM_* class(es) present. Provider is registered." -ForegroundColor Green
  $dcimClasses | Select-Object -First 20 -ExpandProperty CimClassName | ForEach-Object { Write-Host "      $_" }
  if ($dcimCount -gt 20) { Write-Host "      ... and $($dcimCount - 20) more" }
} else {
  Write-Host "    Zero DCIM_* classes in $ns." -ForegroundColor Red
  if (-not $dcmFound) {
    Write-Host "    This matches Dell Command | Monitor not being installed. Install DCM, then rerun this script." -ForegroundColor Yellow
  } else {
    Write-Host "    Provider install/registration failed OR unsupported exposure on this build." -ForegroundColor Yellow
    Write-Host "    Evidence: DCM appears installed but root\dcim\sysman has 0 DCIM_* classes." -ForegroundColor Gray
    Write-Host "    Try: restart WMI (Restart-Service winmgmt -Force), reboot, or reinstall Dell Command | Monitor." -ForegroundColor Gray
  }
}

Write-Host "`n========== End remediation check ==========" -ForegroundColor Cyan
