<#
.SYNOPSIS
  Collects hardware temperature readings from Dell laptops via Dell Command Monitor (DCIM) WMI.

.DESCRIPTION
  Uses the Dell Command Monitor WMI namespace root\dcim\sysman. Enumerates thermal-related
  classes (DCIM_ThermalSensor, DCIM_Temperature, DCIM_SystemThermal, etc.) and optionally
  DCIM_Fan. Does not assume component names; infers component only when sensor name clearly
  indicates it. Requires Dell Command | Monitor to be installed (not just the PowerShell
  Provider, which is for BIOS configuration).

  Supported models: Latitude, Precision, OptiPlex, XPS (model-dependent sensor set).

.PARAMETER AsJson
  Emit output as JSON instead of a formatted table.

.PARAMETER OutFile
  When used with -AsJson, write JSON to this file path.

.PARAMETER Diagnostic
  List DCIM thermal classes, enumerate namespace, and show raw first-instance data.

.PARAMETER IncludeFan
  Include DCIM_Fan instances in output (fan readings, not temperature).

.EXAMPLE
  .\Get-DellThermals.ps1

.EXAMPLE
  .\Get-DellThermals.ps1 -AsJson -OutFile .\dell-thermals.json

.EXAMPLE
  .\Get-DellThermals.ps1 -Diagnostic
#>

[CmdletBinding()]
param(
  [switch]$AsJson,
  [string]$OutFile,
  [switch]$Diagnostic,
  [switch]$IncludeFan
)

$ErrorActionPreference = 'Stop'
$DellNamespace = "root\dcim\sysman"

# --- Helpers ---

# Dell DCIM thermal sensors typically report CurrentReading in Celsius. Some WMI classes
# use tenths of Kelvin; we convert to Celsius when RawValue looks like Kelvin (e.g. 3000+).
function ConvertTo-CelsiusReading {
  param(
    [double]$RawValue,
    [string]$UnitsHint = $null
  )
  if ($null -eq $RawValue) { return $null }
  # If value looks like tenths of Kelvin (common 2500–3500 range), convert.
  if ($UnitsHint -eq "tenthsKelvin" -or ($RawValue -gt 500 -and $RawValue -lt 4000)) {
    return [Math]::Round(($RawValue / 10.0) - 273.15, 2)
  }
  return [Math]::Round([double]$RawValue, 2)
}

# Infer component only when sensor name clearly implies it (do not assume).
$componentKeywords = @{
  'CPU'     = @('CPU', 'PROC', 'CORE', 'PACKAGE', 'PROCESSOR')
  'GPU'     = @('GPU', 'GFX', 'GRAPHICS', 'DISCRETE', 'DISPLAY')
  'Ambient' = @('AMBIENT', 'INLET', 'INTAKE')
  'Memory'  = @('MEMORY', 'DIMM', 'RAM')
  'Storage' = @('STORAGE', 'SSD', 'NVME', 'DRIVE', 'DISK')
  'Chassis' = @('CHASSIS', 'SYSTEM', 'BOARD', 'MOTHERBOARD')
  'VRM'     = @('VRM', 'VOLTAGE', 'REGULATOR')
  'Battery' = @('BATTERY', 'BAT', 'BATT')
  'Fan'     = @('FAN', 'FAN ')
  'Thermal' = @('THERMAL', 'THERMAL DIODE', 'DIODE')
}

function Get-InferredComponent {
  param([string]$SensorName)
  if ([string]::IsNullOrWhiteSpace($SensorName)) { return $null }
  $upper = $SensorName.ToUpperInvariant()
  foreach ($key in $componentKeywords.Keys) {
    foreach ($kw in $componentKeywords[$key]) {
      if ($upper -like "*$kw*") { return $key }
    }
  }
  return $null
}

$now = (Get-Date).ToString("o")
$computer = $env:COMPUTERNAME
$results = New-Object System.Collections.Generic.List[object]
$diagnostics = New-Object System.Collections.Generic.List[object]

# ========== 1) Detect Dell ==========
$manufacturer = $null
try {
  $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
  $manufacturer = $cs.Manufacturer
} catch {
  $manufacturer = "Unknown"
}

$isDell = $manufacturer -match "Dell"
if (-not $isDell) {
  Write-Warning "Manufacturer is not Dell ($manufacturer). Dell Command Monitor (DCIM) is only available on Dell systems."
}

# ========== 2) Check namespace root\dcim\sysman exists ==========
$namespaceExists = $false
try {
  $null = Get-CimInstance -Namespace $DellNamespace -ClassName DCIM_ThermalSensor -ErrorAction Stop
  $namespaceExists = $true
} catch {
  try {
    $classes = Get-CimClass -Namespace $DellNamespace -ErrorAction Stop
    $namespaceExists = $null -ne $classes -and @($classes).Count -gt 0
  } catch {
    $namespaceExists = $false
  }
}

if (-not $namespaceExists) {
  Write-Warning "Dell Command Monitor namespace (root\dcim\sysman) not found. Install Dell Command | Monitor."
  $diagnostics.Add([pscustomobject]@{ Step = "Namespace"; Result = "Missing"; Detail = "root\dcim\sysman not available. Install Dell Command | Monitor." })
} else {
  $diagnostics.Add([pscustomobject]@{ Step = "Namespace"; Result = "OK"; Detail = "root\dcim\sysman available." })
}

# ========== 3) Enumerate thermal-related classes and collect readings ==========
# Known Dell DCIM thermal classes; we try each and add whatever the device exposes.
$thermalClassNames = @(
  "DCIM_ThermalSensor",
  "DCIM_Temperature",
  "DCIM_SystemThermal"
)

foreach ($className in $thermalClassNames) {
  try {
    $instances = Get-CimInstance -Namespace $DellNamespace -ClassName $className -ErrorAction Stop
    $count = @($instances).Count
    $added = 0
    foreach ($obj in $instances) {
      $sensorName = $null
      $tempC = $null
      $rawVal = $null
      $status = $null
      $health = $null

      # Property names vary by class; ElementName / Name, CurrentReading / CurrentValue / Reading, etc.
      if ($obj.PSObject.Properties.Name -contains "ElementName") { $sensorName = $obj.ElementName }
      elseif ($obj.PSObject.Properties.Name -contains "Name") { $sensorName = $obj.Name }
      elseif ($obj.PSObject.Properties.Name -contains "InstanceID") { $sensorName = $obj.InstanceID }

      if ($obj.PSObject.Properties.Name -contains "CurrentReading") {
        $rawVal = [double]$obj.CurrentReading
        $tempC = ConvertTo-CelsiusReading -RawValue $rawVal
      } elseif ($obj.PSObject.Properties.Name -contains "CurrentValue") {
        $rawVal = [double]$obj.CurrentValue
        $tempC = ConvertTo-CelsiusReading -RawValue $rawVal
      } elseif ($obj.PSObject.Properties.Name -contains "Reading") {
        $rawVal = [double]$obj.Reading
        $tempC = ConvertTo-CelsiusReading -RawValue $rawVal
      }

      if ($obj.PSObject.Properties.Name -contains "Status") { $status = $obj.Status }
      if ($obj.PSObject.Properties.Name -contains "HealthState") { $health = $obj.HealthState }

      if ($null -ne $tempC -or $null -ne $sensorName) {
        $results.Add([pscustomobject]@{
          Timestamp         = $now
          ComputerName      = $computer
          Source            = $className
          SensorName        = $sensorName
          Component         = (Get-InferredComponent -SensorName $sensorName)
          TemperatureC      = $tempC
          RawValue          = $rawVal
          Status            = $status
          Health            = $health
          Notes             = "Dell DCIM $className"
        })
        $added++
      }
    }
    $diagnostics.Add([pscustomobject]@{ Step = $className; Result = "OK"; Detail = "$count instance(s), $added reading(s)." })
  } catch {
    $diagnostics.Add([pscustomobject]@{ Step = $className; Result = "Skip"; Detail = $_.Exception.Message })
  }
}

# ========== 4) Optional: DCIM_Fan (fan sensors; may include temp or speed) ==========
if ($IncludeFan) {
  try {
    $fans = Get-CimInstance -Namespace $DellNamespace -ClassName DCIM_Fan -ErrorAction Stop
    foreach ($obj in $fans) {
      $sensorName = $null
      if ($obj.PSObject.Properties.Name -contains "ElementName") { $sensorName = $obj.ElementName }
      elseif ($obj.PSObject.Properties.Name -contains "Name") { $sensorName = $obj.Name }
      $speed = $null
      if ($obj.PSObject.Properties.Name -contains "CurrentReading") { $speed = $obj.CurrentReading }
      elseif ($obj.PSObject.Properties.Name -contains "DesiredSpeed") { $speed = $obj.DesiredSpeed }
      $results.Add([pscustomobject]@{
        Timestamp         = $now
        ComputerName      = $computer
        Source            = "DCIM_Fan"
        SensorName        = $sensorName
        Component         = "Fan"
        TemperatureC     = $null
        RawValue          = $speed
        Status            = if ($obj.PSObject.Properties.Name -contains "Status") { $obj.Status } else { $null }
        Health            = if ($obj.PSObject.Properties.Name -contains "HealthState") { $obj.HealthState } else { $null }
        Notes             = "Dell DCIM Fan (speed or state)"
      })
    }
    $diagnostics.Add([pscustomobject]@{ Step = "DCIM_Fan"; Result = "OK"; Detail = "$(@($fans).Count) fan(s)." })
  } catch {
    $diagnostics.Add([pscustomobject]@{ Step = "DCIM_Fan"; Result = "Skip"; Detail = $_.Exception.Message })
  }
}

# De-dupe by Source + SensorName + RawValue
$deduped = $results | Sort-Object Source, SensorName, RawValue -Unique
$uniqueSensors = $deduped | Where-Object { $null -ne $_.SensorName } | Select-Object -Property Source, SensorName, Component -Unique
$summary = [pscustomobject]@{
  Timestamp     = $now
  ComputerName  = $computer
  Manufacturer  = $manufacturer
  IsDell        = $isDell
  NamespaceOK   = $namespaceExists
  TotalReadings = $deduped.Count
  UniqueSensors = @($uniqueSensors)
  MappingNote   = "Component inferred only when SensorName contains CPU/GPU/Ambient/Memory/Storage/Chassis/VRM/Battery/Fan; otherwise null."
}

# --- Output ---
if ($AsJson) {
  $output = @{
    readings   = @($deduped)
    summary    = $summary
    diagnostic = @($diagnostics)
  }
  $json = $output | ConvertTo-Json -Depth 6
  if ($OutFile) {
    $json | Out-File -FilePath $OutFile -Encoding utf8
    Write-Host "JSON written to: $OutFile"
  } else {
    $json
  }
} else {
  Write-Host "`n--- Dell thermal sensors ---" -ForegroundColor Cyan
  Write-Host "  Manufacturer: $manufacturer  |  Namespace: $DellNamespace  |  OK: $namespaceExists"
  Write-Host ""

  if ($deduped.Count -eq 0) {
    Write-Host "  No temperature readings returned." -ForegroundColor Yellow
    Write-Host "  Ensure Dell Command | Monitor is installed. Run with -Diagnostic to list DCIM classes." -ForegroundColor Gray
  } else {
    $deduped | Sort-Object Source, SensorName | Format-Table -AutoSize Timestamp, ComputerName, Source, SensorName, Component, TemperatureC, RawValue, Status, Health -Wrap
  }

  Write-Host "`n--- Per-class status ---" -ForegroundColor Yellow
  $diagnostics | Format-Table -AutoSize Step, Result, Detail -Wrap

  Write-Host "`n--- Unique sensors and mapping ---" -ForegroundColor Cyan
  $uniqueSensors | Format-Table -AutoSize
  Write-Host $summary.MappingNote -ForegroundColor Gray
}

# ========== -Diagnostic: list thermal classes and show raw first instance ==========
if ($Diagnostic) {
  Write-Host "`n========== DIAGNOSTIC (Dell DCIM) ==========" -ForegroundColor Magenta
  Write-Host "  Manufacturer: $manufacturer"
  Write-Host "  Namespace: $DellNamespace"
  Write-Host ""

  Write-Host "[1] CimClasses in namespace containing Therm or Temp:" -ForegroundColor Cyan
  try {
    $allClasses = Get-CimClass -Namespace $DellNamespace -ErrorAction Stop
    $thermalClasses = $allClasses | Where-Object { $_.CimClassName -match "Therm|Temp|Fan" }
    if ($thermalClasses) {
      $thermalClasses | ForEach-Object { Write-Host "    $($_.CimClassName)" }
    } else {
      Write-Host "    (none or namespace not available)"
    }
  } catch {
    Write-Host "    Error: $($_.Exception.Message)"
  }

  Write-Host "`n[2] DCIM_ThermalSensor (first instance):" -ForegroundColor Cyan
  try {
    $one = Get-CimInstance -Namespace $DellNamespace -ClassName DCIM_ThermalSensor -ErrorAction Stop | Select-Object -First 1
    if ($one) {
      $one.PSObject.Properties | ForEach-Object { Write-Host "    $($_.Name) = $($_.Value)" }
    } else {
      Write-Host "    No instances."
    }
  } catch {
    Write-Host "    Error: $($_.Exception.Message)"
  }

  Write-Host "`n[3] DCIM_Temperature (first instance, if present):" -ForegroundColor Cyan
  try {
    $one = Get-CimInstance -Namespace $DellNamespace -ClassName DCIM_Temperature -ErrorAction Stop | Select-Object -First 1
    if ($one) {
      $one.PSObject.Properties | ForEach-Object { Write-Host "    $($_.Name) = $($_.Value)" }
    } else {
      Write-Host "    No instances."
    }
  } catch {
    Write-Host "    Error: $($_.Exception.Message)"
  }

  Write-Host "`n========== END DIAGNOSTIC ==========" -ForegroundColor Magenta
}

# ========== Quick manual commands ==========
# Check if Dell Command Monitor is available:
#   Get-CimClass -Namespace root\dcim\sysman
# List thermal-related classes:
#   Get-CimClass -Namespace root\dcim\sysman | Where-Object { $_.CimClassName -match "Therm|Temp" }
# Get thermal sensors:
#   Get-CimInstance -Namespace root\dcim\sysman -ClassName DCIM_ThermalSensor
#   Get-CimInstance -Namespace root\dcim\sysman -ClassName DCIM_Temperature
