<#
.SYNOPSIS
  Reports temperatures from Dell devices via Dell Command | Monitor (DCM) WMI — no third-party sensor libraries.

.DESCRIPTION
  Temperature sensors are exposed by Dell's documented class:
    root\dcim\sysman : DCIM_NumericSensor
  - SensorType = 2 => Temperature (Dell reference guide)
  - CurrentReading => current value
  - Units: BaseUnits * 10^UnitModifier (Dell reference guide)

  Does NOT use Win32_TemperatureProbe (SMBIOS; no real-time readings). Does NOT assume ACPI thermal zones on Dell.
  First discovers namespaces and classes; if DCIM_NumericSensor is missing or no SensorType=2 instances exist,
  prints a clear failure reason and discovery output for troubleshooting.

  Not all Dell systems expose sensor classes; DCM targets enterprise clients (Latitude, Precision, OptiPlex, etc.).

.PARAMETER AsJson
  Emit output as JSON.

.PARAMETER OutFile
  With -AsJson, write JSON to this file path.

.PARAMETER Diagnostic
  Dump discovery: namespace class count, first 30 class names, root\dcim children, DCM install check, first sensor raw properties.

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

# Deterministic failure when provider not present / not registered (zero DCIM_* classes)
$failureMessage = "Dell Command | Monitor WMI provider not present / not registered; cannot access Dell-native temps."
$zeroDcimClasses = ($dcimClassNames.Count -eq 0)
if (-not $numericSensorClassExists) {
  if (-not $namespaceExists -or ($allClassNames.Count -eq 0)) {
    $failureMessage = "Namespace $ns has no classes (or namespace missing). " + $failureMessage
  } elseif ($zeroDcimClasses) {
    $failureMessage = "root\dcim\sysman exists but zero DCIM_* classes exist inside it. " + $failureMessage
  } else {
    $failureMessage = "DCIM_NumericSensor not found in $ns. " + $failureMessage
  }
  $discovery.Add([pscustomobject]@{ Step = "Temperature sensors"; Result = "Not available"; Detail = $failureMessage })
}

# ========== 4) Query DCIM_NumericSensor, filter SensorType eq 2 (Temperature) ==========
$tempSensors = @()
if ($numericSensorClassExists) {
  try {
    $sensors = Get-CimInstance -Namespace $ns -ClassName "DCIM_NumericSensor" -ErrorAction Stop
    # Dell reference: SensorType 2 = Temperature
    $tempSensors = @($sensors | Where-Object { $_.SensorType -eq 2 })
    if ($tempSensors.Count -eq 0) {
      $failureMessage = "DCIM_NumericSensor exists but no SensorType=2 (Temperature) instances. " + $failureMessage
      $discovery.Add([pscustomobject]@{ Step = "DCIM_NumericSensor"; Result = "No temp instances"; Detail = "Class exists but no SensorType=2 (Temperature) instances. Other SensorTypes may be present." })
    }
  } catch {
    Add-ScriptError -Step "DCIM_NumericSensor (Get-CimInstance)" -Exception $_.Exception
    $discovery.Add([pscustomobject]@{ Step = "DCIM_NumericSensor"; Result = "Error"; Detail = $_.Exception.Message })
  }
}

foreach ($s in $tempSensors) {
  $sensorName = if ($s.PSObject.Properties.Name -contains "ElementName") { $s.ElementName }
    elseif ($s.PSObject.Properties.Name -contains "Name") { $s.Name }
    else { $s.DeviceID }
  $raw = $s.CurrentReading
  $scaled = Get-ScaledValue -Reading $raw -UnitModifier $s.UnitModifier
  $celsius = if ($null -ne $scaled) { [Math]::Round([double]$scaled, 2) } else { $null }
  $results.Add([pscustomobject]@{
    Timestamp     = $now
    ComputerName  = $computer
    Namespace     = $ns
    ClassName     = "DCIM_NumericSensor"
    SensorName    = $sensorName
    Component     = (Get-InferredComponent -SensorName $sensorName)
    Celsius       = $celsius
    RawReading    = $raw
    BaseUnits      = $s.BaseUnits
    UnitModifier   = $s.UnitModifier
    CurrentState   = $s.CurrentState
  })
}

$deduped = $results | Sort-Object SensorName, RawReading -Unique
$uniqueSensors = $deduped | Where-Object { $null -ne $_.SensorName } | Select-Object -Property SensorName, Component -Unique
$mappingLine = "Component is inferred only when SensorName contains one of: CPU, GPU, Ambient, Memory, Storage, Chassis, VRM, Battery, Fan (case-insensitive). Otherwise Component = `$null."
$summary = [pscustomobject]@{
  Timestamp     = $now
  ComputerName  = $computer
  Manufacturer  = $manufacturer
  IsDell        = $isDell
  Namespace     = $ns
  ClassUsed     = "DCIM_NumericSensor"
  TotalReadings = $deduped.Count
  UniqueSensors = @($uniqueSensors)
  MappingNote   = $mappingLine
}

# --- Output ---
if ($AsJson) {
  $remediation = @()
  $failureReason = $null
  if ($deduped.Count -eq 0 -and ($zeroDcimClasses -or -not $numericSensorClassExists)) {
    $failureReason = $failureMessage
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
  Write-Host "`n--- Dell temperature sensors (DCIM_NumericSensor, SensorType=2) ---" -ForegroundColor Cyan
  Write-Host "  Manufacturer: $manufacturer  |  Namespace: $ns  |  DCIM_NumericSensor: $numericSensorClassExists"
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
    if ($zeroDcimClasses -or -not $numericSensorClassExists) {
      Write-Host "`n--- Remediation ---" -ForegroundColor Yellow
      Write-Host "  a) Verify Dell Command | Monitor is installed (run this script with -Diagnostic, or check Uninstall registry)." -ForegroundColor Gray
      Write-Host "  b) If missing or broken: reinstall or repair Dell Command | Monitor from Dell support (product: Dell Command | Monitor)." -ForegroundColor Gray
      Write-Host "  c) After install/repair: rerun class discovery (e.g. .\Get-DellTemps.ps1 -Diagnostic)." -ForegroundColor Gray
    }
  } else {
    $deduped | Sort-Object SensorName | Format-Table -AutoSize Timestamp, ComputerName, SensorName, Component, Celsius, RawReading, BaseUnits, UnitModifier, CurrentState -Wrap
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
  try {
    $uninst = @(Get-ItemProperty "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue)
    $uninst64 = @(Get-ItemProperty "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue)
    $found = @($uninst + $uninst64) | Where-Object { $_.DisplayName -match "Dell Command\s*\|\s*Monitor|Command Monitor" }
    if ($found.Count -eq 0) {
      Write-Host "    No Dell Command | Monitor found in Uninstall keys."
    } else {
      $found | ForEach-Object { Write-Host "    $($_.DisplayName)  $($_.DisplayVersion)" }
    }
  } catch {
    Write-Host "    Error: $($_.Exception.Message)"
  }

  Write-Host "`n[5] First temperature sensor (SensorType=2) raw properties:" -ForegroundColor Cyan
  if ($tempSensors.Count -gt 0) {
    $tempSensors | Select-Object -First 1 | Format-List *
  } else {
    Write-Host "    No temperature sensor instances to show."
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
