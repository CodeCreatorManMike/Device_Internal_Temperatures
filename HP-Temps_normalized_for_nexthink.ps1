<#
.SYNOPSIS:
Collects device ACPI thermal zone temperatures and outputs fixed fields for Nexthink.

.DESCRIPTION:
Queries Windows WMI class MSAcpi_ThermalZoneTemperature (root\wmi) to retrieve ACPI thermal zone
temperatures (when exposed by the device firmware/drivers).

Converts temperatures from tenths of Kelvin to Celsius, maps known ACPI zone instance names to friendly
labels (CPU, GPU, Battery, etc.), and writes a fixed set of output fields to Nexthink.

If a sensor is not available on a device, its output is set to -1.

.FUNCTIONALITY:
Data collection

.INPUTS:
None

.OUTPUTS:
- TempCPU_C
- TempGPU_C
- TempExhaust_C
- TempLocalHotspot_C
- TempBattery_C
- TempChargingCircuit_C
- TempSkin1_C
- TempSkin2_C
- TempMisc_C
- TempPCH_C
- SensorsDetected_Count
- SensorsRaw_List

.NOTES:
Context:            InteractiveUser
Version:            1.0.0.0 - Initial version
Last Generated:     21 Jan 2026
#>

# Load Nexthink output writer:
Add-Type -Path "$env:NEXTHINK\RemoteActions\nxtremoteactions.dll"

# Default error handler recommended for Nexthink Remote Actions:
trap {
    $host.ui.WriteErrorLine($_.ToString())
    exit 1
}


# Constants / helpers:

# Fixed “not available” value for missing sensors:
$NOT_AVAILABLE = -1.0

# Raw ACPI name -> Friendly label:
$Map = @{
    "ACPI\ThermalZone\CPUZ_0" = "CPU"
    "ACPI\ThermalZone\GFXZ_0" = "GPU"
    "ACPI\ThermalZone\EXTZ_0" = "Exhaust"
    "ACPI\ThermalZone\LOCZ_0" = "LocalHotspot"
    "ACPI\ThermalZone\BATZ_0" = "Battery"
    "ACPI\ThermalZone\CHGZ_0" = "ChargingCircuit"
    "ACPI\ThermalZone\SK1Z_0" = "Skin1"
    "ACPI\ThermalZone\SK2Z_0" = "Skin2"
    "ACPI\ThermalZone\MSHZ_0" = "Misc"
    "ACPI\ThermalZone\PCHZ_0" = "PCH"
}

function Convert-ToCelsius {
    param([int]$TenthsKelvin)
    # MSAcpi_ThermalZoneTemperature is typically in tenths of Kelvin
    return [math]::Round(($TenthsKelvin / 10.0) - 273.15, 1)
}

# We keep a fixed output schema by predefining all expected temperatures:
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


# Main

try {
    # Query WMI (may return 0 objects on some devices):
    $sensors = Get-CimInstance -Namespace "root\wmi" -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop

    # Build a raw list for troubleshooting/visibility (kept small):
    $rawNames = @()

    foreach ($s in $sensors) {
        $raw = [string]$s.InstanceName
        $rawNames += $raw

        if (-not $s.CurrentTemperature) { continue }

        $c = Convert-ToCelsius -TenthsKelvin $s.CurrentTemperature

        # Map raw -> friendly “key”:
        if ($Map.ContainsKey($raw)) {
            $friendlyKey = $Map[$raw]
            # Only write into our fixed schema keys
            if ($temps.ContainsKey($friendlyKey)) {
                $temps[$friendlyKey] = [float]$c
            }
        }
    }

    # Write fixed outputs (float fields):
    [Nxt]::WriteOutputFloat("TempCPU_C",$temps.CPU)
    [Nxt]::WriteOutputFloat("TempGPU_C",$temps.GPU)
    [Nxt]::WriteOutputFloat("TempExhaust_C",$temps.Exhaust)
    [Nxt]::WriteOutputFloat("TempLocalHotspot_C",$temps.LocalHotspot)
    [Nxt]::WriteOutputFloat("TempBattery_C",$temps.Battery)
    [Nxt]::WriteOutputFloat("TempChargingCircuit_C",$temps.ChargingCircuit)
    [Nxt]::WriteOutputFloat("TempSkin1_C",$temps.Skin1)
    [Nxt]::WriteOutputFloat("TempSkin2_C",$temps.Skin2)
    [Nxt]::WriteOutputFloat("TempMisc_C",$temps.Misc)
    [Nxt]::WriteOutputFloat("TempPCH_C",$temps.PCH)

    # Helpful meta outputs:
    $count = 0
    if ($sensors) { $count = @($sensors).Count }
    [Nxt]::WriteOutputUInt32("SensorsDetected_Count", [uint32]$count)

    # Keep under Nexthink string size limits: truncate defensively:
    $rawList = ($rawNames | Select-Object -First 30) -join "; "
    if ($rawList.Length -gt 900) { $rawList = $rawList.Substring(0, 900) }
    [Nxt]::WriteOutputString("SensorsRaw_List", $rawList)

    exit 0
}
catch {
    $host.ui.WriteErrorLine($_.ToString())
    exit 1
}

