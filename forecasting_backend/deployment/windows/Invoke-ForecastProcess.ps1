param(
    [Parameter(Mandatory = $true)][ValidateSet('Worker', 'Maintenance')][string]$Mode,
    [Parameter(Mandatory = $true)][string]$BackendDir,
    [Parameter(Mandatory = $true)][string]$PythonExe,
    [Parameter(Mandatory = $true)][string]$LocationId
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $PythonExe -PathType Leaf)) { throw 'Python executable is unavailable.' }
if (-not (Test-Path -LiteralPath (Join-Path $BackendDir '.env') -PathType Leaf)) {
    throw 'Protected backend .env is unavailable.'
}
Set-Location -LiteralPath $BackendDir
$logDir = Join-Path $BackendDir '.runtime\logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logPath = Join-Path $logDir ('forecast-{0}-{1:yyyyMMdd-HHmmss}.log' -f $Mode.ToLowerInvariant(), (Get-Date))
$exitCode = 1
Start-Transcript -LiteralPath $logPath | Out-Null
try {
    # Python writes ordinary INFO logs to stderr. In Windows PowerShell 5.1,
    # Stop would turn those lines into terminating NativeCommandError records.
    # Scope Continue to the native invocation and decide failure by exit code.
    $nativePreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        if ($Mode -eq 'Worker') {
            & $PythonExe 'run_forecast_worker.py' '--concurrency' '1' '--poll-seconds' '5'
        } else {
            & $PythonExe 'run_forecast_maintenance.py' '--location-id' $LocationId `
                '--max-products' '10' '--max-pages' '4' '--interval-seconds' '300' '--enqueue'
        }
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $nativePreference
    }
} finally {
    Stop-Transcript | Out-Null
}
exit $exitCode
