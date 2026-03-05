<#
Universal hardware temperature collector
Uses LibreHardwareMonitor sensor library

Works on:
Dell
HP
Lenovo
Surface
custom PCs

Outputs:
CPU / GPU / motherboard / storage / battery temps
#>

param(
    [string]$LibPath = ".\LibreHardwareMonitorLib.dll"
)

if (!(Test-Path $LibPath)) {
    Write-Host ""
    Write-Host "LibreHardwareMonitorLib.dll not found."
    Write-Host "Download from:"
    Write-Host "https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases"
    Write-Host "Place the DLL next to this script."
    return
}

Add-Type -Path $LibPath

$computer = New-Object LibreHardwareMonitor.Hardware.Computer
$computer.IsCpuEnabled = $true
$computer.IsGpuEnabled = $true
$computer.IsMotherboardEnabled = $true
$computer.IsMemoryEnabled = $true
$computer.IsStorageEnabled = $true
$computer.Open()

$results = @()

foreach ($hardware in $computer.Hardware) {

    $hardware.Update()

    foreach ($sensor in $hardware.Sensors) {

        if ($sensor.SensorType -eq "Temperature") {

            $results += [pscustomobject]@{
                Timestamp     = (Get-Date).ToString("o")
                ComputerName  = $env:COMPUTERNAME
                HardwareType  = $hardware.HardwareType
                Component     = $hardware.Name
                SensorName    = $sensor.Name
                TemperatureC  = $sensor.Value
            }
        }
    }

    foreach ($sub in $hardware.SubHardware) {

        $sub.Update()

        foreach ($sensor in $sub.Sensors) {

            if ($sensor.SensorType -eq "Temperature") {

                $results += [pscustomobject]@{
                    Timestamp     = (Get-Date).ToString("o")
                    ComputerName  = $env:COMPUTERNAME
                    HardwareType  = $sub.HardwareType
                    Component     = $sub.Name
                    SensorName    = $sensor.Name
                    TemperatureC  = $sensor.Value
                }
            }
        }
    }
}

$results | Sort HardwareType, SensorName | Format-Table -AutoSize
