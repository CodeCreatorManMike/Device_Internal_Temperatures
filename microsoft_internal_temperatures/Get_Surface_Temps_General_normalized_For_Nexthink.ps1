<#
.SYNOPSIS
Nexthink-ready general Microsoft / Surface laptop thermal report.

.DESCRIPTION
General Microsoft / Surface thermal inventory for models where no model-specific script is available.
Normalized for Nexthink Remote Actions with fixed outputs, structured error handling,
and stable output names.

.NOTES
Recommended Nexthink execution context: Local System
#>

param(
    [string]$IncludeDiagnostics = "true",
    [string]$MaxTextLength = "900"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -Path $env:NEXTHINK\RemoteActions\nxtremoteactions.dll

# ---- constants ----------------------------------------------------------------

$NOT_AVAILABLE = -1.0
$DefaultMaxTextLength = 900

# ---- parameter validation ------------------------------------------------------

switch ($IncludeDiagnostics.ToLowerInvariant()) {
    'true'  { $includeDiagnosticsBool = $true }
    'false' { $includeDiagnosticsBool = $false }
    default { throw "Parameter 'IncludeDiagnostics' must be 'true' or 'false'." }
}

if (-not [int]::TryParse($MaxTextLength, [ref]$parsedMaxTextLength)) {
    throw "Parameter 'MaxTextLength' must be a valid integer."
}
if ($parsedMaxTextLength -lt 100 -or $parsedMaxTextLength -gt 1024) {
    throw "Parameter 'MaxTextLength' must be between 100 and 1024."
}

# ---- output state --------------------------------------------------------------

$outputs = [ordered]@{
    Status                    = 'Error'
    Success                   = $false
    ErrorMessage              = 'Unknown error'
    Source                    = 'NONE'
    ThermalZoneClassExists    = $false
    ThermalZoneQuerySucceeded = $false
    ThermalZoneInstances      = [uint32]0
    SurfaceDriversMatched     = [uint32]0

    CpuTemperatureC           = ''
    GpuTemperatureC           = ''
    ExhaustTemperatureC       = ''
    LocalHotspotTemperatureC  = ''
    BatteryTemperatureC       = ''
    ChargingCircuitTempC      = ''
    Skin1TemperatureC         = ''
    Skin2TemperatureC         = ''
    MiscTemperatureC          = ''
    PchTemperatureC           = ''

    ZoneCount                 = [uint32]0
    ZoneSummary               = ''
    DriverSummary             = ''
    DiagnosticsSummary        = ''
    RunningAsUser             = ''
    PSVersion                 = ''
    IsAdmin                   = $false
    TimestampUtc              = ''
}

# ---- helpers ------------------------------------------------------------------

function Get-SafeString {
    param(
        [AllowNull()]
        [object]$Value,
        [int]$Limit = $DefaultMaxTextLength
    )

    if ($null -eq $Value) { return '' }

    $text = [string]$Value
    $text = $text -replace "[`r`n`t]+", ' '
    $text = $text.Trim()

    if ($text.Length -gt $Limit) {
        return $text.Substring(0, $Limit)
    }

    return $text
}

function Get-SafeTempString {
    param(
        [double]$Value
    )

    if ($Value -eq $NOT_AVAILABLE) {
        return ''
    }

    return ('{0:N1}' -f $Value)
}

function Write-AllOutputs {
    [Nxt]::WriteOutputString('Status',               (Get-SafeString $outputs.Status $parsedMaxTextLength))
    [Nxt]::WriteOutputBool('Success',                [bool]$outputs.Success)
    [Nxt]::WriteOutputString('ErrorMessage',         (Get-SafeString $outputs.ErrorMessage $parsedMaxTextLength))
    [Nxt]::WriteOutputString('Source',               (Get-SafeString $outputs.Source $parsedMaxTextLength))
    [Nxt]::WriteOutputBool('ThermalZoneClassExists', [bool]$outputs.ThermalZoneClassExists)
    [Nxt]::WriteOutputBool('ThermalZoneQuerySucceeded', [bool]$outputs.ThermalZoneQuerySucceeded)
    [Nxt]::WriteOutputUInt32('ThermalZoneInstances', [uint32]$outputs.ThermalZoneInstances)
    [Nxt]::WriteOutputUInt32('SurfaceDriversMatched',[uint32]$outputs.SurfaceDriversMatched)

    [Nxt]::WriteOutputString('CpuTemperatureC',      (Get-SafeString $outputs.CpuTemperatureC $parsedMaxTextLength))
    [Nxt]::WriteOutputString('GpuTemperatureC',      (Get-SafeString $outputs.GpuTemperatureC $parsedMaxTextLength))
    [Nxt]::WriteOutputString('ExhaustTemperatureC',  (Get-SafeString $outputs.ExhaustTemperatureC $parsedMaxTextLength))
    [Nxt]::WriteOutputString('LocalHotspotTemperatureC', (Get-SafeString $outputs.LocalHotspotTemperatureC $parsedMaxTextLength))
    [Nxt]::WriteOutputString('BatteryTemperatureC',  (Get-SafeString $outputs.BatteryTemperatureC $parsedMaxTextLength))
    [Nxt]::WriteOutputString('ChargingCircuitTempC', (Get-SafeString $outputs.ChargingCircuitTempC $parsedMaxTextLength))
    [Nxt]::WriteOutputString('Skin1TemperatureC',    (Get-SafeString $outputs.Skin1TemperatureC $parsedMaxTextLength))
    [Nxt]::WriteOutputString('Skin2TemperatureC',    (Get-SafeString $outputs.Skin2TemperatureC $parsedMaxTextLength))
    [Nxt]::WriteOutputString('MiscTemperatureC',     (Get-SafeString $outputs.MiscTemperatureC $parsedMaxTextLength))
    [Nxt]::WriteOutputString('PchTemperatureC',      (Get-SafeString $outputs.PchTemperatureC $parsedMaxTextLength))

    [Nxt]::WriteOutputUInt32('ZoneCount',            [uint32]$outputs.ZoneCount)
    [Nxt]::WriteOutputString('ZoneSummary',          (Get-SafeString $outputs.ZoneSummary $parsedMaxTextLength))
    [Nxt]::WriteOutputString('DriverSummary',        (Get-SafeString $outputs.DriverSummary $parsedMaxTextLength))
    [Nxt]::WriteOutputString('DiagnosticsSummary',   (Get-SafeString $outputs.DiagnosticsSummary $parsedMaxTextLength))
    [Nxt]::WriteOutputString('RunningAsUser',        (Get-SafeString $outputs.RunningAsUser $parsedMaxTextLength))
    [Nxt]::WriteOutputString('PSVersion',            (Get-SafeString $outputs.PSVersion $parsedMaxTextLength))
    [Nxt]::WriteOutputBool('IsAdmin',                [bool]$outputs.IsAdmin)
    [Nxt]::WriteOutputString('TimestampUtc',         (Get-SafeString $outputs.TimestampUtc $parsedMaxTextLength))
}

trap {
    $message = $_.Exception.Message
    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = $_.ToString()
    }

    $outputs.Status = 'Error'
    $outputs.Success = $false
    $outputs.ErrorMessage = Get-SafeString $message $parsedMaxTextLength

    Write-AllOutputs
    $host.ui.WriteErrorLine($_.ToString())
    exit 1
}

# ---- data structures ----------------------------------------------------------

$Script:SurfaceZoneToComponent = @{
    'TZ01_0' = 'CPU'
    'TZ02_0' = 'GPU'
    'TZ05_0' = 'PCH'
    'TZ06_0' = 'Battery'
    'TZ07_0' = 'Skin1'
    'TZ08_0' = 'Skin2'
    'TZ09_0' = 'Exhaust'
}
$Script:UserZoneMapping = @{}

$temps = @{
    CPU             = $NOT_AVAILABLE
    GPU             = $NOT_AVAILABLE
    Exhaust         = $NOT_AVAILABLE
    LocalHotspot    = $NOT_AVAILABLE
    Battery         = $NOT_AVAILABLE
    ChargingCircuit = $NOT_AVAILABLE
    Skin1           = $NOT_AVAILABLE
    Skin2           = $NOT_AVAILABLE
    Misc            = $NOT_AVAILABLE
    PCH             = $NOT_AVAILABLE
}

$rawSensors = New-Object System.Collections.Generic.List[string]
$zoneList   = New-Object System.Collections.Generic.List[string]
$driverList = New-Object System.Collections.Generic.List[string]

$diag = [ordered]@{
    TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
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

# ---- functions ----------------------------------------------------------------

function Set-IfEmpty {
    param(
        [Parameter(Mandatory = $true)] [hashtable] $Table,
        [Parameter(Mandatory = $true)] [string] $Key,
        [Parameter(Mandatory = $true)] [double] $Value
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
    param([Parameter(Mandatory = $true)] [string] $Text)

    $t = $Text.ToLowerInvariant()
    if ($t -match 'cpu|proc|processor|package')      { return 'CPU' }
    if ($t -match 'gpu|gfx|graphics|dgpu|igpu')      { return 'GPU' }
    if ($t -match 'battery|batt')                    { return 'Battery' }
    if ($t -match 'pch|platform\s*controller\s*hub') { return 'PCH' }
    if ($t -match 'skin\s*1|skin1')                  { return 'Skin1' }
    if ($t -match 'skin\s*2|skin2')                  { return 'Skin2' }
    if ($t -match 'exhaust|vent|outlet')             { return 'Exhaust' }
    if ($t -match 'charging|charger|vrm|regulator')  { return 'ChargingCircuit' }
    if ($t -match 'local|hotspot|hot\s*spot')        { return 'LocalHotspot' }
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

        $rawLine = ('ACPI|InstanceName={0}|CurrentTemperature={1}|CriticalTripPoint={2}|PassiveTripPoint={3}|ActiveTripPoint={4}' -f `
            $name, $z.CurrentTemperature, $z.CriticalTripPoint, $z.PassiveTripPoint, $z.ActiveTripPoint)
        $RawList.Add($rawLine) | Out-Null

        if ($null -eq $tempRaw) { continue }

        $DiagRoot.ThermalZone.InstancesWithTemp++
        $c = Convert-TenthsKelvinToCelsius -TenthsKelvin ([uint32]$tempRaw)
        $ZoneList.Add(('{0}={1}' -f $name, $c)) | Out-Null

        $friendly = Get-FriendlyKeyFromZoneName -Text $name
        Set-IfEmpty -Table $TempsTable -Key $friendly -Value $c

        $shortName = $name
        if ($name -match '\\([^\\]+)$') { $shortName = $Matches[1] }

        $mapping = if ($Script:UserZoneMapping.Count -gt 0) { $Script:UserZoneMapping } else { $Script:SurfaceZoneToComponent }
        if ($mapping.ContainsKey($shortName)) {
            $componentKey = $mapping[$shortName]
            if ($TempsTable.ContainsKey($componentKey)) {
                Set-IfEmpty -Table $TempsTable -Key $componentKey -Value $c
            }
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
            $DriverList.Add(('{0}|Version={1}|INF={2}' -f $d.DeviceName, $d.DriverVersion, $d.InfName)) | Out-Null
        }
    } catch {
        $DiagRoot.SurfaceDrivers.QuerySucceeded = $false
        $DiagRoot.SurfaceDrivers.QueryError = $_.Exception.Message
    }
}

# ---- main ---------------------------------------------------------------------

$source = 'NONE'
$countDetected = 0

$tz = Try-CollectThermalZones -TempsTable $temps -RawList $rawSensors -ZoneList $zoneList -DiagRoot $diag
if ($tz.Count -gt 0) {
    $source = 'ACPI_THERMAL_ZONE'
    $countDetected = $tz.Count
}

Query-LegacyProbe -DiagRoot $diag
Query-SurfaceDrivers -DriverList $driverList -DiagRoot $diag

$summary = "Source=$source; ThermalZone(ok=$($diag.ThermalZone.QuerySucceeded), instances=$($diag.ThermalZone.InstancesReturned)); SurfaceDrivers(matches=$($diag.SurfaceDrivers.MatchingDrivers))"

$outputs.Status = 'Success'
$outputs.Success = $true
$outputs.ErrorMessage = ''
$outputs.Source = $source
$outputs.ThermalZoneClassExists = [bool]$diag.ThermalZone.ClassExists
$outputs.ThermalZoneQuerySucceeded = [bool]$diag.ThermalZone.QuerySucceeded
$outputs.ThermalZoneInstances = [uint32]$diag.ThermalZone.InstancesReturned
$outputs.SurfaceDriversMatched = [uint32]$diag.SurfaceDrivers.MatchingDrivers

$outputs.CpuTemperatureC = Get-SafeTempString $temps.CPU
$outputs.GpuTemperatureC = Get-SafeTempString $temps.GPU
$outputs.ExhaustTemperatureC = Get-SafeTempString $temps.Exhaust
$outputs.LocalHotspotTemperatureC = Get-SafeTempString $temps.LocalHotspot
$outputs.BatteryTemperatureC = Get-SafeTempString $temps.Battery
$outputs.ChargingCircuitTempC = Get-SafeTempString $temps.ChargingCircuit
$outputs.Skin1TemperatureC = Get-SafeTempString $temps.Skin1
$outputs.Skin2TemperatureC = Get-SafeTempString $temps.Skin2
$outputs.MiscTemperatureC = Get-SafeTempString $temps.Misc
$outputs.PchTemperatureC = Get-SafeTempString $temps.PCH

$outputs.ZoneCount = [uint32]$zoneList.Count
$outputs.ZoneSummary = if ($zoneList.Count -gt 0) {
    Get-SafeString ($zoneList -join '; ') $parsedMaxTextLength
} else {
    ''
}

$outputs.DriverSummary = if ($driverList.Count -gt 0) {
    Get-SafeString ($driverList -join '; ') $parsedMaxTextLength
} else {
    ''
}

if ($includeDiagnosticsBool) {
    $outputs.DiagnosticsSummary = Get-SafeString $summary $parsedMaxTextLength
    $outputs.RunningAsUser = Get-SafeString $diag.RunningAsUser $parsedMaxTextLength
    $outputs.PSVersion = Get-SafeString $diag.PSVersion $parsedMaxTextLength
    $outputs.IsAdmin = [bool]$diag.IsAdmin
    $outputs.TimestampUtc = Get-SafeString $diag.TimestampUtc $parsedMaxTextLength
} else {
    $outputs.DiagnosticsSummary = ''
    $outputs.RunningAsUser = ''
    $outputs.PSVersion = ''
    $outputs.IsAdmin = $false
    $outputs.TimestampUtc = ''
}

Write-AllOutputs
exit 0
