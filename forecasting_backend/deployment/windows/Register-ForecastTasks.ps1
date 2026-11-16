param(
    [Parameter(Mandatory = $true)][string]$PythonExe,
    [string]$BackendDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string]$LocationId = '11111111-1111-1111-1111-111111111111'
)

$ErrorActionPreference = 'Stop'
$BackendDir = (Resolve-Path -LiteralPath $BackendDir).Path
$PythonExe = (Resolve-Path -LiteralPath $PythonExe).Path
if (-not (Test-Path -LiteralPath (Join-Path $BackendDir '.env') -PathType Leaf)) {
    throw 'Configure the protected backend .env before registering tasks.'
}
$launcher = Join-Path $PSScriptRoot 'Invoke-ForecastProcess.ps1'
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw 'Forecast task launcher is unavailable.' }
$taskNames = @('InventoryPlusForecastWorker', 'InventoryPlusForecastMaintenance')
foreach ($name in $taskNames) {
    if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
        throw "Scheduled task $name already exists. Review it before making changes."
    }
}

$credential = Get-Credential -Message 'Dedicated Windows forecast service account (password is not logged)'
if ($null -eq $credential) { throw 'A service account is required.' }
$pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($credential.Password)
try {
    $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    $startup = New-ScheduledTaskTrigger -AtStartup
    $daily = New-ScheduledTaskTrigger -Daily -At '00:15'
    $settings = New-ScheduledTaskSettingsSet -Disable -StartWhenAvailable `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    foreach ($mode in @('Worker', 'Maintenance')) {
        $name = 'InventoryPlusForecast' + $mode
        $arguments = '-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "{0}" -Mode {1} -BackendDir "{2}" -PythonExe "{3}" -LocationId {4}' -f `
            $launcher, $mode, $BackendDir, $PythonExe, $LocationId
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments -WorkingDirectory $BackendDir
        Register-ScheduledTask -TaskName $name -Action $action -Trigger @($startup, $daily) `
            -Settings $settings -User $credential.UserName -Password $password `
            -Description 'Inventory Plus bounded forecast background process; registered disabled' | Out-Null
    }
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    Remove-Variable password -ErrorAction SilentlyContinue
}
Get-ScheduledTask -TaskName $taskNames | Select-Object TaskName, State
