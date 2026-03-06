<#
.SYNOPSIS
Collects native Microsoft/Surface thermal-zone temperatures on Windows 11 and prints a human-readable report to the terminal.

.DESCRIPTION
This script is designed for Microsoft laptops running Windows 11, especially Surface devices.

Primary live temperature source:
- Namespace: root\wmi
- Class:     MSAcpi_ThermalZoneTemperature

Output: Human-readable report to the terminal (header, temperatures, all ACPI zones, Surface drivers, diagnostics).

.NOTES
Context:            LocalDevice / LocalUser
Version:            1.0.0.0 - Microsoft/Surface native thermal-zone implementation
Last Generated:     06 Mar 2026

If you see "running scripts is disabled", run with bypass for this run only:
  powershell -ExecutionPolicy Bypass -File ".\Get-SurfaceTemperatures.ps1"
Or set policy for CurrentUser (persistent): Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

trap {
    $host.ui.WriteErrorLine($_.ToString())
    exit 1
}

$NOT_AVAILABLE = -1.0
# Degree symbol at runtime so console encoding does not break it
$degC = [char]0x00B0 + "C"

# Surface/Intel convention-based zone -> component mapping (from ACPI docs, linux-surface thermald, and laptop thermal zone patterns).
# Microsoft does not publish official mapping; this is a best-effort from community/docs. Edit to match your device if needed.
# Keys: short zone name (e.g. TZ01_0). Values: our component key (CPU, GPU, PCH, Battery, Skin1, Skin2, Exhaust, etc.).
$Script:SurfaceZoneToComponent = @{
    'TZ01_0' = 'CPU'   # First zone often main package/SOC (common in ACPI/laptop docs)
    'TZ02_0' = 'GPU'   # Second zone often GPU or second major heat source
    'TZ05_0' = 'PCH'   # Intel PCH thermal zone often in mid numbering
    'TZ06_0' = 'Battery'  # Often coolest; many systems put battery zone here
    'TZ07_0' = 'Skin1' # Chassis/skin touch point 1 (Surface SMF monitors multiple touch points)
    'TZ08_0' = 'Skin2' # Chassis/skin touch point 2
    'TZ09_0' = 'Exhaust' # Exhaust/vent area
}
# Optional: set this to override the convention (e.g. $UserZoneMapping = @{ 'TZ01_0'='CPU'; 'TZ02_0'='GPU' })
$Script:UserZoneMapping = @{}

$temps = @{
    CPU              = $NOT_AVAILABLE
    GPU              = $NOT_AVAILABLE
    Exhaust          = $NOT_AVAILABLE
    LocalHotspot     = $NOT_AVAILABLE
    Battery          = $NOT_AVAILABLE
    ChargingCircuit  = $NOT_AVAILABLE
    Skin1            = $NOT_AVAILABLE
    Skin2            = $NOT_AVAILABLE
    Misc             = $NOT_AVAILABLE
    PCH              = $NOT_AVAILABLE
}

$rawSensors   = New-Object System.Collections.Generic.List[string]
$zoneList     = New-Object System.Collections.Generic.List[string]
$driverList   = New-Object System.Collections.Generic.List[string]

$diag = [ordered]@{
    TimestampUtc = (Get-Date).ToUniversalTime().ToString("o")
    RunningAsUser = "$env:USERDOMAIN\$env:USERNAME"
    PSVersion = $PSVersionTable.PSVersion.ToString()
    IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
              ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    ThermalZone = [ordered]@{
        Namespace         = 'root\wmi'
        Class             = 'MSAcpi_ThermalZoneTemperature'
        ClassExists       = $false
        QueryAttempted    = $false
        QuerySucceeded    = $false
        QueryError        = $null
        InstancesReturned = 0
        InstancesWithTemp = 0
    }

    LegacyProbe = [ordered]@{
        Class             = 'Win32_TemperatureProbe'
        Queried           = $false
        InstancesReturned = 0
        AnyCurrentReading = $false
    }

    SurfaceDrivers = [ordered]@{
        QuerySucceeded    = $false
        QueryError        = $null
        MatchingDrivers   = 0
    }
}

function Set-IfEmpty {
    param(
        [Parameter(Mandatory=$true)] [hashtable] $Table,
        [Parameter(Mandatory=$true)] [string] $Key,
        [Parameter(Mandatory=$true)] [double] $Value
    )
    if ($Table.ContainsKey($Key) -and ($Table[$Key] -eq $NOT_AVAILABLE)) {
        $Table[$Key] = [double]$Value
    }
}

function Convert-TenthsKelvinToCelsius {
    param([uint32]$TenthsKelvin)
    return [math]::Round((($TenthsKelvin / 10.0) - 273.15), 1)
}

function Get-FriendlyKeyFromZoneName {
    param([Parameter(Mandatory=$true)] [string] $Text)

    $t = $Text.ToLowerInvariant()

    if ($t -match 'cpu|proc|processor|package')      { return 'CPU' }
    if ($t -match 'gpu|gfx|graphics|dgpu|igpu')       { return 'GPU' }
    if ($t -match 'battery|batt')                     { return 'Battery' }
    if ($t -match 'pch|platform\s*controller\s*hub')  { return 'PCH' }
    if ($t -match 'skin\s*1|skin1')                   { return 'Skin1' }
    if ($t -match 'skin\s*2|skin2')                   { return 'Skin2' }
    if ($t -match 'exhaust|vent|outlet')              { return 'Exhaust' }
    if ($t -match 'charging|charger|vrm|regulator')    { return 'ChargingCircuit' }
    if ($t -match 'local|hotspot|hot\s*spot')         { return 'LocalHotspot' }

    return 'Misc'
}

function Try-CollectThermalZones {
    param(
        [hashtable]$TempsTable,
        [System.Collections.Generic.List[string]]$RawList,
        [System.Collections.Generic.List[string]]$ZoneList,
        $DiagRoot
    )

    $ns = [string]$DiagRoot.ThermalZone.Namespace
    $class = [string]$DiagRoot.ThermalZone.Class

    try {
        Get-CimClass -Namespace $ns -ClassName $class -ErrorAction Stop | Out-Null
        $DiagRoot.ThermalZone.ClassExists = $true
    } catch {
        $DiagRoot.ThermalZone.ClassExists = $false
        $DiagRoot.ThermalZone.QueryError = $_.Exception.Message
        return @{ Count = 0 }
    }

    $DiagRoot.ThermalZone.QueryAttempted = $true
    try {
        $zones = @(Get-CimInstance -Namespace $ns -ClassName $class -ErrorAction Stop)
        $DiagRoot.ThermalZone.QuerySucceeded = $true
        $DiagRoot.ThermalZone.InstancesReturned = $zones.Count
    } catch {
        $DiagRoot.ThermalZone.QuerySucceeded = $false
        $DiagRoot.ThermalZone.QueryError = $_.Exception.Message
        return @{ Count = 0 }
    }

    foreach ($z in $zones) {
        $name = [string]$z.InstanceName
        $tempRaw = $z.CurrentTemperature

        $rawLine = ("ACPI|InstanceName={0}|CurrentTemperature={1}|CriticalTripPoint={2}|PassiveTripPoint={3}|ActiveTripPoint={4}" -f `
            $name, $z.CurrentTemperature, $z.CriticalTripPoint, $z.PassiveTripPoint, $z.ActiveTripPoint)
        $RawList.Add($rawLine) | Out-Null

        if ($null -eq $tempRaw) { continue }

        $DiagRoot.ThermalZone.InstancesWithTemp++
        $c = Convert-TenthsKelvinToCelsius -TenthsKelvin ([uint32]$tempRaw)

        $ZoneList.Add(("{0}={1}" -f $name, $c)) | Out-Null

        $friendly = Get-FriendlyKeyFromZoneName -Text $name
        Set-IfEmpty -Table $TempsTable -Key $friendly -Value $c

        # Apply convention-based or user zone->component mapping (short name e.g. TZ01_0)
        $shortName = $name
        if ($name -match '\\([^\\]+)$') { $shortName = $Matches[1] }
        $mapping = if ($Script:UserZoneMapping.Count -gt 0) { $Script:UserZoneMapping } else { $Script:SurfaceZoneToComponent }
        if ($mapping.ContainsKey($shortName)) {
            $componentKey = $mapping[$shortName]
            if ($TempsTable.ContainsKey($componentKey)) { Set-IfEmpty -Table $TempsTable -Key $componentKey -Value $c }
        }
    }

    return @{ Count = $zones.Count }
}

function Query-LegacyProbe {
    param($DiagRoot)

    $DiagRoot.LegacyProbe.Queried = $true
    try {
        $probes = @(Get-CimInstance -ClassName Win32_TemperatureProbe -ErrorAction Stop)
        $DiagRoot.LegacyProbe.InstancesReturned = $probes.Count
        foreach ($p in $probes) {
            if ($null -ne $p.CurrentReading) {
                $DiagRoot.LegacyProbe.AnyCurrentReading = $true
                break
            }
        }
    } catch {
        # Ignore; this probe is diagnostic only
    }
}

function Query-SurfaceDrivers {
    param(
        [System.Collections.Generic.List[string]]$DriverList,
        $DiagRoot
    )

    try {
        $drivers = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop | Where-Object {
            $_.DeviceName -match 'Surface Thermal Zone Sensor|SurfaceSystemManagement|Surface Integration Service|Surface UEFI|Surface ME'
        })

        $DiagRoot.SurfaceDrivers.QuerySucceeded = $true
        $DiagRoot.SurfaceDrivers.MatchingDrivers = $drivers.Count

        foreach ($d in $drivers) {
            $DriverList.Add(("{0}|Version={1}|INF={2}" -f $d.DeviceName, $d.DriverVersion, $d.InfName)) | Out-Null
        }
    } catch {
        $DiagRoot.SurfaceDrivers.QuerySucceeded = $false
        $DiagRoot.SurfaceDrivers.QueryError = $_.Exception.Message
    }
}

function Write-HumanReadableReport {
    param(
        [hashtable]$TempsTable,
        [System.Collections.Generic.List[string]]$ZoneList,
        [System.Collections.Generic.List[string]]$DriverList,
        [string]$Summary,
        $DiagRoot
    )

    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host " Surface / Microsoft Thermal Report" -ForegroundColor Cyan
    Write-Host " $ts" -ForegroundColor Cyan
    Write-Host " (all temperatures in Celsius)" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    # 1. All thermal zone temperatures (Celsius) - every sensor, nothing missing
    Write-Host "--- All thermal zone temperatures (Celsius) ---" -ForegroundColor Yellow
    if ($ZoneList.Count -eq 0) {
        Write-Host "  (no zones reported)"
    } else {
        foreach ($z in $ZoneList) {
            $idx = $z.IndexOf('=')
            if ($idx -gt 0) {
                $namePart = $z.Substring(0, $idx)
                $tempPart = $z.Substring($idx + 1)
                $shortName = $namePart
                if ($namePart -match '\\([^\\]+)$') { $shortName = $Matches[1] }
                Write-Host ("  {0}: {1} {2}" -f $shortName, $tempPart, $degC)
            } else {
                Write-Host "  $z $degC"
            }
        }
    }
    Write-Host ""

    # 2. Component mapping (convention-based for TZ01_0, TZ02_0, etc. + name-based when zone name contains CPU/GPU/...)
    Write-Host "--- Component mapping (linked from zone codes) ---" -ForegroundColor Yellow
    Write-Host "  (TZ01=CPU, TZ02=GPU, TZ05=PCH, TZ06=Battery, TZ07/TZ08=Skin, TZ09=Exhaust per convention; edit script to change.)" -ForegroundColor DarkGray
    $labels = @(
        @{ Key = 'CPU';              Label = 'CPU' }
        @{ Key = 'GPU';              Label = 'GPU' }
        @{ Key = 'Exhaust';          Label = 'Exhaust' }
        @{ Key = 'LocalHotspot';     Label = 'Local hotspot' }
        @{ Key = 'Battery';          Label = 'Battery' }
        @{ Key = 'ChargingCircuit';  Label = 'Charging circuit' }
        @{ Key = 'Skin1';            Label = 'Skin 1' }
        @{ Key = 'Skin2';            Label = 'Skin 2' }
        @{ Key = 'Misc';             Label = 'Misc' }
        @{ Key = 'PCH';              Label = 'PCH' }
    )
    foreach ($item in $labels) {
        $val = $TempsTable[$item.Key]
        if ($null -ne $val -and $val -ne $NOT_AVAILABLE) {
            Write-Host ("  {0}: {1:N1} {2}" -f $item.Label, [double]$val, $degC)
        } else {
            Write-Host ("  {0}: N/A" -f $item.Label)
        }
    }
    Write-Host ""

    # 3. All ACPI thermal zones (raw InstanceName = Celsius)
    Write-Host "--- All ACPI thermal zones (InstanceName = Celsius) ---" -ForegroundColor Yellow
    if ($ZoneList.Count -eq 0) {
        Write-Host "  (none)"
    } else {
        foreach ($z in $ZoneList) {
            Write-Host ("  {0} {1}" -f $z, $degC)
        }
    }
    Write-Host ""

    # 4. Surface thermal/system drivers
    Write-Host "--- Surface thermal/system drivers ---" -ForegroundColor Yellow
    if ($DriverList.Count -eq 0) {
        Write-Host "  (none found)"
    } else {
        foreach ($d in $DriverList) {
            Write-Host "  $d"
        }
    }
    Write-Host ""

    # 5. Diagnostics
    Write-Host "--- Diagnostics ---" -ForegroundColor Yellow
    Write-Host "  $Summary"
    Write-Host ""
    Write-Host "  Thermal zone class exists:    $($DiagRoot.ThermalZone.ClassExists)"
    Write-Host "  Query attempted:             $($DiagRoot.ThermalZone.QueryAttempted)"
    Write-Host "  Query succeeded:             $($DiagRoot.ThermalZone.QuerySucceeded)"
    Write-Host "  Instances returned:          $($DiagRoot.ThermalZone.InstancesReturned)"
    Write-Host "  Instances with temperature:  $($DiagRoot.ThermalZone.InstancesWithTemp)"
    if ($null -ne $DiagRoot.ThermalZone.QueryError) {
        Write-Host "  Query error:                 $($DiagRoot.ThermalZone.QueryError)"
    }
    Write-Host "  Legacy probe instances:      $($DiagRoot.LegacyProbe.InstancesReturned)"
    Write-Host "  Legacy probe has readings:   $($DiagRoot.LegacyProbe.AnyCurrentReading)"
    Write-Host "  Surface drivers matched:     $($DiagRoot.SurfaceDrivers.MatchingDrivers)"
    if ($null -ne $DiagRoot.SurfaceDrivers.QueryError) {
        Write-Host "  Surface drivers error:       $($DiagRoot.SurfaceDrivers.QueryError)"
    }
    Write-Host ""
}

try {
    $source = 'NONE'
    $countDetected = 0

    $tz = Try-CollectThermalZones -TempsTable $temps -RawList $rawSensors -ZoneList $zoneList -DiagRoot $diag
    if ($tz.Count -gt 0) {
        $source = 'ACPI_THERMAL_ZONE'
        $countDetected = $tz.Count
    }

    Query-LegacyProbe -DiagRoot $diag
    Query-SurfaceDrivers -DriverList $driverList -DiagRoot $diag

    $summary = "Source=$source; " +
               "ThermalZone(class=$($diag.ThermalZone.ClassExists), attempted=$($diag.ThermalZone.QueryAttempted), ok=$($diag.ThermalZone.QuerySucceeded), instances=$($diag.ThermalZone.InstancesReturned), withTemp=$($diag.ThermalZone.InstancesWithTemp)); " +
               "LegacyProbe(instances=$($diag.LegacyProbe.InstancesReturned), anyCurrentReading=$($diag.LegacyProbe.AnyCurrentReading)); " +
               "SurfaceDrivers(ok=$($diag.SurfaceDrivers.QuerySucceeded), matches=$($diag.SurfaceDrivers.MatchingDrivers))"

    Write-HumanReadableReport -TempsTable $temps -ZoneList $zoneList -DriverList $driverList -Summary $summary -DiagRoot $diag

    exit 0
}
catch {
    $host.ui.WriteErrorLine($_.ToString())
    exit 1
}
