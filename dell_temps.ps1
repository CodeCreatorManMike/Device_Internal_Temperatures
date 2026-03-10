<#
.SYNOPSIS
    All temperature data: LibreHardwareMonitor (every sensor, Value/Min/Max) + WMI (every Dell/Windows temp source).
    Key : Value for each. No exceptions - everything that can be read is output (duplicates allowed).
#>
$ErrorActionPreference = 'SilentlyContinue'

$ReleaseZip = "https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases/download/v0.9.6/LibreHardwareMonitor.zip"
$Desktop   = [Environment]::GetFolderPath("Desktop")
$TargetDir = Join-Path $Desktop "LibreHardwareMonitor-Release"
$Dll       = $null

if (Test-Path $TargetDir) {
    $found = Get-ChildItem -Path $TargetDir -Recurse -Filter "LibreHardwareMonitorLib.dll" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $Dll = $found.FullName }
}
if (!$Dll) {
    Write-Host "Downloading LibreHardwareMonitor release (one-time)..." -ForegroundColor Cyan
    $zipPath = Join-Path $env:TEMP "LibreHardwareMonitor.zip"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $ReleaseZip -OutFile $zipPath -UseBasicParsing
    } catch { Write-Error "Download failed: $_"; exit 1 }
    if (!(Test-Path $TargetDir)) { New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null }
    Expand-Archive -Path $zipPath -DestinationPath $TargetDir -Force
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    $found = Get-ChildItem -Path $TargetDir -Recurse -Filter "LibreHardwareMonitorLib.dll" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $Dll = $found.FullName }
}
if (!$Dll) { Write-Error "LibreHardwareMonitorLib.dll not found."; exit 1 }

Unblock-File -Path $Dll -ErrorAction SilentlyContinue
try { Add-Type -Path $Dll } catch { Write-Error "Failed to load DLL: $_"; exit 1 }

$Computer = New-Object LibreHardwareMonitor.Hardware.Computer
$Computer.IsCpuEnabled = $true
$Computer.IsGpuEnabled = $true
$Computer.IsMemoryEnabled = $true
$Computer.IsMotherboardEnabled = $true
$Computer.IsControllerEnabled = $true
$Computer.IsStorageEnabled = $true
$Computer.IsNetworkEnabled = $true
try { $Computer.IsPsuEnabled = $true } catch { }
try { $Computer.IsBatteryEnabled = $true } catch { }
$Computer.Open()

function Get-CompName { param ($s); try { if ($s.Hardware -and $s.Hardware.Name) { return $s.Hardware.Name } } catch { }; return "Device" }

Write-Host "`n========== LIBREHARDWAREMONITOR - ALL TEMPERATURES (Value, Min, Max) ==========`n" -ForegroundColor Cyan
function Get-AllTempSensors {
    param ([object]$Hw, [int]$Depth = 0)
    if ($Depth -gt 15) { return }
    try { $Hw.Update() } catch { }
    if ($Hw.Sensors) {
        foreach ($s in $Hw.Sensors) {
            try {
                $st = $s.SensorType.ToString()
                if ($st -notlike "Temperature*") { continue }
                $comp = Get-CompName -s $s
                $keyBase = "$comp | $($s.Name)"
                if ($null -ne $s.Value) { Write-Host "LibreHardwareMonitor | $keyBase : $([math]::Round([double]$s.Value, 2))" }
                if ($null -ne $s.Min)   { Write-Host "LibreHardwareMonitor | $keyBase (Min) : $([math]::Round([double]$s.Min, 2))" }
                if ($null -ne $s.Max)   { Write-Host "LibreHardwareMonitor | $keyBase (Max) : $([math]::Round([double]$s.Max, 2))" }
            } catch { }
        }
    }
    if ($Hw.SubHardware) {
        foreach ($sub in $Hw.SubHardware) { Get-AllTempSensors -Hw $sub -Depth ($Depth + 1) }
    }
}
try {
    foreach ($H in $Computer.Hardware) { Get-AllTempSensors -Hw $H }
} finally {
    try { $Computer.Close() } catch { }
}

Write-Host "`n========== WMI - ALL TEMPERATURE SOURCES (Dell + Windows) ==========`n" -ForegroundColor Cyan

# ACPI thermal zones (root\wmi) - tenths of Kelvin
try {
    $zones = Get-CimInstance -Namespace 'root\wmi' -ClassName 'MSAcpi_ThermalZoneTemperature' -ErrorAction Stop
    foreach ($z in $zones) {
        $c = [math]::Round(($z.CurrentTemperature / 10.0) - 273.15, 2)
        $k = $z.InstanceName -replace '_0$', '' -replace '^ACPI\\', ''
        Write-Host "WMI | root\wmi\MSAcpi_ThermalZoneTemperature | $k : $c"
    }
} catch { }

# CIM_TemperatureSensor (root\cimv2)
try {
    $cim = Get-CimInstance -Namespace 'root\cimv2' -ClassName 'CIM_TemperatureSensor' -ErrorAction Stop
    foreach ($t in $cim) {
        $raw = $t.CurrentReading
        if ($null -eq $raw) { continue }
        $c = if ([math]::Abs($raw) -lt 200) { [math]::Round($raw / 10.0, 2) } else { [math]::Round($raw, 2) }
        $k = if ($t.Name) { $t.Name } else { $t.DeviceID }
        Write-Host "WMI | root\cimv2\CIM_TemperatureSensor | $k : $c"
    }
} catch { }

# Win32_PerfFormattedData_Counters_ThermalZoneInformation
try {
    $perf = Get-CimInstance -Namespace 'root\cimv2' -ClassName 'Win32_PerfFormattedData_Counters_ThermalZoneInformation' -ErrorAction Stop
    foreach ($p in $perf) {
        $v = $p.Temperature
        if ($null -eq $v) { continue }
        $nm = $p.Name -replace '\s*\(.*\)\s*$', ''
        Write-Host "WMI | root\cimv2\ThermalZoneInformation | $nm : $v"
    }
} catch { }

# Enumerate any *Temperature* or *Thermal* classes in root\cimv2 and query
try {
    $classes = Get-CimClass -Namespace 'root\cimv2' -ErrorAction Stop | Where-Object { $_.CimClassName -match 'Temperature|Thermal' }
    foreach ($cl in $classes) {
        try {
            $instances = Get-CimInstance -Namespace 'root\cimv2' -ClassName $cl.CimClassName -ErrorAction Stop
            foreach ($i in $instances) {
                $props = $i.CimInstanceProperties | Where-Object { $_.Name -match 'Temperature|Reading|Current|Value' -and $null -ne $_.Value }
                foreach ($prop in $props) {
                    $val = $prop.Value
                    if ($val -match '^\s*-?\d+(\.\d+)?\s*$') { $val = [math]::Round([double]$val, 2) }
                    Write-Host "WMI | root\cimv2\$($cl.CimClassName) | $($i.InstanceName)_$($prop.Name) : $val"
                }
            }
        } catch { }
    }
} catch { }

# root\wmi - any thermal/temperature class
try {
    $wmiClasses = Get-CimClass -Namespace 'root\wmi' -ErrorAction Stop | Where-Object { $_.CimClassName -match 'Temperature|Thermal' }
    foreach ($cl in $wmiClasses) {
        try {
            $instances = Get-CimInstance -Namespace 'root\wmi' -ClassName $cl.CimClassName -ErrorAction Stop
            foreach ($i in $instances) {
                $props = $i.CimInstanceProperties | Where-Object { $_.Name -match 'Temperature|Reading|Current' -and $null -ne $_.Value }
                foreach ($prop in $props) {
                    $val = $prop.Value
                    if ($val -is [int] -and $val -gt 1000) { $val = [math]::Round(($val / 10.0) - 273.15, 2) }
                    Write-Host "WMI | root\wmi\$($cl.CimClassName) | $($i.InstanceName)_$($prop.Name) : $val"
                }
            }
        } catch { }
    }
} catch { }

# Dell root\dcim\sysman - DCIM_NumericSensor (temperature BaseUnits 2=C, 3=F, 4=K)
try {
    $ns = Get-CimInstance -Namespace 'root\dcim\sysman' -ClassName 'DCIM_NumericSensor' -ErrorAction Stop
    $tempUnits = 2, 3, 4
    foreach ($s in $ns) {
        $name = if ($s.ElementName) { $s.ElementName } else { $s.InstanceID }
        $isTemp = ($s.BaseUnits -in $tempUnits) -or ($name -match 'temp|thermal|Temperature')
        if (-not $isTemp) { continue }
        $raw = $s.CurrentReading
        if ($null -eq $raw) { continue }
        $mod = if ($null -ne $s.UnitModifier) { [math]::Pow(10, [int]$s.UnitModifier) } else { 1 }
        $v = $raw * $mod
        switch ($s.BaseUnits) {
            3 { $c = [math]::Round(($v - 32) * 5/9, 2) }
            4 { $c = [math]::Round($v - 273.15, 2) }
            default { $c = [math]::Round($v, 2) }
        }
        Write-Host "WMI | root\dcim\sysman\DCIM_NumericSensor | $name : $c"
    }
} catch { }

# Dell root\dcim\sysman - DCIM_ThermalInformation
try {
    $th = Get-CimInstance -Namespace 'root\dcim\sysman' -ClassName 'DCIM_ThermalInformation' -ErrorAction Stop
    foreach ($t in $th) {
        $name = if ($t.AttributeName) { $t.AttributeName } else { $t.InstanceID }
        $cv = $t.CurrentValue
        if ($null -eq $cv) { continue }
        $val = if ($cv -is [string]) { $cv } else { ($cv -join ', ') }
        Write-Host "WMI | root\dcim\sysman\DCIM_ThermalInformation | $name : $val"
    }
} catch { }

# Dell root\dcim\sysman - DCIM_Sensor (any numeric reading in temp range)
try {
    $sens = Get-CimInstance -Namespace 'root\dcim\sysman' -ClassName 'DCIM_Sensor' -ErrorAction Stop
    foreach ($s in $sens) {
        $name = if ($s.ElementName) { $s.ElementName } else { $s.InstanceID }
        $r = $s.CurrentReading; if ($null -eq $r) { $r = $s.CurrentState }
        if ($null -eq $r) { continue }
        if ($r -match '^\s*-?\d+(\.\d+)?\s*$') {
            $n = [double]$r
            if ($n -ge -50 -and $n -le 150) { Write-Host "WMI | root\dcim\sysman\DCIM_Sensor | $name : $([math]::Round($n, 2))" }
        } else { Write-Host "WMI | root\dcim\sysman\DCIM_Sensor | $name : $r" }
    }
} catch { }

# Dell root\dcim\sysman - enumerate all classes, query those with Temperature/Thermal in name
try {
    $allClasses = Get-CimClass -Namespace 'root\dcim\sysman' -ErrorAction Stop
    $thermalClasses = $allClasses | Where-Object { $_.CimClassName -match 'Temperature|Thermal|Sensor' }
    foreach ($cl in $thermalClasses) {
        try {
            $instances = Get-CimInstance -Namespace 'root\dcim\sysman' -ClassName $cl.CimClassName -ErrorAction Stop
            foreach ($i in $instances) {
                foreach ($prop in $i.CimInstanceProperties) {
                    if ($null -eq $prop.Value) { continue }
                    if ($prop.Name -match 'CurrentValue|CurrentReading|Temperature|Value') {
                        $val = $prop.Value
                        if ($val -is [array]) { $val = $val -join ',' }
                        Write-Host "WMI | root\dcim\sysman\$($cl.CimClassName) | $($i.InstanceID)_$($prop.Name) : $val"
                    }
                }
            }
        } catch { }
    }
} catch { }

# Dell root\dcim\sysman\biosattributes - any numeric attribute that could be temp
try {
    $bios = Get-CimInstance -Namespace 'root\dcim\sysman\biosattributes' -ClassName 'IntegerAttribute' -ErrorAction Stop
    foreach ($b in $bios) {
        $name = if ($b.AttributeName) { $b.AttributeName } else { $b.InstanceID }
        if ($name -match 'temp|thermal|Temp|Temperature') {
            Write-Host "WMI | root\dcim\sysman\biosattributes\IntegerAttribute | $name : $($b.CurrentValue)"
        }
    }
} catch { }

# Dell root\dellomci - all classes that might have temperature
try {
    $omciClasses = Get-CimClass -Namespace 'root\dellomci' -ErrorAction Stop | Where-Object { $_.CimClassName -notlike '__*' }
    foreach ($cl in $omciClasses) {
        try {
            $instances = Get-CimInstance -Namespace 'root\dellomci' -ClassName $cl.CimClassName -ErrorAction Stop
            foreach ($i in $instances) {
                foreach ($prop in $i.CimInstanceProperties) {
                    if ($null -eq $prop.Value) { continue }
                    if ($prop.Name -match 'Temperature|Temp|Reading|Value|Current') {
                        Write-Host "WMI | root\dellomci\$($cl.CimClassName) | $($i.InstanceName)_$($prop.Name) : $($prop.Value)"
                    }
                }
            }
        } catch { }
    }
} catch { }

# root\cimv2\Power - Battery temperature if present
try {
    $bat = Get-CimInstance -Namespace 'root\cimv2' -ClassName 'Win32_Battery' -ErrorAction Stop
    foreach ($b in $bat) {
        if ($null -ne $b.DesignTemperature) { Write-Host "WMI | root\cimv2\Win32_Battery | DesignTemperature : $($b.DesignTemperature)" }
    }
} catch { }

Write-Host "`n========== END ==========`n" -ForegroundColor Cyan
