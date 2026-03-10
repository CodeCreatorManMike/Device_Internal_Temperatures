<#
.SYNOPSIS
  Collects temperature sensors on Lenovo Windows devices using LibreHardwareMonitorLib.dll.

.DESCRIPTION
  Lenovo does not expose a vendor-native WMI thermal API. The documented Lenovo WMI interface
  is for BIOS management (settings, boot order, passwords), not live temperature telemetry.
  Win32_TemperatureProbe is not real-time (SMBIOS-based; CurrentReading is typically not
  populated). MSAcpi_ThermalZoneTemperature can return zone temps on some systems but is
  firmware-defined and not reliable per-component. For per-component temps on Lenovo Windows,
  the practical path is Libre Hardware Monitor (LibreHardwareMonitorLib.dll).

  This script loads the DLL, enables CPU/GPU/Motherboard/Storage/Memory/Battery, recursively
  updates hardware, and returns every Temperature sensor with raw name and a normalized category.
  Sensor availability varies by model (ThinkPad/ThinkCentre/ThinkStation vs IdeaPad/Yoga).

  Run elevated when possible; some sensors require admin rights.

.NOTES
  - Requires LibreHardwareMonitorLib.dll from Libre Hardware Monitor (extract to a folder and pass -LibPath).
  - Do not use Lenovo BIOS WMI for live temps; it is not documented for thermal telemetry.
  - Battery temperature is opportunistic; not guaranteed across models.

.PARAMETER LibPath
  Full path to LibreHardwareMonitorLib.dll (required).

.PARAMETER AsJson
  Emit JSON instead of table. With -OutFile, write to file.

.PARAMETER OutFile
  With -AsJson, write JSON to this path.

.PARAMETER Diagnostic
  Show native ACPI thermal zones (root\wmi) and error report for troubleshooting.

.EXAMPLE
  .\Get-LenovoTemps.ps1 -LibPath 'C:\Tools\LibreHardwareMonitor\LibreHardwareMonitorLib.dll'

.EXAMPLE
  .\Get-LenovoTemps.ps1 -LibPath 'C:\Tools\LibreHardwareMonitor\LibreHardwareMonitorLib.dll' -AsJson -OutFile .\lenovo-temps.json

.EXAMPLE
  .\Get-LenovoTemps.ps1 -LibPath 'C:\Tools\LibreHardwareMonitor\LibreHardwareMonitorLib.dll' -Diagnostic
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$LibPath,
  [switch]$AsJson,
  [string]$OutFile,
  [switch]$Diagnostic
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Error reporting: identify why and where it failed
$scriptErrors = New-Object System.Collections.Generic.List[object]
function Add-ScriptError {
  param([string]$Step, [System.Exception]$Ex)
  if (-not $Ex) { return }
  $scriptErrors.Add([pscustomobject]@{
    Step          = $Step
    ExceptionType = $Ex.GetType().FullName
    Message       = $Ex.Message
    FullMessage   = $Ex.ToString()
  }) | Out-Null
}

$nowUtc = [DateTime]::UtcNow.ToString('o')
$computerName = $env:COMPUTERNAME

# Validate DLL path
if (-not (Test-Path -LiteralPath $LibPath)) {
  Write-Error "LibreHardwareMonitorLib.dll not found at: $LibPath. Download Libre Hardware Monitor and extract; pass -LibPath to the DLL."
  exit 1
}

# Load the library
try {
  Add-Type -Path $LibPath
} catch {
  Add-ScriptError -Step "Add-Type (load LibreHardwareMonitorLib)" -Ex $_.Exception
  Write-Error "Failed to load LibreHardwareMonitorLib.dll: $($_.Exception.Message)"
  exit 1
}

# Create computer and enable hardware groups (Lenovo-typical: CPU, GPU, Motherboard, Storage, Memory, Battery)
$computer = $null
try {
  $computer = [LibreHardwareMonitor.Hardware.Computer]::new()
  $computer.IsCpuEnabled = $true
  $computer.IsGpuEnabled = $true
  $computer.IsMemoryEnabled = $true
  $computer.IsMotherboardEnabled = $true
  $computer.IsStorageEnabled = $true
  $computer.IsNetworkEnabled = $false
  $computer.IsBatteryEnabled = $true
  $computer.Open()
} catch {
  Add-ScriptError -Step "Computer.Open()" -Ex $_.Exception
  Write-Error "Failed to open LibreHardwareMonitor computer: $($_.Exception.Message)"
  if ($Diagnostic -and $scriptErrors.Count -gt 0) {
    $scriptErrors | Format-Table -AutoSize Step, ExceptionType, Message -Wrap
  }
  exit 1
}

# Recursively update hardware so sensors have current values
function Update-HardwareRecursive {
  param([LibreHardwareMonitor.Hardware.IHardware]$Hardware)
  if (-not $Hardware) { return }
  try {
    $Hardware.Update()
  } catch {
    Add-ScriptError -Step "Update $($Hardware.Name)" -Ex $_.Exception
  }
  foreach ($sub in $Hardware.SubHardware) {
    Update-HardwareRecursive -Hardware $sub
  }
}

foreach ($hw in $computer.Hardware) {
  Update-HardwareRecursive -Hardware $hw
}

# Normalized category for cross-vendor reporting. Conservative: never rename away raw sensor name.
function Get-NormalizedTempCategory {
  param([string]$HardwareType, [string]$SensorName)
  $n = $SensorName.ToLowerInvariant()
  $ht = $HardwareType.ToLowerInvariant()

  if ($ht -match 'cpu') {
    if ($n -match 'package') { return 'CPU.Package' }
    if ($n -match 'core')    { return 'CPU.Core' }
    return 'CPU.Other'
  }
  if ($ht -match 'gpu') {
    if ($n -match 'hotspot')      { return 'GPU.Hotspot' }
    if ($n -match 'memory')       { return 'GPU.Memory' }
    if ($n -match 'junction')     { return 'GPU.Junction' }
    if ($n -match 'core|package') { return 'GPU.Core' }
    return 'GPU.Other'
  }
  if ($ht -match 'storage') { return 'Storage' }
  if ($ht -match 'battery') { return 'Battery' }
  if ($ht -match 'motherboard') {
    if ($n -match 'pch|chipset')  { return 'PCH' }
    if ($n -match 'vrm|mos')      { return 'VRM' }
    if ($n -match 'system|board') { return 'Board' }
    if ($n -match 'ambient')      { return 'Ambient' }
    return 'Motherboard.Other'
  }
  return 'Other'
}

# Collect temperature sensors only; preserve raw names
$results = New-Object System.Collections.Generic.List[object]
foreach ($hw in $computer.Hardware) {
  $nodeList = @($hw) + @($hw.SubHardware)
  foreach ($node in $nodeList) {
    if (-not $node.Sensors) { continue }
    foreach ($sensor in $node.Sensors) {
      if ($sensor.SensorType.ToString() -ne 'Temperature') { continue }
      if ($null -eq $sensor.Value) { continue }
      try {
        $results.Add([pscustomobject]@{
          ComputerName       = $computerName
          Vendor             = 'Lenovo'
          TimestampUtc       = $nowUtc
          HardwareName       = $node.Name
          HardwareType       = $node.HardwareType.ToString()
          SensorNameRaw      = $sensor.Name
          SensorIdentifier   = $sensor.Identifier.ToString()
          TemperatureC       = [Math]::Round([double]$sensor.Value, 1)
          MinC               = if ($null -ne $sensor.Min) { [Math]::Round([double]$sensor.Min, 1) } else { $null }
          MaxC               = if ($null -ne $sensor.Max) { [Math]::Round([double]$sensor.Max, 1) } else { $null }
          NormalizedCategory = Get-NormalizedTempCategory -HardwareType $node.HardwareType.ToString() -SensorName $sensor.Name
        })
      } catch {
        Add-ScriptError -Step "Collect sensor $($node.Name)/$($sensor.Name)" -Ex $_.Exception
      }
    }
  }
}

# Optional: native ACPI thermal zones (firmware-defined; not guaranteed per-component)
$nativeAcpi = @()
if ($Diagnostic) {
  try {
    $acpi = Get-CimInstance -Namespace 'root/wmi' -ClassName 'MSAcpi_ThermalZoneTemperature' -ErrorAction Stop
    foreach ($z in @($acpi)) {
      if ($z.PSObject.Properties.Name -contains 'CurrentTemperature' -and $null -ne $z.CurrentTemperature) {
        $tenthsK = [double]$z.CurrentTemperature
        $celsius = [Math]::Round(($tenthsK / 10.0) - 273.15, 1)
        $nativeAcpi += [pscustomobject]@{
          Source     = 'MSAcpi_ThermalZoneTemperature'
          InstanceName = $z.InstanceName
          TemperatureC = $celsius
          RawTenthsKelvin = $tenthsK
        }
      }
    }
  } catch {
    Add-ScriptError -Step "Get-CimInstance MSAcpi_ThermalZoneTemperature" -Ex $_.Exception
  }
}

# Output
$sorted = @($results | Sort-Object HardwareType, HardwareName, NormalizedCategory, SensorNameRaw)

if ($AsJson) {
  $payload = [pscustomobject]@{
    Timestamp    = $nowUtc
    ComputerName = $computerName
    Vendor       = 'Lenovo'
    Readings     = @($sorted)
    Errors       = @($scriptErrors)
    NativeAcpiZones = if ($Diagnostic) { @($nativeAcpi) } else { $null }
  }
  $json = $payload | ConvertTo-Json -Depth 5
  if ($OutFile) {
    try {
      $json | Out-File -FilePath $OutFile -Encoding utf8 -Force
      Write-Host "Wrote JSON to: $OutFile"
    } catch {
      Add-ScriptError -Step "Out-File $OutFile" -Ex $_.Exception
      Write-Warning "Failed to write $OutFile : $($_.Exception.Message)"
    }
  } else {
    $json
  }
} else {
  Write-Host "`n--- Lenovo temperature sensors (LibreHardwareMonitor) ---" -ForegroundColor Cyan
  Write-Host "  Computer: $computerName  |  Vendor: Lenovo  |  Sensors: $($sorted.Count)"
  Write-Host ""
  if ($sorted.Count -eq 0) {
    Write-Host "  No temperature sensors returned. Run elevated; ensure DLL path is correct; model may expose few sensors." -ForegroundColor Yellow
  } else {
    $sorted | Format-Table -AutoSize ComputerName, HardwareType, HardwareName, SensorNameRaw, NormalizedCategory, TemperatureC, MinC, MaxC -Wrap
  }
  if ($scriptErrors.Count -gt 0) {
    Write-Host "`n--- Error report ---" -ForegroundColor Red
    $scriptErrors | Format-Table -AutoSize Step, ExceptionType, Message -Wrap
  }
}

if ($Diagnostic) {
  Write-Host "`n--- Diagnostic ---" -ForegroundColor Cyan
  Write-Host "  LibreHardwareMonitor sensors (Temperature): $($sorted.Count)"
  if ($nativeAcpi.Count -gt 0) {
    Write-Host "  Native ACPI thermal zones (root\wmi MSAcpi_ThermalZoneTemperature):"
    $nativeAcpi | Format-Table -AutoSize Source, InstanceName, TemperatureC, RawTenthsKelvin
  } else {
    Write-Host "  Native ACPI thermal zones: none or not queried (Diagnostic ran but no zones returned)."
  }
  if ($scriptErrors.Count -gt 0) {
    Write-Host "`n  Error details:"
    $scriptErrors | ForEach-Object { Write-Host "    [$($_.Step)] $($_.Message)" }
  }
}

# ---------- Troubleshooting (comments) ----------
# No sensors returned:
#   - Run PowerShell as Administrator; some sensors require elevation.
#   - Confirm LibPath points to LibreHardwareMonitorLib.dll from an extracted Libre Hardware Monitor build.
#   - Lenovo IdeaPad/Yoga often expose fewer sensors than ThinkPad/ThinkCentre/ThinkStation.
# Only CPU shows up:
#   - Common on integrated-GPU or when EC/board sensors are not exposed by firmware.
# Battery temperature missing:
#   - Normal on many Lenovo Windows devices; Lenovo Vantage may show it on some models; no stable PowerShell API.
# Names vary by model:
#   - Keep SensorNameRaw; use NormalizedCategory for cross-vendor reporting only.
