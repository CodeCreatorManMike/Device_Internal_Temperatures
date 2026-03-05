<#
.SYNOPSIS
  Dell Thermal Telemetry Diagnostic (no 3rd-party libs)

.DESCRIPTION
  This script gathers everything needed to determine WHY Dell temperature telemetry
  (Dell Command | Monitor / DCIM WMI) is not working on a given device.

  It does NOT require Dell Command | Monitor to run.
  It will:
    - Identify manufacturer/model/OS
    - Detect whether Dell Command | Monitor is installed (registry + file paths)
    - Enumerate root\dcim namespaces and class counts
    - Check whether DCIM_* classes exist in root\dcim\sysman (and other child namespaces)
    - Check if DCIM_NumericSensor exists anywhere and whether SensorType=2 (Temperature) instances exist
    - Capture WMI repository health status (verifyrepository)
    - Capture key WMI service status
    - Produce a human-readable summary and optionally JSON output

.USAGE
  .\Diagnose-DellThermals.ps1
  .\Diagnose-DellThermals.ps1 -OutJson .\dell-thermal-diagnostic.json
  .\Diagnose-DellThermals.ps1 -Verbose

.NOTES
  Run PowerShell as Administrator for best results (some checks may be restricted otherwise).
#>

[CmdletBinding()]
param(
  [string]$OutJson
)

# -----------------------------
# Helpers
# -----------------------------
function New-ResultObject {
  param(
    [string]$Step,
    [string]$Result,
    [string]$Detail
  )
  [pscustomobject]@{ Step = $Step; Result = $Result; Detail = $Detail }
}

function Safe-Run {
  param(
    [string]$Name,
    [scriptblock]$ScriptBlock
  )
  try {
    & $ScriptBlock
  } catch {
    Write-Verbose "[$Name] Error: $($_.Exception.Message)"
    return $null
  }
}

function Is-Admin {
  try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch { return $false }
}

function Get-UninstallEntries {
  $paths = @(
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
  )
  $items = foreach ($p in $paths) {
    Safe-Run "Registry:$p" { Get-ItemProperty $p -ErrorAction Stop }
  }
  $items | Where-Object { $_ -ne $null }
}

function Get-RootNamespaces {
  param([string]$RootNs)

  Safe-Run "Namespaces:$RootNs" {
    Get-CimInstance -Namespace $RootNs -ClassName __Namespace -ErrorAction Stop |
      Select-Object -ExpandProperty Name
  }
}

function Get-ClassNames {
  param([string]$Ns)

  Safe-Run "Classes:$Ns" {
    Get-CimClass -Namespace $Ns -ErrorAction Stop |
      Select-Object -ExpandProperty CimClassName
  }
}

function Get-DcimClassNames {
  param([string]$Ns)

  $names = Get-ClassNames -Ns $Ns
  if (-not $names) { return @() }
  $names | Where-Object { $_ -match '^DCIM_' } | Sort-Object
}

function Test-ClassExists {
  param(
    [string]$Ns,
    [string]$ClassName
  )
  $cls = Safe-Run "TestClass:$Ns\$ClassName" {
    Get-CimClass -Namespace $Ns -ClassName $ClassName -ErrorAction Stop
  }
  return ($null -ne $cls)
}

function Get-CimInstancesSafe {
  param(
    [string]$Ns,
    [string]$ClassName
  )
  Safe-Run "Instances:$Ns\$ClassName" {
    Get-CimInstance -Namespace $Ns -ClassName $ClassName -ErrorAction Stop
  }
}

function Run-Cmd {
  param([string]$CommandLine)
  Safe-Run "cmd:$CommandLine" {
    & cmd.exe /c $CommandLine 2>&1 | Out-String
  }
}

# -----------------------------
# Start collection
# -----------------------------
$timestamp = (Get-Date).ToString("o")
$admin = Is-Admin

$summaryRows = New-Object System.Collections.Generic.List[object]
$data = [ordered]@{
  Timestamp = $timestamp
  IsAdmin   = $admin
  System    = [ordered]@{}
  DellTools = [ordered]@{}
  Wmi       = [ordered]@{}
  Dcim      = [ordered]@{}
  Findings  = @()
}

# -----------------------------
# System Identity
# -----------------------------
$cs = Safe-Run "Win32_ComputerSystem" { Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop }
$bios = Safe-Run "Win32_BIOS" { Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop }
$os = Safe-Run "Win32_OperatingSystem" { Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop }
$baseboard = Safe-Run "Win32_BaseBoard" { Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction Stop }

$manufacturer = $cs.Manufacturer
$model = $cs.Model
$systemSku = $cs.SystemSKUNumber
$serial = $bios.SerialNumber

$data.System.Manufacturer = $manufacturer
$data.System.Model = $model
$data.System.SystemSku = $systemSku
$data.System.SerialNumber = $serial
$data.System.BIOSVersion = ($bios.SMBIOSBIOSVersion)
$data.System.OSCaption = $os.Caption
$data.System.OSVersion = $os.Version
$data.System.BuildNumber = $os.BuildNumber
$data.System.Architecture = $os.OSArchitecture
$data.System.BaseBoard = $baseboard.Product

if ($manufacturer -match "Dell") {
  $summaryRows.Add((New-ResultObject -Step "Manufacturer" -Result "OK" -Detail $manufacturer))
} else {
  $summaryRows.Add((New-ResultObject -Step "Manufacturer" -Result "WARN" -Detail "Not Dell (reported: $manufacturer). DCIM telemetry is Dell-specific."))
}

# -----------------------------
# WMI health / services
# -----------------------------
$winmgmt = Safe-Run "Service:winmgmt" { Get-Service -Name winmgmt -ErrorAction Stop }
$data.Wmi.WinmgmtStatus = if ($winmgmt) { $winmgmt.Status.ToString() } else { "Unknown" }

$repoVerify = Run-Cmd "winmgmt /verifyrepository"
$data.Wmi.RepositoryVerify = $repoVerify

if ($repoVerify -and $repoVerify -match "WMI repository is consistent") {
  $summaryRows.Add((New-ResultObject -Step "WMI Repository" -Result "OK" -Detail "Repository is consistent"))
} elseif ($repoVerify) {
  $summaryRows.Add((New-ResultObject -Step "WMI Repository" -Result "WARN" -Detail ($repoVerify.Trim())))
} else {
  $summaryRows.Add((New-ResultObject -Step "WMI Repository" -Result "WARN" -Detail "Could not run winmgmt /verifyrepository"))
}

# -----------------------------
# Detect Dell Command | Monitor install
# -----------------------------
$uninstall = Get-UninstallEntries

$monitorMatches = $uninstall | Where-Object {
  ($_.DisplayName -match 'Dell Command\s*\|\s*Monitor') -or
  ($_.DisplayName -match 'Dell Command Monitor') -or
  ($_.DisplayName -match 'Dell Client Management Service') -or
  ($_.DisplayName -match 'Dell Client Management Pack') -or
  ($_.DisplayName -match 'Command\s*\|\s*Monitor')
}

$data.DellTools.UninstallMatches = @(
  $monitorMatches | Select-Object DisplayName, DisplayVersion, Publisher, InstallDate
)

# Common install locations (best-effort; varies by version)
$possiblePaths = @(
  "$env:ProgramFiles\Dell\CommandMonitor",
  "$env:ProgramFiles\Dell\Command Monitor",
  "$env:ProgramFiles(x86)\Dell\CommandMonitor",
  "$env:ProgramFiles(x86)\Dell\Command Monitor",
  "$env:ProgramData\Dell\CommandMonitor",
  "$env:ProgramData\Dell\Command Monitor"
)

$existingPaths = @()
foreach ($p in $possiblePaths) {
  if (Test-Path $p) { $existingPaths += $p }
}
$data.DellTools.PossibleInstallPathsFound = $existingPaths

if ($monitorMatches -and $monitorMatches.Count -gt 0) {
  $summaryRows.Add((New-ResultObject -Step "Dell Command | Monitor Installed" -Result "OK" -Detail (($monitorMatches | Select-Object -First 1).DisplayName + " " + (($monitorMatches | Select-Object -First 1).DisplayVersion))))
} else {
  $summaryRows.Add((New-ResultObject -Step "Dell Command | Monitor Installed" -Result "WARN" -Detail "No uninstall entry found for Dell Command | Monitor (may be missing or installed under unexpected name)."))
}

if ($existingPaths.Count -gt 0) {
  $summaryRows.Add((New-ResultObject -Step "Dell Monitor Files" -Result "OK" -Detail ("Found paths: " + ($existingPaths -join ", "))))
} else {
  $summaryRows.Add((New-ResultObject -Step "Dell Monitor Files" -Result "WARN" -Detail "No common Dell Command | Monitor install folders found."))
}

# -----------------------------
# DCIM namespace discovery
# -----------------------------
$dcimChildren = Get-RootNamespaces -RootNs "root\dcim"
$data.Dcim.RootChildren = $dcimChildren

if (-not $dcimChildren) {
  $summaryRows.Add((New-ResultObject -Step "root\\dcim children" -Result "WARN" -Detail "Could not enumerate root\\dcim namespaces (root\\dcim missing or access issue)."))
  $dcimChildren = @()
} else {
  $summaryRows.Add((New-ResultObject -Step "root\\dcim children" -Result "OK" -Detail ($dcimChildren -join ", ")))
}

# Always include sysman if present; otherwise still test it explicitly (as your output shows it exists)
$nsCandidates = New-Object System.Collections.Generic.List[string]
foreach ($c in $dcimChildren) { $nsCandidates.Add("root\dcim\$c") }
if (-not ($nsCandidates -contains "root\dcim\sysman")) { $nsCandidates.Add("root\dcim\sysman") }

$data.Dcim.NamespacesChecked = @($nsCandidates)

# For each candidate namespace, count classes and list DCIM_*
$nsReports = @()
foreach ($ns in $nsCandidates) {
  $allClasses = Get-ClassNames -Ns $ns
  $dcimClasses = @()
  if ($allClasses) {
    $dcimClasses = $allClasses | Where-Object { $_ -match '^DCIM_' } | Sort-Object
  }

  $nsReports += [pscustomobject]@{
    Namespace        = $ns
    TotalClassCount  = if ($allClasses) { $allClasses.Count } else { 0 }
    DcimClassCount   = if ($dcimClasses) { $dcimClasses.Count } else { 0 }
    DcimClassesTop30 = @($dcimClasses | Select-Object -First 30)
  }
}
$data.Dcim.NamespaceReports = $nsReports

# Highlight sysman specifically
$sysmanReport = $nsReports | Where-Object { $_.Namespace -eq "root\dcim\sysman" } | Select-Object -First 1
if ($sysmanReport) {
  if ($sysmanReport.DcimClassCount -gt 0) {
    $summaryRows.Add((New-ResultObject -Step "DCIM classes in root\\dcim\\sysman" -Result "OK" -Detail ("Count=" + $sysmanReport.DcimClassCount)))
  } else {
    $summaryRows.Add((New-ResultObject -Step "DCIM classes in root\\dcim\\sysman" -Result "FAIL" -Detail "0 DCIM_* classes present (namespace stub or missing/broken provider)."))
  }
}

# -----------------------------
# Try to locate DCIM_NumericSensor anywhere and enumerate temperature instances
# -----------------------------
$numericSensorFound = $false
$tempInstancesTotal = 0
$numericSensorLocations = @()

foreach ($ns in $nsCandidates) {
  if (Test-ClassExists -Ns $ns -ClassName "DCIM_NumericSensor") {
    $numericSensorFound = $true
    $numericSensorLocations += $ns

    $instances = Get-CimInstancesSafe -Ns $ns -ClassName "DCIM_NumericSensor"
    if ($instances) {
      # Dell convention: SensorType==2 indicates temperature (per Dell docs)
      $temp = $instances | Where-Object { $_.PSObject.Properties.Name -contains "SensorType" -and $_.SensorType -eq 2 }
      $tempInstancesTotal += ($temp | Measure-Object).Count

      # Keep a small sample to help debugging
      $sample = $temp | Select-Object -First 5 *  # full props for first few
      $data.Dcim.TempSensorSamples = @($sample)
    } else {
      $data.Dcim.TempSensorSamples = @()
    }
  }
}

$data.Dcim.DCIM_NumericSensorFound = $numericSensorFound
$data.Dcim.DCIM_NumericSensorNamespaces = $numericSensorLocations
$data.Dcim.TemperatureInstanceCount = $tempInstancesTotal

if ($numericSensorFound) {
  $summaryRows.Add((New-ResultObject -Step "DCIM_NumericSensor" -Result "OK" -Detail ("Found in: " + ($numericSensorLocations -join ", "))))
  if ($tempInstancesTotal -gt 0) {
    $summaryRows.Add((New-ResultObject -Step "Temperature sensors" -Result "OK" -Detail ("SensorType=2 instances: $tempInstancesTotal")))
  } else {
    $summaryRows.Add((New-ResultObject -Step "Temperature sensors" -Result "WARN" -Detail "DCIM_NumericSensor exists but returned 0 SensorType=2 instances (no temp sensors exposed on this model/SKU or restricted)."))
  }
} else {
  $summaryRows.Add((New-ResultObject -Step "DCIM_NumericSensor" -Result "FAIL" -Detail "Not found in any checked root\\dcim namespaces."))
}

# -----------------------------
# Findings / next-step guidance (computed)
# -----------------------------
$findings = New-Object System.Collections.Generic.List[string]

if ($manufacturer -notmatch "Dell") {
  $findings.Add("This machine is not reporting Manufacturer= Dell. Do not expect Dell DCIM WMI telemetry.")
}

if ($sysmanReport -and $sysmanReport.TotalClassCount -eq 0) {
  $findings.Add("root\\dcim\\sysman is present but returns 0 classes. This usually indicates a namespace stub without a registered provider, or a WMI/provider registration failure.")
}

if ($sysmanReport -and $sysmanReport.DcimClassCount -eq 0 -and ($monitorMatches.Count -eq 0)) {
  $findings.Add("Dell Command | Monitor does not appear installed AND no DCIM classes exist. Install Dell Command | Monitor on this endpoint, then re-run.")
}

if ($sysmanReport -and $sysmanReport.DcimClassCount -eq 0 -and ($monitorMatches.Count -gt 0)) {
  $findings.Add("Dell Command | Monitor appears installed, but DCIM classes are missing. This points to broken provider registration or unsupported model/SKU. Repair/reinstall Dell Command | Monitor, then re-run. If still empty, the model may not expose telemetry via DCM.")
}

if (-not $numericSensorFound) {
  $findings.Add("DCIM_NumericSensor was not found anywhere. Without it (or an equivalent Dell sensor class), you cannot retrieve temperatures via Dell-native WMI on this device.")
}

if ($numericSensorFound -and $tempInstancesTotal -eq 0) {
  $findings.Add("DCIM_NumericSensor exists but exposes no temperature instances (SensorType=2). This can be normal on some models/SKUs or BIOS configurations.")
}

$data.Findings = @($findings)

# -----------------------------
# Output (console)
# -----------------------------
Write-Host ""
Write-Host "--- Dell Thermal Telemetry Diagnostic ---"
Write-Host "Timestamp: $timestamp"
Write-Host "Admin: $admin"
Write-Host ""

Write-Host ("Manufacturer: {0} | Model: {1} | SKU: {2} | Serial: {3}" -f $manufacturer, $model, $systemSku, $serial)
Write-Host ("OS: {0} | Version: {1} | Build: {2} | Arch: {3}" -f $os.Caption, $os.Version, $os.BuildNumber, $os.OSArchitecture)
Write-Host ""

Write-Host "--- Summary ---"
$summaryRows | Format-Table -AutoSize

Write-Host ""
Write-Host "--- DCIM Namespace Reports (top-level) ---"
$data.Dcim.NamespaceReports |
  Select-Object Namespace, TotalClassCount, DcimClassCount |
  Format-Table -AutoSize

Write-Host ""
Write-Host "--- Findings ---"
if ($findings.Count -eq 0) {
  Write-Host "No findings generated (unexpected). Review the JSON output."
} else {
  foreach ($f in $findings) { Write-Host ("- " + $f) }
}

Write-Host ""
Write-Host "--- Next steps (based on findings) ---"
if ($monitorMatches.Count -eq 0) {
  Write-Host "- Dell Command | Monitor not detected: install it, then re-run this script."
} else {
  Write-Host "- Dell Command | Monitor detected: if DCIM classes are missing, repair/reinstall it, then re-run."
}
if ($repoVerify -and $repoVerify -notmatch "consistent") {
  Write-Host "- WMI repository did not verify as consistent; investigate WMI health (verify/repair) before expecting 3rd-party providers to load."
}
Write-Host "- If DCIM classes never appear after reinstall and WMI health is OK, this model/SKU likely does not expose temperature telemetry via Dell-native WMI."

# -----------------------------
# Optional JSON output
# -----------------------------
if ($OutJson) {
  try {
    $json = $data | ConvertTo-Json -Depth 8
    $json | Out-File -FilePath $OutJson -Encoding utf8
    Write-Host ""
    Write-Host "Wrote JSON diagnostic to: $OutJson"
  } catch {
    Write-Host ""
    Write-Host "Failed to write JSON output: $($_.Exception.Message)"
  }
}
