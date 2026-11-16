param(
    [switch]$ApprovedFiveProductTrial,
    [switch]$AcknowledgeExistingCursor,
    [Parameter(Mandatory = $true)][string]$PythonExe,
    [string]$BackendDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string]$LocationId = '11111111-1111-1111-1111-111111111111'
)

$ErrorActionPreference = 'Stop'
if (-not $ApprovedFiveProductTrial) {
    throw 'The five-product enqueue and worker trial requires explicit approval.'
}
$BackendDir = (Resolve-Path -LiteralPath $BackendDir).Path
$PythonExe = (Resolve-Path -LiteralPath $PythonExe).Path
$LocationId = ([guid]::Parse($LocationId)).ToString()
$runtimeDir = Join-Path $BackendDir '.runtime'
New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
$statePath = Join-Path $runtimeDir ("five-product-trial-$LocationId.json")
$lockPath = "$statePath.lock"

function Save-TrialState($value) {
    $temporary = "$statePath.tmp-$([guid]::NewGuid().ToString('N'))"
    $backup = "$statePath.bak-$([guid]::NewGuid().ToString('N'))"
    try {
        $json = $value | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($temporary, $json, (New-Object System.Text.UTF8Encoding($false)))
        if ([System.IO.File]::Exists($statePath)) {
            [System.IO.File]::Replace($temporary, $statePath, $backup)
        } else {
            [System.IO.File]::Move($temporary, $statePath)
        }
    } finally {
        if ([System.IO.File]::Exists($temporary)) { [System.IO.File]::Delete($temporary) }
        if ([System.IO.File]::Exists($backup)) { [System.IO.File]::Delete($backup) }
    }
}

function Invoke-ForecastChild([string[]]$CommandArguments, [string]$LogPrefix) {
    $stdoutPath = "$LogPrefix.stdout.log"
    $stderrPath = "$LogPrefix.stderr.log"
    Write-Host "child_stdout_log=$stdoutPath child_stderr_log=$stderrPath"
    # Separate redirection avoids PowerShell 5.1 turning normal Python stderr
    # logging into a terminating NativeCommandError under Stop.
    $process = Start-Process -FilePath $PythonExe -ArgumentList $CommandArguments `
        -WorkingDirectory $BackendDir -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $stdoutLines = @(Get-Content -LiteralPath $stdoutPath -ErrorAction Stop)
    $stderrLines = @(Get-Content -LiteralPath $stderrPath -ErrorAction Stop)
    foreach ($line in $stderrLines) { Write-Host $line }
    foreach ($line in $stdoutLines) { Write-Host $line }
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout = $stdoutLines
        StdoutPath = $stdoutPath
        StderrPath = $stderrPath
    }
}

$trialLock = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate,
    [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
try {
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if ($state.phase -eq 'complete') {
        Write-Host 'This five-product trial already finished. No new maintenance or worker process was started.'
        return
    }
    if ($state.phase -ne 'workers') {
        throw "A prior trial stopped during maintenance. Review $statePath and its logs before starting another batch; no new work was started."
    }
    Write-Host 'Resuming only the previously recorded job IDs; no new maintenance batch will run.'
} else {
    $cursorPath = Join-Path $runtimeDir 'forecast-maintenance.json'
    if ((Test-Path -LiteralPath $cursorPath -PathType Leaf) -and -not $AcknowledgeExistingCursor) {
        $priorCursor = (Get-Content -LiteralPath $cursorPath -Raw | ConvertFrom-Json).PSObject.Properties[$LocationId]
        if ($null -ne $priorCursor -and -not [string]::IsNullOrWhiteSpace([string]$priorCursor.Value)) {
            throw 'A maintenance cursor exists without a trial checkpoint. Review the prior attempt and queued jobs, then use -AcknowledgeExistingCursor to start the next bounded batch.'
        }
    }
    $runId = [guid]::NewGuid().ToString('N')
    $state = [ordered]@{
        phase = 'maintenance_started'
        location_id = $LocationId
        run_id = $runId
        visited = 0
        queued_job_ids = @()
        processed_job_ids = @()
    }
    Save-TrialState $state
    $maintenance = Invoke-ForecastChild -CommandArguments @(
        'run_forecast_maintenance.py', '--location-id', $LocationId,
        '--max-products', '5', '--max-pages', '1', '--enqueue', '--report-json-stdout'
    ) -LogPrefix (Join-Path $runtimeDir "five-product-trial-$runId-maintenance")
    if ($maintenance.ExitCode -ne 0) {
        $state.phase = 'maintenance_failed'
        Save-TrialState $state
        throw "Maintenance exited with code $($maintenance.ExitCode); no workers were started."
    }
    $reportLines = @($maintenance.Stdout | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($reportLines.Count -ne 1) {
        throw 'Expected exactly one machine-readable bounded maintenance report on stdout; no workers were started.'
    }
    $report = $reportLines[0] | ConvertFrom-Json
    if (-not $report.PSObject.Properties['visited'] -or -not $report.PSObject.Properties['queued'] -or
        -not $report.PSObject.Properties['queued_job_ids']) {
        throw 'Maintenance report is missing required trial fields; no workers were started.'
    }
    $jobs = @($report.queued_job_ids | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        ForEach-Object { ([guid]::Parse([string]$_)).ToString() })
    if ([int]$report.visited -lt 0 -or [int]$report.visited -gt 5 -or
        $jobs.Count -gt [int]$report.visited -or $jobs.Count -ne [int]$report.queued -or
        @($jobs | Select-Object -Unique).Count -ne $jobs.Count) {
        throw 'Maintenance report exceeds or contradicts the five-product bound; no workers were started.'
    }
    $state.visited = [int]$report.visited
    $state.queued_job_ids = $jobs
    $state.phase = 'workers'
    Save-TrialState $state
    Write-Host ("trial_visited={0} trial_queued={1} jobs_to_process={2}" -f `
        $state.visited, $report.queued, $jobs.Count)
}

foreach ($jobId in @($state.queued_job_ids)) {
    if (@($state.processed_job_ids) -contains $jobId) { continue }
    $worker = Invoke-ForecastChild -CommandArguments @(
        'run_forecast_worker.py', '--job-id', $jobId, '--max-jobs', '1', '--concurrency', '1'
    ) -LogPrefix (Join-Path $runtimeDir "five-product-trial-$($state.run_id)-worker-$jobId")
    if ($worker.ExitCode -ne 0) {
        throw "Worker exited with code $($worker.ExitCode) for job $jobId. The trial state retains this job for a controlled retry."
    }
    $state.processed_job_ids = @($state.processed_job_ids) + @($jobId)
    Save-TrialState $state
}
$state.phase = 'complete'
Save-TrialState $state
Write-Host 'Trial finished. Verify each job status and result through read-only SQL.'
} finally {
    $trialLock.Dispose()
}
