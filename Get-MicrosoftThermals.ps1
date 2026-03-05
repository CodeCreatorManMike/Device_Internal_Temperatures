<#
.SYNOPSIS
  Enumerates thermal zone temperatures on Microsoft/Surface-class laptops using only native Windows APIs.

.DESCRIPTION
  Reads temperatures from:
  1) ROOT\WMI: MSAcpi_ThermalZoneTemperature (ACPI thermal zones)
  2) Win32_PerfFormattedData_Counters_ThermalZoneInformation (Thermal Zone Information perf counters)

  Does NOT use Win32_TemperatureProbe (SMBIOS-based; typically not real-time on most systems).
  Converts tenths-of-Kelvin to Celsius. Optionally infers component (CPU/GPU/Battery/etc.) only when
  zone name clearly indicates it; otherwise leaves inferredComponent null to avoid guessing.

.PARAMETER AsJson
  Emit output as JSON instead of a formatted table.

.PARAMETER OutFile
  When used with -AsJson, write JSON to this file path.

.PARAMETER Diagnostic
  Dump raw WMI and perf counter output (instance count, property names, first instance) so you can see exactly what this PC exposes.

.EXAMPLE
  .\Get-MicrosoftThermals.ps1

.EXAMPLE
  .\Get-MicrosoftThermals.ps1 -AsJson -OutFile .\thermals.json
#>

[CmdletBinding()]
param(
  [switch]$AsJson,
  [string]$OutFile,
  [switch]$Diagnostic
)

$ErrorActionPreference = 'Stop'

# --- Helpers ---

# Many Windows thermal readings are in tenths of Kelvin (K * 10).
# Formula: °C = (rawValue / 10) - 273.15
function Convert-TenthsKelvinToCelsius {
  param([double]$TenthsKelvin)
  return [Math]::Round(($TenthsKelvin / 10.0) - 273.15, 2)
}

# Only set inferredComponent when zone name strongly implies a known component.
# Avoids mislabeling generic zones (e.g. _TZ.TZ00) as CPU/GPU without evidence.
$componentKeywords = @{
  'CPU'  = @('CPU', 'PROC', 'CORE', 'PACKAGE')
  'GPU'  = @('GPU', 'GFX', 'GRAPHICS', 'DISCRETE')
  'SKIN' = @('SKIN', 'SURFACE', 'SKIN')
  'BAT'  = @('BAT', 'BATT', 'BATTERY')
  'CHG'  = @('CHG', 'CHARGER', 'CHARGING')
  'PCH'  = @('PCH', 'PLATFORM')
}

function Get-InferredComponent {
  param([string]$ZoneName)
  if ([string]::IsNullOrWhiteSpace($ZoneName)) { return $null }
  $upper = $ZoneName.ToUpperInvariant()
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

# Track why each source produced no (or few) readings; shown when output is empty or -Diagnostic
$diagWmiAcpi = $null
$diagPerfTzi = $null

# ========== 1) ACPI thermal zones via WMI (root/wmi) ==========
# MSAcpi_ThermalZoneTemperature is the WMI representation of ACPI thermal zone
# temperature. CurrentTemperature is in tenths of Kelvin when populated.
try {
  $acpi = Get-CimInstance -Namespace "root/wmi" -ClassName "MSAcpi_ThermalZoneTemperature" -ErrorAction Stop
  $acpiCount = @($acpi).Count
  $added = 0
  foreach ($z in $acpi) {
    $raw = $null
    if ($z.PSObject.Properties.Name -contains "CurrentTemperature") {
      $raw = [double]$z.CurrentTemperature
    }
    if ($null -ne $raw) {
      $zoneName = $z.InstanceName
      $celsius = Convert-TenthsKelvinToCelsius -TenthsKelvin $raw
      $results.Add([pscustomobject]@{
        Timestamp         = $now
        ComputerName      = $computer
        Source            = "WMI_ACPI"
        ZoneName          = $zoneName
        Celsius           = $celsius
        RawValue          = $raw
        RawUnits          = "tenthsKelvin"
        InferredComponent = (Get-InferredComponent -ZoneName $zoneName)
        Notes             = "ACPI thermal zone via root/wmi MSAcpi_ThermalZoneTemperature"
      })
      $added++
    }
  }
  $diagWmiAcpi = if ($added -eq 0) {
    "Query OK but no usable readings: $acpiCount instance(s); no CurrentTemperature or all null. (Dell/other OEMs often don't expose ACPI thermal zones.)"
  } else {
    "OK: $added reading(s) from $acpiCount instance(s)."
  }
} catch {
  $diagWmiAcpi = "Error: $($_.Exception.Message)"
  # Device may not expose ACPI thermal zones, or WMI provider not available.
  $results.Add([pscustomobject]@{
    Timestamp         = $now
    ComputerName      = $computer
    Source            = "WMI_ACPI"
    ZoneName          = $null
    Celsius           = $null
    RawValue          = $null
    RawUnits          = $null
    InferredComponent = $null
    Notes             = "Failed: $($_.Exception.Message)"
  })
}

# ========== 2) Thermal Zone Information (perf counters) ==========
# Win32_PerfFormattedData_Counters_ThermalZoneInformation exposes thermal zone
# instances (often _TZ.*). Temperature and HighPrecisionTemperature are typically
# tenths of Kelvin; we use whichever is available.
try {
  $tzi = Get-CimInstance -ClassName "Win32_PerfFormattedData_Counters_ThermalZoneInformation" -ErrorAction Stop
  $tziCount = @($tzi).Count
  $added = 0
  foreach ($row in $tzi) {
    $raw = $null
    if ($row.PSObject.Properties.Name -contains "Temperature") {
      $raw = [double]$row.Temperature
    }
    $hpt = $null
    if ($row.PSObject.Properties.Name -contains "HighPrecisionTemperature") {
      $hpt = [double]$row.HighPrecisionTemperature
    }

    $zoneName = $row.Name
    if ($null -ne $raw) {
      $celsius = Convert-TenthsKelvinToCelsius -TenthsKelvin $raw
      $results.Add([pscustomobject]@{
        Timestamp         = $now
        ComputerName      = $computer
        Source            = "PERF_TZI"
        ZoneName          = $zoneName
        Celsius           = $celsius
        RawValue          = $raw
        RawUnits          = "tenthsKelvin"
        InferredComponent = (Get-InferredComponent -ZoneName $zoneName)
        Notes             = "PerfFormattedData Counters_ThermalZoneInformation Temperature"
      })
      $added++
    }
    if ($null -ne $hpt -and $hpt -ne 0) {
      $celsiusHpt = Convert-TenthsKelvinToCelsius -TenthsKelvin $hpt
      $results.Add([pscustomobject]@{
        Timestamp         = $now
        ComputerName      = $computer
        Source            = "PERF_TZI"
        ZoneName          = $zoneName
        Celsius           = $celsiusHpt
        RawValue          = $hpt
        RawUnits          = "tenthsKelvin"
        InferredComponent = (Get-InferredComponent -ZoneName $zoneName)
        Notes             = "PerfFormattedData Counters_ThermalZoneInformation HighPrecisionTemperature"
      })
      $added++
    }
  }
  $diagPerfTzi = if ($added -eq 0) {
    "Query OK but no usable readings: $tziCount instance(s); no Temperature/HighPrecisionTemperature or all zero. (Thermal Zone perf counters often absent on non-Surface OEMs.)"
  } else {
    "OK: $added reading(s) from $tziCount instance(s)."
  }
} catch {
  $diagPerfTzi = "Error: $($_.Exception.Message)"
  $results.Add([pscustomobject]@{
    Timestamp         = $now
    ComputerName      = $computer
    Source            = "PERF_TZI"
    ZoneName          = $null
    Celsius           = $null
    RawValue          = $null
    RawUnits          = $null
    InferredComponent = $null
    Notes             = "Failed: $($_.Exception.Message)"
  })
}

# De-dupe: same source + zone + raw value at same timestamp (e.g. Temperature vs HighPrecisionTemperature overlap)
$deduped = $results | Sort-Object Source, ZoneName, RawValue -Unique

# --- Summary: unique zones and mapping rationale ---
$uniqueZones = $deduped | Where-Object { $null -ne $_.ZoneName } | Select-Object -Property Source, ZoneName, InferredComponent -Unique
$summary = [pscustomobject]@{
  Timestamp     = $now
  ComputerName  = $computer
  TotalReadings = $deduped.Count
  UniqueZones   = @($uniqueZones)
  MappingNote   = "InferredComponent set only when ZoneName contains CPU/GFX/GPU/SKIN/BAT/CHG/PCH (or variants); otherwise null."
}

# --- Output ---
$hasUsableReadings = ($deduped | Where-Object { $null -ne $_.Celsius }).Count -gt 0

if ($AsJson) {
  $output = @{
    readings   = @($deduped)
    summary    = $summary
    diagnostic = @{ WMI_ACPI = $diagWmiAcpi; PERF_TZI = $diagPerfTzi }
  }
  $json = $output | ConvertTo-Json -Depth 6
  if ($OutFile) {
    $json | Out-File -FilePath $OutFile -Encoding utf8
    Write-Host "JSON written to: $OutFile"
  } else {
    $json
  }
} else {
  Write-Host "`n--- Thermal zone readings ---" -ForegroundColor Cyan
  $deduped | Sort-Object Source, ZoneName | Format-Table -AutoSize Timestamp, ComputerName, Source, ZoneName, Celsius, RawValue, InferredComponent, Notes -Wrap

  # Always show why each source did or didn't return data (so empty output is explained)
  Write-Host "`n--- Why this result? (per-source) ---" -ForegroundColor Yellow
  Write-Host "  WMI_ACPI (root/wmi MSAcpi_ThermalZoneTemperature): $diagWmiAcpi"
  Write-Host "  PERF_TZI (Thermal Zone Information perf counters):  $diagPerfTzi"
  if (-not $hasUsableReadings) {
    Write-Host "`n  This PC does not expose thermal zones via these APIs (common on Dell/HP/Lenovo)." -ForegroundColor Gray
    Write-Host "  Surface/Microsoft devices more often do. Use -Diagnostic to see raw WMI/perf output." -ForegroundColor Gray
  }

  Write-Host "`n--- Summary: unique zones and mapping ---" -ForegroundColor Cyan
  $uniqueZones | Format-Table -AutoSize
  Write-Host $summary.MappingNote -ForegroundColor Gray
}

# ========== -Diagnostic: dump raw WMI and perf output ==========
if ($Diagnostic) {
  Write-Host "`n========== DIAGNOSTIC (raw data from this PC) ==========" -ForegroundColor Magenta
  Write-Host "`n[1] root/wmi MSAcpi_ThermalZoneTemperature" -ForegroundColor Cyan
  $rawAcpi = $null
  try {
    $rawAcpi = Get-CimInstance -Namespace "root/wmi" -ClassName "MSAcpi_ThermalZoneTemperature" -ErrorAction SilentlyContinue
  } catch {}
  if (-not $rawAcpi -or @($rawAcpi).Count -eq 0) {
    Write-Host "  Instances: 0 (or class not available)"
  } else {
    $first = @($rawAcpi)[0]
    Write-Host "  Instances: $(@($rawAcpi).Count)"
    Write-Host "  Property names: $(($first.PSObject.Properties.Name) -join ', ')"
    Write-Host "  First instance:"
    $first.PSObject.Properties | ForEach-Object { Write-Host "    $($_.Name) = $($_.Value)" }
  }
  Write-Host "`n[2] Win32_PerfFormattedData_Counters_ThermalZoneInformation" -ForegroundColor Cyan
  $rawTzi = $null
  try {
    $rawTzi = Get-CimInstance -ClassName "Win32_PerfFormattedData_Counters_ThermalZoneInformation" -ErrorAction SilentlyContinue
  } catch {}
  if (-not $rawTzi -or @($rawTzi).Count -eq 0) {
    Write-Host "  Instances: 0 (or class not available)"
  } else {
    $first = @($rawTzi)[0]
    Write-Host "  Instances: $(@($rawTzi).Count)"
    Write-Host "  Property names: $(($first.PSObject.Properties.Name) -join ', ')"
    Write-Host "  First instance:"
    $first.PSObject.Properties | ForEach-Object { Write-Host "    $($_.Name) = $($_.Value)" }
  }
  Write-Host "`n========== END DIAGNOSTIC ==========" -ForegroundColor Magenta
}

# ========== Quick manual commands (for troubleshooting) ==========
# List ACPI thermal zones (if exposed):
#   Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature | Select-Object InstanceName, CurrentTemperature
# List Thermal Zone Information perf instances:
#   Get-CimInstance -ClassName Win32_PerfFormattedData_Counters_ThermalZoneInformation | Select-Object Name, Temperature, HighPrecisionTemperature
