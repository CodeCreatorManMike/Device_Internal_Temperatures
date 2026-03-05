<#
.SYNOPSIS
  Collects Dell-native temperature telemetry via Dell Command | Monitor (DCM) WMI — no third-party sensor libraries.

.DESCRIPTION
  Works only when DCIM_* classes exist in root\dcim\sysman (Dell Command | Monitor installed and registered).
  Discovery-first: enumerates DCIM_* classes, selects sensor candidates (NumericSensor|Sensor|Therm|Temp|Thermal|Fan),
  queries instances and normalizes temperature readings (e.g. DCIM_NumericSensor SensorType=2, CurrentReading + UnitModifier).
  Does NOT use Win32_TemperatureProbe or ACPI thermal zones. Requires Dell Command | Monitor (not Dell Command | Update; Update does not provide sensor/WMI support).
  If root\dcim\sysman has zero DCIM_* classes: reports "Dell provider not installed/registered" and instructs to install DCM.
  If provider present but no temps: reports "model/SKU/BIOS not exposing temperature sensors" with discovery evidence.
  For WMI repository repair and DCM validation, run as Admin: .\Repair-DellWmiAndDcm.ps1

.PARAMETER AsJson
  Emit output as JSON (includes vendor, namespace, className, sensorName, component, temperatureC, rawValue, unitsScaling, status/health).

.PARAMETER OutFile
  With -AsJson, write JSON to this file path.

.PARAMETER Diagnostic
  Namespace/class inventory, DCM vs Update check, first instance raw properties per sensor candidate class, errors with actionable reasons.

.EXAMPLE
  .\Get-DellTemps.ps1

.EXAMPLE
  .\Get-DellTemps.ps1 -AsJson -OutFile .\dell-temps.json

.EXAMPLE
  .\Get-DellTemps.ps1 -Diagnostic
#>

[CmdletBinding()]
param(
  [switch]$AsJson,
  [string]$OutFile,
  [switch]$Diagnostic
)

$ErrorActionPreference = 'Stop'

# --- Error reporting: collect failures so you can identify exactly why something failed ---
$scriptErrors = New-Object System.Collections.Generic.List[object]

function Add-ScriptError {
  param([string]$Step, [System.Exception]$Exception)
  if (-not $Exception) { return }
  $scriptErrors.Add([pscustomobject]@{
    Step          = $Step
    ExceptionType = $Exception.GetType().FullName
    Message       = $Exception.Message
    FullMessage   = $Exception.ToString()
  }) | Out-Null
}

# --- Helpers ---

# Dell reference: scale = BaseUnits * 10^UnitModifier
function Get-ScaledValue {
  param([object]$Reading, [object]$UnitModifier)
  if ($null -eq $Reading) { return $null }
  if ($null -eq $UnitModifier) { return [double]$Reading }
  return [double]$Reading * [Math]::Pow(10, [double]$UnitModifier)
}

# Component only when sensor name clearly contains one of these (case-insensitive); otherwise $null
$componentKeywords = @(
  'CPU', 'GPU', 'Ambient', 'Memory', 'Storage', 'Chassis', 'VRM', 'Battery', 'Fan'
)
function Get-InferredComponent {
  param([string]$SensorName)
  if ([string]::IsNullOrWhiteSpace($SensorName)) { return $null }
  $upper = $SensorName.ToUpperInvariant()
  foreach ($kw in $componentKeywords) {
    if ($upper -like "*$($kw.ToUpperInvariant())*") { return $kw }
  }
  return $null
}

function Test-NamespaceExists {
  param([string]$Namespace)
  try {
    $null = Get-CimClass -Namespace $Namespace -ClassName "__Namespace" -ErrorAction Stop
    return $true
  } catch {
    return $false
  }
}

$now = (Get-Date).ToString("o")
$computer = $env:COMPUTERNAME
$results = New-Object System.Collections.Generic.List[object]
$discovery = New-Object System.Collections.Generic.List[object]

# ========== 1) Manufacturer ==========
$manufacturer = "Unknown"
try {
  $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
  $manufacturer = $cs.Manufacturer
} catch {
  Add-ScriptError -Step "Win32_ComputerSystem (manufacturer)" -Exception $_.Exception
}
$isDell = $manufacturer -match "Dell"
if (-not $isDell) {
  Write-Warning "Manufacturer is not Dell ($manufacturer). Dell Command | Monitor is only available on Dell systems."
}

# ========== 2) Discover Dell WMI namespaces ==========
$dcimNamespaces = @()
try {
  $children = Get-CimInstance -Namespace "root\dcim" -ClassName "__Namespace" -ErrorAction Stop
  $dcimNamespaces = @($children | Select-Object -ExpandProperty Name)
} catch {
  Add-ScriptError -Step "root\dcim __Namespace" -Exception $_.Exception
  $discovery.Add([pscustomobject]@{ Step = "root\dcim"; Result = "Missing or error"; Detail = $_.Exception.Message })
}

if ($dcimNamespaces.Count -eq 0 -and $discovery.Count -eq 0) {
  $discovery.Add([pscustomobject]@{ Step = "root\dcim"; Result = "No child namespaces"; Detail = "root\dcim has no __Namespace children or namespace does not exist." })
}

# Primary namespace Dell documents for sensors
$ns = "root\dcim\sysman"
$namespaceExists = Test-NamespaceExists -Namespace $ns
if (-not $namespaceExists) {
  $discovery.Add([pscustomobject]@{ Step = "Namespace $ns"; Result = "Missing"; Detail = "Install Dell Command | Monitor (not the BIOS PowerShell Provider)." })
}

# ========== 3) Discover classes in root\dcim\sysman ==========
$allClassNames = @()
$dcimClassNames = @()
$numericSensorClassExists = $false
if ($namespaceExists) {
  try {
    $allClasses = Get-CimClass -Namespace $ns -ErrorAction Stop
    $allClassNames = @($allClasses | Select-Object -ExpandProperty CimClassName)
    $dcimClassNames = @($allClassNames | Where-Object { $_ -like "DCIM_*" } | Sort-Object)
    $numericSensorClassExists = $dcimClassNames -contains "DCIM_NumericSensor"
  } catch {
    Add-ScriptError -Step "Get-CimClass $ns" -Exception $_.Exception
    $discovery.Add([pscustomobject]@{ Step = "Get-CimClass $ns"; Result = "Error"; Detail = $_.Exception.Message })
  }
}

# When namespace exists but 0 DCIM_* classes = provider not installed/registered (not a query bug)
$zeroDcimClasses = ($dcimClassNames.Count -eq 0)
$providerMissingMessage = "Dell provider not installed/registered."
$nextActionMessage = "Next action: Install Dell Command | Monitor (from Dell Support). Do not use Dell Command | Update for sensors; it does not provide WMI/sensor support."
$failureMessage = "Dell Command | Monitor WMI provider not present / not registered; cannot access Dell-native temps."
if (-not $namespaceExists -or ($allClassNames.Count -eq 0)) {
  $failureMessage = "Namespace $ns has no classes (or namespace missing). " + $failureMessage
} elseif ($zeroDcimClasses) {
  $failureMessage = $providerMissingMessage + " root\dcim\sysman exists but zero DCIM_* classes exist inside it (namespace stub without Dell provider). " + $nextActionMessage
} else {
  $failureMessage = "DCIM sensor class(es) not found or no temperature instances. " + $failureMessage
}
if ($zeroDcimClasses -or -not $numericSensorClassExists) {
  $discovery.Add([pscustomobject]@{ Step = "Temperature sensors"; Result = "Not available"; Detail = $failureMessage })
}

# ========== 4) Discovery-first: find sensor candidate classes and collect temperatures ==========
# Sensor candidates by name pattern (Dell exposes various DCIM_* classes; not all on every endpoint)
$sensorClassPattern = 'NumericSensor|Sensor|Therm|Temp|Thermal|Fan'
$sensorCandidateClasses = @($dcimClassNames | Where-Object { $_ -match $sensorClassPattern })

foreach ($className in $sensorCandidateClasses) {
  try {
    $instances = @(Get-CimInstance -Namespace $ns -ClassName $className -ErrorAction Stop)
    $discovery.Add([pscustomobject]@{ Step = $className; Result = "OK"; Detail = "$($instances.Count) instance(s)." })
    foreach ($s in $instances) {
      $sensorName = if ($s.PSObject.Properties.Name -contains "ElementName") { $s.ElementName }
        elseif ($s.PSObject.Properties.Name -contains "Name") { $s.Name }
        else { $s.DeviceID }
      $raw = $null
      $unitMod = $null
      $baseUnits = $null
      $isTemperature = $false
      if ($s.PSObject.Properties.Name -contains "SensorType" -and [int]$s.SensorType -eq 2) { $isTemperature = $true }
      if ($s.PSObject.Properties.Name -contains "CurrentReading") { $raw = $s.CurrentReading }
      elseif ($s.PSObject.Properties.Name -contains "Reading") { $raw = $s.Reading }
      elseif ($s.PSObject.Properties.Name -contains "CurrentValue") { $raw = $s.CurrentValue }
      if ($s.PSObject.Properties.Name -contains "UnitModifier") { $unitMod = $s.UnitModifier }
      if ($s.PSObject.Properties.Name -contains "BaseUnits") { $baseUnits = $s.BaseUnits }
      if ($null -eq $raw -and $s.PSObject.Properties.Name -contains "Temperature") { $raw = $s.Temperature; $isTemperature = $true }
      if ($null -eq $raw) { continue }
      if ($className -eq "DCIM_NumericSensor" -and -not $isTemperature) { continue }
      if ($className -ne "DCIM_NumericSensor" -and -not $isTemperature -and $className -notmatch 'Therm|Temp') { continue }
      $scaled = Get-ScaledValue -Reading $raw -UnitModifier $unitMod
      $celsius = if ($null -ne $scaled) { [Math]::Round([double]$scaled, 2) } else { $null }
      $status = $null; $health = $null
      if ($s.PSObject.Properties.Name -contains "CurrentState") { $status = $s.CurrentState }
      if ($s.PSObject.Properties.Name -contains "HealthState") { $health = $s.HealthState }
      if ($s.PSObject.Properties.Name -contains "Status") { $status = $s.Status }
      $results.Add([pscustomobject]@{
        Timestamp     = $now
        ComputerName  = $computer
        Vendor        = "Dell"
        Namespace     = $ns
        ClassName     = $className
        SensorName    = $sensorName
        Component     = (Get-InferredComponent -SensorName $sensorName)
        TemperatureC  = $celsius
        RawValue      = $raw
        BaseUnits     = $baseUnits
        UnitModifier  = $unitMod
        UnitsScaling  = if ($null -ne $unitMod) { "BaseUnits * 10^$unitMod" } else { "raw" }
        Status        = $status
        Health        = $health
      })
    }
  } catch {
    Add-ScriptError -Step "Get-CimInstance $className" -Exception $_.Exception
    $discovery.Add([pscustomobject]@{ Step = $className; Result = "Error"; Detail = $_.Exception.Message })
  }
}

# If provider present (DCIM_* classes exist) but no temperature readings
if ($dcimClassNames.Count -gt 0 -and $results.Count -eq 0) {
  $failureMessage = "Model/SKU/BIOS not exposing temperature sensors via Dell DCIM provider. Discovery evidence: $($dcimClassNames.Count) DCIM_* class(es) present; sensor candidate classes tried: $($sensorCandidateClasses -join ', '). No temperature instances returned."
  $discovery.Add([pscustomobject]@{ Step = "Temperature sensors"; Result = "None exposed"; Detail = $failureMessage })
}

$deduped = $results | Sort-Object SensorName, RawValue -Unique
$uniqueSensors = $deduped | Where-Object { $null -ne $_.SensorName } | Select-Object -Property SensorName, Component, ClassName -Unique
$mappingLine = "Component is inferred only when SensorName contains one of: CPU, GPU, Ambient, Memory, Storage, Chassis, VRM, Battery, Fan (case-insensitive). Otherwise Component = `$null."
$summary = [pscustomobject]@{
  Timestamp       = $now
  ComputerName    = $computer
  Vendor          = "Dell"
  Manufacturer    = $manufacturer
  IsDell          = $isDell
  Namespace       = $ns
  SensorClassesUsed = @($sensorCandidateClasses)
  TotalReadings   = $deduped.Count
  UniqueSensors   = @($uniqueSensors)
  MappingNote     = $mappingLine
}

# --- Output ---
if ($AsJson) {
  $remediation = @()
  $failureReason = if ($deduped.Count -eq 0) { $failureMessage } else { $null }
  if ($deduped.Count -eq 0 -and $zeroDcimClasses) {
    $remediation = @(
      "a) Verify Dell Command | Monitor is installed (run script with -Diagnostic or check Uninstall registry).",
      "b) If missing or broken: reinstall or repair Dell Command | Monitor from Dell support (product: Dell Command | Monitor).",
      "c) After install/repair: rerun class discovery (e.g. .\Get-DellTemps.ps1 -Diagnostic)."
    )
  }
  $output = @{
    readings     = @($deduped)
    summary      = $summary
    discovery    = @($discovery)
    dcimClasses  = @($dcimClassNames)
    failureReason = $failureReason
    remediation  = @($remediation)
    errors       = @($scriptErrors)
  }
  $json = $output | ConvertTo-Json -Depth 6
  if ($OutFile) {
    try {
      $json | Out-File -FilePath $OutFile -Encoding utf8
      Write-Host "JSON written to: $OutFile"
    } catch {
      Add-ScriptError -Step "Out-File $OutFile" -Exception $_.Exception
      Write-Warning "Failed to write $OutFile : $($_.Exception.Message)"
    }
  } else {
    $json
  }
} else {
  Write-Host "`n--- Dell temperature sensors (DCIM discovery) ---" -ForegroundColor Cyan
  Write-Host "  Manufacturer: $manufacturer  |  Namespace: $ns  |  DCIM_* classes: $($dcimClassNames.Count)  |  Sensor candidates: $($sensorCandidateClasses.Count)"
  Write-Host ""

  if ($deduped.Count -eq 0) {
    Write-Host "  No temperature readings returned." -ForegroundColor Yellow
    Write-Host "  $failureMessage" -ForegroundColor Gray
    if ($scriptErrors.Count -gt 0) {
      Write-Host "`n--- Error report ---" -ForegroundColor Red
      $scriptErrors | Format-Table -AutoSize Step, ExceptionType, Message -Wrap
    }
    Write-Host "`n--- Discovery ---" -ForegroundColor Yellow
    $discovery | Format-Table -AutoSize Step, Result, Detail -Wrap
    if ($dcimClassNames.Count -gt 0) {
      Write-Host "  DCIM_* classes present in $ns :" -ForegroundColor Gray
      $dcimClassNames | ForEach-Object { Write-Host "    $_" }
    }
    if ($zeroDcimClasses -or $dcimClassNames.Count -eq 0) {
      Write-Host "`n--- Remediation ---" -ForegroundColor Yellow
      Write-Host "  a) Run as Admin: .\Repair-DellWmiAndDcm.ps1 (WMI repo + Dell Command | Monitor check)." -ForegroundColor Gray
      Write-Host "  b) Install Dell Command | Monitor from Dell Support (not Dell Command | Update; Update does not provide sensor/WMI support)." -ForegroundColor Gray
      Write-Host "  c) After install: rerun this script or .\Get-DellTemps.ps1 -Diagnostic to confirm DCIM_* classes." -ForegroundColor Gray
    }
  } else {
    $deduped | Sort-Object SensorName | Format-Table -AutoSize Timestamp, ComputerName, Vendor, ClassName, SensorName, Component, TemperatureC, RawValue, UnitsScaling, Status, Health -Wrap
    if ($scriptErrors.Count -gt 0) {
      Write-Host "`n--- Error report ---" -ForegroundColor Red
      $scriptErrors | Format-Table -AutoSize Step, ExceptionType, Message -Wrap
    }
    Write-Host "`n--- Discovery / status ---" -ForegroundColor Yellow
    $discovery | Format-Table -AutoSize Step, Result, Detail -Wrap
  }

  Write-Host "`n--- Unique sensors and mapping ---" -ForegroundColor Cyan
  if ($uniqueSensors) {
    $uniqueSensors | Format-Table -AutoSize
  }
  Write-Host $mappingLine -ForegroundColor Gray
}

# ========== -Diagnostic ==========
if ($Diagnostic) {
  Write-Host "`n========== DIAGNOSTIC ==========" -ForegroundColor Magenta
  Write-Host "  Manufacturer: $manufacturer"
  Write-Host ""

  Write-Host "[1] Namespaces under root\dcim:" -ForegroundColor Cyan
  $diagNsList = @()
  try {
    $diagNsList = @(Get-CimInstance -Namespace "root\dcim" -ClassName "__Namespace" -ErrorAction Stop | Select-Object -ExpandProperty Name)
    if ($diagNsList.Count -eq 0) {
      Write-Host "    (none or root\dcim does not exist)"
    } else {
      $diagNsList | ForEach-Object { Write-Host "    $_" }
    }
  } catch {
    Write-Host "    Error: $($_.Exception.Message)"
  }

  Write-Host "`n[2] Class count per namespace:" -ForegroundColor Cyan
  $namespacesToCheck = @($ns)
  if ($diagNsList.Count -gt 0) {
    $namespacesToCheck = @($diagNsList | ForEach-Object { "root\dcim\$_" })
  }
  foreach ($dn in $namespacesToCheck) {
    try {
      $classes = @(Get-CimClass -Namespace $dn -ErrorAction Stop)
      $count = $classes.Count
      $dcimCount = ($classes | Where-Object { $_.CimClassName -like "DCIM_*" }).Count
      Write-Host "    $dn : $count classes ($dcimCount DCIM_*)"
    } catch {
      Write-Host "    $dn : Error - $($_.Exception.Message)"
    }
  }

  Write-Host "`n[3] First 30 class names in root\dcim\sysman:" -ForegroundColor Cyan
  try {
    $topClasses = @(Get-CimClass -Namespace $ns -ErrorAction Stop | Select-Object -First 30 -ExpandProperty CimClassName)
    if ($topClasses.Count -eq 0) {
      Write-Host "    (no classes)"
    } else {
      $topClasses | ForEach-Object { Write-Host "    $_" }
    }
  } catch {
    Write-Host "    Error: $($_.Exception.Message)"
  }

  Write-Host "`n[4] Dell Command | Monitor install check (registry):" -ForegroundColor Cyan
  Write-Host "    Required for sensors: Dell Command | Monitor. Dell Command | Update does NOT provide WMI/sensor support." -ForegroundColor Gray
  try {
    $uninst = @(Get-ItemProperty "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue)
    $uninst64 = @(Get-ItemProperty "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue)
    $found = @($uninst + $uninst64) | Where-Object {
      $_.DisplayName -match "Dell Command\s*\|\s*Monitor|Command Monitor" -and
      $_.DisplayName -notmatch "Update|Configure"
    }
    if ($found.Count -eq 0) {
      Write-Host "    No Dell Command | Monitor found in Uninstall keys."
    } else {
      $found | ForEach-Object { Write-Host "    $($_.DisplayName)  $($_.DisplayVersion)" }
    }
  } catch {
    Write-Host "    Error: $($_.Exception.Message)"
  }

  Write-Host "`n[5] Sensor candidate classes and first instance (raw properties):" -ForegroundColor Cyan
  foreach ($sc in $sensorCandidateClasses) {
    try {
      $first = Get-CimInstance -Namespace $ns -ClassName $sc -ErrorAction Stop | Select-Object -First 1
      if ($first) {
        Write-Host "    --- $sc ---" -ForegroundColor Gray
        $first.PSObject.Properties | ForEach-Object { Write-Host "      $($_.Name) = $($_.Value)" }
      } else {
        Write-Host "    $sc : no instances" -ForegroundColor Gray
      }
    } catch {
      Write-Host "    $sc : Error - $($_.Exception.Message)" -ForegroundColor Gray
    }
  }
  if ($sensorCandidateClasses.Count -eq 0) {
    Write-Host "    No sensor candidate classes (pattern: $sensorClassPattern) in DCIM_* list." -ForegroundColor Gray
  }

  if ($scriptErrors.Count -gt 0) {
    Write-Host "`n[6] Error report (exceptions captured this run):" -ForegroundColor Cyan
    $scriptErrors | Format-Table -AutoSize Step, ExceptionType, Message -Wrap
    Write-Host "    FullMessage per error:" -ForegroundColor Gray
    foreach ($e in $scriptErrors) {
      Write-Host "    --- $($e.Step) ---" -ForegroundColor Gray
      Write-Host "    $($e.FullMessage)" -ForegroundColor Gray
    }
  }
  if ($zeroDcimClasses) {
    Write-Host "`n  >> root\dcim\sysman has zero DCIM_* classes. Run remediation: verify DCM installed, reinstall/repair if needed, then rerun -Diagnostic." -ForegroundColor Yellow
  }
  Write-Host "`n========== END DIAGNOSTIC ==========" -ForegroundColor Magenta
}

# ---------- Quick manual commands ----------
# List DCIM classes (paste only the command, not the PS prompt):
#   Get-CimClass -Namespace root\dcim\sysman | Where-Object CimClassName -like "DCIM_*" | Select-Object -ExpandProperty CimClassName | Sort-Object
# Confirm DCIM_NumericSensor and get temp sensors:
#   Get-CimInstance -Namespace root\dcim\sysman -ClassName DCIM_NumericSensor | Where-Object SensorType -eq 2
