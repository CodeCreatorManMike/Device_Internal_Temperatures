<#
.SYNOPSIS
  One script: installs Dell Command | Monitor if missing, waits for WMI provider, then collects temps. No 3rd-party libraries.

.DESCRIPTION
  - Checks if Dell Command | Monitor is installed (ignores Command | Update / Configure).
  - If not installed, downloads Dell's official installer and runs silent install (/s) as Dell documents.
  - Waits until the WMI provider is ready (DCIM_* classes appear).
  - Discovers and outputs all temperature-related readings via root\dcim\sysman without hardcoding a single class.
  - Useful error reporting if the provider is missing, install fails, or the BIOS isn't exposing any temps.

  Requires admin rights if installation is needed.
  Dell Command | Monitor supports unattended install via /s (Dell docs).

.PARAMETER AsJson
  Emit JSON (timestamp, computerName, vendor, provider info, readings, errors).

.PARAMETER OutFile
  With -AsJson, write JSON to this file path.

.PARAMETER Diagnostic
  Show system info, DCIM_* counts, sensor candidates, discovery evidence, and full error details.

.PARAMETER InstallerUrl
  Optional override if you host the installer internally.

.PARAMETER VerifySha256
  Verify SHA-256 of downloaded installer (recommended in managed environments).

.EXAMPLE
  .\Get-DellTemps-AutoInstall.ps1

.EXAMPLE
  .\Get-DellTemps-AutoInstall.ps1 -AsJson -OutFile .\dellTemps.json

.EXAMPLE
  .\Get-DellTemps-AutoInstall.ps1 -Diagnostic
#>

[CmdletBinding()]
param(
  [switch]$AsJson,
  [string]$OutFile,
  [switch]$Diagnostic,
  [string]$InstallerUrl,
  [switch]$VerifySha256
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -----------------------------
# Constants (Dell official package)
# -----------------------------
$Namespace = "root\dcim\sysman"
$Now = (Get-Date).ToString("o")

# Dell Command | Monitor v10.13.0 Win64 package (from Dell driver details page)
$DefaultWin64Url     = "https://dl.dell.com/FOLDER14184140M/1/Dell-Command-Monitor_NP0X6_WIN64_10.13.0.96_A00.EXE"
$DefaultWin64Sha256  = "66c1cf7b4f428e1c67e6dc075743bc893547099cecf3a481e634212a2aedf37c"

# Dell Command | Monitor supports unattended install via "/s"
$SilentArgs = "/s"

$ProviderWaitSeconds = 120
$PollIntervalSeconds = 3

# -----------------------------
# Helpers
# -----------------------------
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
  if (-not $Ex) { return }
  $ErrList.Add([pscustomobject]@{
    Step          = $Step
    ExceptionType = $Ex.GetType().FullName
    Message       = $Ex.Message
    FullMessage   = $Ex.ToString()
  }) | Out-Null
}

function Find-DellCommandMonitor {
  $uninstallKeys = @(
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
  )
  $rawEntries = foreach ($k in $uninstallKeys) {
    try { Get-ItemProperty $k -ErrorAction Stop } catch { $null }
  }
  $entries = @($rawEntries | Where-Object { $_ -ne $null -and $_.DisplayName })
  $monitor = @($entries | Where-Object {
    (
      $_.DisplayName -match 'Dell Command\s*\|\s*Monitor' -or
      $_.DisplayName -match 'Dell Command Monitor' -or
      $_.DisplayName -match 'Command\s*\|\s*Monitor'
    ) -and
    ($_.DisplayName -notmatch 'Update') -and
    ($_.DisplayName -notmatch 'Configure')
  } | Select-Object -First 5 DisplayName, DisplayVersion, Publisher, InstallDate)
  return [pscustomobject]@{
    Found = (@($monitor).Count -gt 0)
    Hits  = @($monitor)
  }
}

function Get-DCIMClassNames {
  try {
    $list = @(Get-CimClass -Namespace $Namespace -ErrorAction Stop | Where-Object { $_.CimClassName -like "DCIM_*" } | Select-Object -ExpandProperty CimClassName | Sort-Object)
    return $list
  } catch {
    return @()
  }
}

function Download-File {
  param([string]$Url, [string]$DestinationPath)
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 } catch { }
  Invoke-WebRequest -Uri $Url -OutFile $DestinationPath -UseBasicParsing
}

function Get-FileSha256 {
  param([string]$Path)
  return (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Ensure-DellCommandMonitor {
  param([System.Collections.Generic.List[object]]$Errs)
  $dcm = Find-DellCommandMonitor
  if ($dcm.Found) {
    return [pscustomobject]@{ Installed = $true; Action = "AlreadyInstalled"; Details = $dcm.Hits }
  }
  if (-not (Is-Admin)) {
    throw [System.UnauthorizedAccessException]::new("Dell Command | Monitor is not installed and installation requires Administrator. Re-run PowerShell as Admin.")
  }
  $arch = $env:PROCESSOR_ARCHITECTURE
  if ($arch -ne "AMD64" -and $arch -ne "ARM64") {
    throw "Unsupported architecture: $arch (expected AMD64 or ARM64)."
  }
  $url = if ($InstallerUrl) { $InstallerUrl } else { $DefaultWin64Url }
  $expectedSha = if ($InstallerUrl) { $null } else { $DefaultWin64Sha256 }
  $tempDir = Join-Path $env:TEMP "DellCommandMonitor"
  New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
  $installerPath = Join-Path $tempDir ("DellCommandMonitorInstaller_{0}.exe" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
  try {
    Download-File -Url $url -DestinationPath $installerPath
  } catch {
    Add-ScriptError -ErrList $Errs -Step "Download installer" -Ex $_.Exception
    throw "Failed to download Dell Command | Monitor installer from: $url"
  }
  if ($VerifySha256 -and $expectedSha) {
    $actual = Get-FileSha256 -Path $installerPath
    if ($actual -ne $expectedSha) {
      throw "SHA-256 mismatch for downloaded installer. Expected $expectedSha, got $actual."
    }
  }
  try {
    $p = Start-Process -FilePath $installerPath -ArgumentList $SilentArgs -PassThru -Wait
    if ($p.ExitCode -ne 0) {
      throw "Installer exit code: $($p.ExitCode)"
    }
  } catch {
    Add-ScriptError -ErrList $Errs -Step "Run installer (/s)" -Ex $_.Exception
    throw "Dell Command | Monitor installer failed."
  }
  $deadline = (Get-Date).AddSeconds($ProviderWaitSeconds)
  do {
    Start-Sleep -Seconds $PollIntervalSeconds
    $dcim = @(Get-DCIMClassNames)
    if ($dcim.Count -gt 0) {
      return [pscustomobject]@{ Installed = $true; Action = "InstalledNow"; Details = $null }
    }
  } while ((Get-Date) -lt $deadline)
  return [pscustomobject]@{ Installed = $true; Action = "InstalledButProviderMissing"; Details = $null }
}

function Pick-SensorName {
  param($inst)
  foreach ($p in @("ElementName", "Name", "SensorName", "DeviceID", "InstanceName")) {
    if ($inst.PSObject.Properties.Name -contains $p -and $null -ne $inst.$p) { return [string]$inst.$p }
  }
  return $null
}

function Extract-RawValue {
  param($inst)
  foreach ($prop in @("CurrentReading", "Temperature", "Reading", "CurrentValue", "CurrentTemperature")) {
    if ($inst.PSObject.Properties.Name -contains $prop -and $null -ne $inst.$prop) {
      return [pscustomobject]@{ Prop = $prop; Val = $inst.$prop }
    }
  }
  return $null
}

function Try-ConvertToCelsius {
  param([string]$PropUsed, $inst, [object]$raw)
  if ($inst.PSObject.Properties.Name -contains "UnitModifier" -and $null -ne $inst.UnitModifier) {
    $scaled = [double]$raw * [Math]::Pow(10, [double]$inst.UnitModifier)
    return [pscustomobject]@{ Celsius = $scaled; Scaling = "BaseUnits * 10^UnitModifier" }
  }
  if ($PropUsed -eq "CurrentTemperature") {
    $c = ([double]$raw / 10.0) - 273.15
    return [pscustomobject]@{ Celsius = $c; Scaling = "(raw/10) - 273.15" }
  }
  try { return [pscustomobject]@{ Celsius = [double]$raw; Scaling = $null } } catch { return [pscustomobject]@{ Celsius = $null; Scaling = $null } }
}

# -----------------------------
# Main
# -----------------------------
$errors = New-Object "System.Collections.Generic.List[object]"
$readings = New-Object "System.Collections.Generic.List[object]"

$cs = $null
try { $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop } catch { }
$man = if ($cs) { $cs.Manufacturer } else { $null }

if ($Diagnostic) {
  Write-Host "--- Diagnostic: System ---"
  Write-Host "Timestamp:   $Now"
  Write-Host "Computer:   $env:COMPUTERNAME"
  Write-Host "Manufacturer: $man"
  Write-Host "Admin:       $(Is-Admin)"
  Write-Host ""
}

$ensure = $null
try {
  $ensure = Ensure-DellCommandMonitor -Errs $errors
} catch {
  $msg = $_.Exception.Message
  Write-Host "ERROR: $msg" -ForegroundColor Red
  if ($errors.Count -gt 0) {
    Write-Host ""
    Write-Host "--- Error report ---"
    $errors | Select-Object Step, ExceptionType, Message | Format-Table -AutoSize -Wrap
    if ($Diagnostic) {
      Write-Host ""
      Write-Host "--- Error details ---"
      $errors | ForEach-Object {
        Write-Host "[$($_.Step)]"
        Write-Host $_.FullMessage
        Write-Host ""
      }
    }
  }
  return
}

try {
  $dcimClasses = @(Get-DCIMClassNames)
} catch {
  Add-ScriptError -ErrList $errors -Step "Get-CimClass DCIM_*" -Ex $_.Exception
  $dcimClasses = @()
}

if ($dcimClasses.Count -eq 0) {
  Write-Host "Dell Command | Monitor telemetry provider not installed/registered (no DCIM_* classes in $Namespace)." -ForegroundColor Yellow
  Write-Host "Install/repair Dell Command | Monitor, reboot, then rerun. Dell documents unattended install with: <EXE> /s" -ForegroundColor Yellow
  if ($ensure.Action -eq "InstalledButProviderMissing") {
    Write-Host "NOTE: We attempted to install, but DCIM_* classes still did not appear within $ProviderWaitSeconds seconds." -ForegroundColor Yellow
    Write-Host "Next: reboot, then rerun. If still missing, repair/reinstall Command | Monitor." -ForegroundColor Yellow
  }
  if ($errors.Count -gt 0) {
    Write-Host ""
    Write-Host "--- Error report ---"
    $errors | Select-Object Step, ExceptionType, Message | Format-Table -AutoSize -Wrap
    if ($Diagnostic) {
      Write-Host ""
      Write-Host "--- Error details ---"
      $errors | ForEach-Object {
        Write-Host "[$($_.Step)]"
        Write-Host $_.FullMessage
        Write-Host ""
      }
    }
  }
  return
}

$sensorCandidates = @($dcimClasses | Where-Object { $_ -match 'Sensor|NumericSensor|Temp|Therm|Thermal|Fan' })

if ($Diagnostic) {
  Write-Host "--- Diagnostic: Provider ---"
  Write-Host "DCIM_* class count: $($dcimClasses.Count)"
  Write-Host "Sensor candidates:  $($sensorCandidates.Count)"
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
  $instances = @($instances)
  if ($instances.Count -eq 0) { continue }

  foreach ($inst in $instances) {
    if ($cls -eq "DCIM_NumericSensor" -and ($inst.PSObject.Properties.Name -contains "SensorType")) {
      if ($inst.SensorType -ne 2) { continue }
    }
    $raw = Extract-RawValue -inst $inst
    if (-not $raw) { continue }

    $isTemp = $false
    if ($cls -match 'Temp|Therm|Thermal') { $isTemp = $true }
    elseif ($raw.Prop -eq "Temperature") { $isTemp = $true }
    elseif (($inst.PSObject.Properties.Name -contains "SensorType") -and ($inst.SensorType -eq 2)) { $isTemp = $true }
    if (-not $isTemp) { continue }

    $name = Pick-SensorName -inst $inst
    $conv = Try-ConvertToCelsius -PropUsed $raw.Prop -inst $inst -raw $raw.Val

    $readings.Add([pscustomobject]@{
      Timestamp    = $Now
      ComputerName = $env:COMPUTERNAME
      Namespace    = $Namespace
      Class        = $cls
      Sensor       = $name
      TemperatureC = if ($null -ne $conv.Celsius) { [Math]::Round([double]$conv.Celsius, 2) } else { $null }
      RawValue     = $raw.Val
      RawProperty  = $raw.Prop
      Scaling      = $conv.Scaling
    }) | Out-Null
  }
}

if ($readings.Count -eq 0) {
  Write-Host "Provider installed but no temperature sensors exposed." -ForegroundColor Yellow
  Write-Host "System firmware may not expose temperature sensors through Dell DCIM on this model/SKU/BIOS." -ForegroundColor Yellow
  if ($Diagnostic) {
    Write-Host ""
    Write-Host "--- Diagnostic: Discovery evidence ---"
    Write-Host "DCIM_* classes: $($dcimClasses.Count)"
    Write-Host "Sensor classes tried: $($sensorCandidates.Count)"
    Write-Host "First 25 sensor candidates:"
    $sensorCandidates | Select-Object -First 25 | ForEach-Object { Write-Host " - $_" }
  }
} else {
  $readings | Sort-Object Class, Sensor | Format-Table -AutoSize
}

if ($errors.Count -gt 0) {
  Write-Host ""
  Write-Host "--- Error report (non-fatal) ---"
  $errors | Select-Object Step, ExceptionType, Message | Format-Table -AutoSize -Wrap
  if ($Diagnostic) {
    Write-Host ""
    Write-Host "--- Error details ---"
    $errors | ForEach-Object {
      Write-Host "[$($_.Step)]"
      Write-Host $_.FullMessage
      Write-Host ""
    }
  }
}

if ($AsJson) {
  $payload = [pscustomobject]@{
    Timestamp    = $Now
    ComputerName = $env:COMPUTERNAME
    Vendor       = "Dell"
    Provider     = [pscustomobject]@{
      Namespace           = $Namespace
      DcimClassCount      = $dcimClasses.Count
      CandidateClassCount = $sensorCandidates.Count
      InstallAction       = $ensure.Action
    }
    Readings     = @($readings)
    Errors       = @($errors)
  }
  $json = $payload | ConvertTo-Json -Depth 8
  if ($OutFile) {
    try {
      $json | Out-File -FilePath $OutFile -Encoding utf8 -Force
      Write-Host ""
      Write-Host "Wrote JSON to: $OutFile"
    } catch {
      Add-ScriptError -ErrList $errors -Step "Write OutFile" -Ex $_.Exception
      Write-Host "Failed to write JSON to: $OutFile" -ForegroundColor Yellow
    }
  } else {
    $json
  }
}
