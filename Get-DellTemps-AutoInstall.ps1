<#
Get-DellTemps-AutoInstall.ps1 (HARDENED)
- Checks for Dell Command | Monitor (ignores Update/Configure).
- If missing: downloads + silent installs (Admin required).
- Waits for DCIM provider readiness (DCIM_* classes appear in root\dcim\sysman).
- Discovers temperature-related data across DCIM_* sensor-ish classes.
- Defensive against missing properties and odd registry/WMI objects.
- Outputs readings + non-fatal error report. Optional JSON.

Run (recommended):
  PowerShell (Admin)
  Set-ExecutionPolicy -Scope Process Bypass -Force
  .\Get-DellTemps-AutoInstall.ps1 -Diagnostic

Optional JSON:
  .\Get-DellTemps-AutoInstall.ps1 -AsJson -OutFile .\dellTemps.json
#>

[CmdletBinding()]
param(
  [switch]$AsJson,
  [string]$OutFile,
  [switch]$Diagnostic,

  # Override if you host installer internally:
  [string]$InstallerUrl,

  # Only verifies SHA256 for the default Dell URL (recommended in managed envs):
  [switch]$VerifySha256
)

$ErrorActionPreference = "Stop"
$Namespace = "root\dcim\sysman"
$Now = (Get-Date).ToString("o")

# Known Dell-hosted DCM installer URL + SHA256 (you can override URL with -InstallerUrl)
$DefaultWin64Url      = "https://dl.dell.com/FOLDER14184140M/1/Dell-Command-Monitor_NP0X6_WIN64_10.13.0.96_A00.EXE"
$DefaultWin64Sha256   = "66c1cf7b4f428e1c67e6dc075743bc893547099cecf3a481e634212a2aedf37c"
$SilentArgs           = "/s"

$ProviderWaitSeconds  = 180
$PollIntervalSeconds  = 3

# ---------------------------
# Helpers (property-safe)
# ---------------------------
function Has-Prop {
  param($obj, [string]$prop)
  if ($null -eq $obj) { return $false }
  return $null -ne $obj.PSObject.Properties[$prop]
}
function Get-Prop {
  param($obj, [string]$prop)
  if (Has-Prop $obj $prop) { return $obj.$prop }
  return $null
}
function Is-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Add-ScriptError {
  param(
    [System.Collections.Generic.List[object]]$ErrList,
    [string]$Step,
    [System.Exception]$Ex
  )
  $ErrList.Add([pscustomobject]@{
    Step          = $Step
    ExceptionType = $Ex.GetType().FullName
    Message       = $Ex.Message
    FullMessage   = $Ex.ToString()
  }) | Out-Null
}

# ---------------------------
# Dell Command | Monitor detection (robust)
# ---------------------------
function Get-UninstallEntriesSafe {
  $paths = @(
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
  )

  $all = New-Object System.Collections.Generic.List[object]
  foreach ($p in $paths) {
    try {
      foreach ($i in @(Get-ItemProperty $p -ErrorAction Stop)) {
        if ($null -ne $i -and (Has-Prop $i "DisplayName")) {
          $dn = Get-Prop $i "DisplayName"
          if ($dn) { $all.Add($i) | Out-Null }
        }
      }
    } catch {
      # ignore missing key / access errors
    }
  }
  return @($all)
}

function Find-DellCommandMonitor {
  $entries = Get-UninstallEntriesSafe

  $hits = $entries | Where-Object {
    $dn = Get-Prop $_ "DisplayName"
    $dn -and
    (
      $dn -match 'Dell Command\s*\|\s*Monitor' -or
      $dn -match 'Dell Command Monitor' -or
      $dn -match 'Command\s*\|\s*Monitor'
    ) -and
    ($dn -notmatch 'Update') -and
    ($dn -notmatch 'Configure')
  } | Select-Object -First 5 DisplayName, DisplayVersion, Publisher, InstallDate

  $paths = @(
    "$env:ProgramFiles\Dell\Command Monitor",
    "$env:ProgramFiles\Dell\CommandMonitor",
    "$env:ProgramFiles(x86)\Dell\Command Monitor",
    "$env:ProgramFiles(x86)\Dell\CommandMonitor"
  ) | Where-Object { Test-Path $_ }

  [pscustomobject]@{
    Found = (($hits.Count -gt 0) -or ($paths.Count -gt 0))
    Hits  = @($hits)
    Paths = @($paths)
  }
}

# ---------------------------
# DCIM provider readiness
# ---------------------------
function Get-DCIMClassNames {
  try {
    Get-CimClass -Namespace $Namespace -ErrorAction Stop |
      Where-Object { $_.CimClassName -like "DCIM_*" } |
      Select-Object -ExpandProperty CimClassName |
      Sort-Object
  } catch {
    @()
  }
}

# ---------------------------
# Download / Install
# ---------------------------
function Download-File {
  param([string]$Url, [string]$DestinationPath)

  # Try TLS 1.2+ (best effort)
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

  Invoke-WebRequest -Uri $Url -OutFile $DestinationPath
}

function Get-FileSha256 {
  param([string]$Path)
  (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Ensure-DellCommandMonitor {
  param([System.Collections.Generic.List[object]]$Errs)

  $dcm = Find-DellCommandMonitor
  if ($dcm.Found) {
    return [pscustomobject]@{ Installed=$true; Action="AlreadyInstalled"; Details=$dcm }
  }

  if (-not (Is-Admin)) {
    throw [System.UnauthorizedAccessException]::new(
      "Dell Command | Monitor is not installed. Auto-install requires Administrator. Re-run PowerShell as Admin."
    )
  }

  $url = if ($InstallerUrl) { $InstallerUrl } else { $DefaultWin64Url }
  $expectedSha = if ($InstallerUrl) { $null } else { $DefaultWin64Sha256 }

  $tempDir = Join-Path $env:TEMP "DellCommandMonitor"
  New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
  $installerPath = Join-Path $tempDir ("DellCommandMonitor_{0}.exe" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

  try {
    Download-File -Url $url -DestinationPath $installerPath
  } catch {
    Add-ScriptError -ErrList $Errs -Step "Download installer" -Ex $_.Exception
    throw "Failed to download Dell Command | Monitor installer from: $url"
  }

  if ($VerifySha256 -and $expectedSha) {
    $actual = Get-FileSha256 -Path $installerPath
    if ($actual -ne $expectedSha) {
      throw "SHA-256 mismatch. Expected $expectedSha, got $actual."
    }
  }

  try {
    $p = Start-Process -FilePath $installerPath -ArgumentList $SilentArgs -PassThru -Wait
    if ($p.ExitCode -ne 0) {
      throw "Installer exit code: $($p.ExitCode)"
    }
  } catch {
    Add-ScriptError -ErrList $Errs -Step "Run installer (/s)" -Ex $_.Exception
    throw "Dell Command | Monitor install failed."
  }

  # Wait for provider
  $deadline = (Get-Date).AddSeconds($ProviderWaitSeconds)
  do {
    Start-Sleep -Seconds $PollIntervalSeconds
    $dcim = Get-DCIMClassNames
    if ($dcim.Count -gt 0) {
      return [pscustomobject]@{ Installed=$true; Action="InstalledNow"; Details=$null }
    }
  } while ((Get-Date) -lt $deadline)

  return [pscustomobject]@{ Installed=$true; Action="InstalledButProviderMissing"; Details=$null }
}

# ---------------------------
# Sensor extraction
# ---------------------------
function Pick-SensorName {
  param($inst)
  foreach ($p in @("ElementName","Name","SensorName","DeviceID","InstanceName")) {
    if (Has-Prop $inst $p) {
      $v = Get-Prop $inst $p
      if ($v) { return [string]$v }
    }
  }
  return $null
}

function Extract-RawValue {
  param($inst)
  foreach ($p in @("CurrentReading","Temperature","Reading","CurrentValue","CurrentTemperature")) {
    if (Has-Prop $inst $p) {
      $v = Get-Prop $inst $p
      if ($null -ne $v) { return [pscustomobject]@{ Prop=$p; Val=$v } }
    }
  }
  return $null
}

function Convert-ToCelsius {
  param($inst, [string]$propUsed, [object]$raw)

  # Apply UnitModifier scaling if present (common in DCIM numeric readings)
  if (Has-Prop $inst "UnitModifier") {
    $um = Get-Prop $inst "UnitModifier"
    if ($null -ne $um) {
      $scaled = [double]$raw * [Math]::Pow(10, [double]$um)
      return [pscustomobject]@{ Celsius=$scaled; Scaling="BaseUnits * 10^UnitModifier" }
    }
  }

  # If it were ACPI tenths Kelvin (rare in DCIM), convert:
  if ($propUsed -eq "CurrentTemperature") {
    $c = ([double]$raw / 10.0) - 273.15
    return [pscustomobject]@{ Celsius=$c; Scaling="(raw/10) - 273.15" }
  }

  # Default: treat as Celsius numeric
  try { return [pscustomobject]@{ Celsius=[double]$raw; Scaling=$null } }
  catch { return [pscustomobject]@{ Celsius=$null; Scaling=$null } }
}

# ---------------------------
# Main
# ---------------------------
$errors   = New-Object "System.Collections.Generic.List[object]"
$readings = New-Object "System.Collections.Generic.List[object]"

if ($Diagnostic) {
  Write-Host "--- Diagnostic ---"
  Write-Host "Timestamp: $Now"
  Write-Host "Admin:     $(Is-Admin)"
  $cs = $null
  try { $cs = Get-CimInstance Win32_ComputerSystem } catch {}
  if ($cs) { Write-Host "Manufacturer: $($cs.Manufacturer) | Model: $($cs.Model)" }
  Write-Host ""
}

# Ensure DCM
$ensure = $null
try {
  $ensure = Ensure-DellCommandMonitor -Errs $errors
} catch {
  Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
  if ($errors.Count -gt 0) {
    Write-Host "`n--- Error report ---"
    $errors | Select Step, ExceptionType, Message | Format-Table -AutoSize
    if ($Diagnostic) {
      Write-Host "`n--- Error details ---"
      $errors | ForEach-Object { Write-Host "[$($_.Step)]`n$($_.FullMessage)`n" }
    }
  }
  return
}

# Verify DCIM classes exist
$dcimClasses = Get-DCIMClassNames
if ($dcimClasses.Count -eq 0) {
  Write-Host "Dell Command | Monitor telemetry provider not installed/registered (no DCIM_* classes in $Namespace)." -ForegroundColor Yellow
  Write-Host "If you just installed, reboot and rerun. If still missing, repair/reinstall DCM." -ForegroundColor Yellow
  if ($ensure.Action -eq "InstalledButProviderMissing") {
    Write-Host "NOTE: Install ran but DCIM provider did not appear within $ProviderWaitSeconds seconds." -ForegroundColor Yellow
  }
  return
}

# Sensor candidate classes (discovery-first)
$sensorCandidates = $dcimClasses | Where-Object { $_ -match 'Sensor|NumericSensor|Temp|Therm|Thermal|Fan' }

if ($Diagnostic) {
  Write-Host "--- Provider ---"
  Write-Host "InstallAction: $($ensure.Action)"
  Write-Host "DCIM_* class count: $($dcimClasses.Count)"
  Write-Host "Sensor candidates: $($sensorCandidates.Count)"
  Write-Host ""
}

foreach ($cls in $sensorCandidates) {
  $instances = $null
  try {
    $instances = Get-CimInstance -Namespace $Namespace -ClassName $cls -ErrorAction Stop
  } catch {
    Add-ScriptError -ErrList $errors -Step ("Get-CimInstance {0}" -f $cls) -Ex $_.Exception
    continue
  }
  if (-not $instances) { continue }

  foreach ($inst in @($instances)) {

    # For DCIM_NumericSensor, filter to SensorType==2 (Temperature) when present
    if ($cls -eq "DCIM_NumericSensor" -and (Has-Prop $inst "SensorType")) {
      if ((Get-Prop $inst "SensorType") -ne 2) { continue }
    }

    $raw = Extract-RawValue $inst
    if (-not $raw) { continue }

    # Only treat as temperature when:
    # - class name indicates temp/thermal OR
    # - Temperature property used OR
    # - SensorType==2 (when present)
    $isTemp = $false
    if ($cls -match 'Temp|Therm|Thermal') { $isTemp = $true }
    elseif ($raw.Prop -eq "Temperature") { $isTemp = $true }
    elseif ((Has-Prop $inst "SensorType") -and ((Get-Prop $inst "SensorType") -eq 2)) { $isTemp = $true }

    if (-not $isTemp) { continue }

    $name = Pick-SensorName $inst
    $conv = Convert-ToCelsius -inst $inst -propUsed $raw.Prop -raw $raw.Val

    $readings.Add([pscustomobject]@{
      Timestamp    = $Now
      ComputerName = $env:COMPUTERNAME
      Namespace    = $Namespace
      Class        = $cls
      Sensor       = $name
      TemperatureC = if ($conv.Celsius -ne $null) { [Math]::Round([double]$conv.Celsius, 2) } else { $null }
      RawValue     = $raw.Val
      RawProperty  = $raw.Prop
      Scaling      = $conv.Scaling
    }) | Out-Null
  }
}

if ($readings.Count -eq 0) {
  Write-Host "Provider present but no temperature sensors exposed." -ForegroundColor Yellow
  Write-Host "This model/SKU/BIOS may not publish temp sensors via Dell DCIM (even if DCIM classes exist)." -ForegroundColor Yellow
  if ($Diagnostic) {
    Write-Host "`n--- Diagnostic: Tried classes (first 40) ---"
    $sensorCandidates | Select-Object -First 40 | ForEach-Object { Write-Host " - $_" }
  }
} else {
  $readings | Sort-Object Class, Sensor | Format-Table -AutoSize
}

if ($errors.Count -gt 0) {
  Write-Host "`n--- Error report (non-fatal) ---"
  $errors | Select Step, ExceptionType, Message | Format-Table -AutoSize
  if ($Diagnostic) {
    Write-Host "`n--- Error details ---"
    $errors | ForEach-Object { Write-Host "[$($_.Step)]`n$($_.FullMessage)`n" }
  }
}

if ($AsJson) {
  $payload = [pscustomobject]@{
    Timestamp    = $Now
    ComputerName = $env:COMPUTERNAME
    Vendor       = "Dell"
    Provider     = [pscustomobject]@{
      Namespace           = $Namespace
      InstallAction       = $ensure.Action
      DcimClassCount      = $dcimClasses.Count
      CandidateClassCount = $sensorCandidates.Count
    }
    Readings     = @($readings)
    Errors       = @($errors)
  }

  $json = $payload | ConvertTo-Json -Depth 8
  if ($OutFile) {
    $json | Out-File -FilePath $OutFile -Encoding utf8 -Force
    Write-Host "`nWrote JSON to: $OutFile"
  } else {
    $json
  }
}
