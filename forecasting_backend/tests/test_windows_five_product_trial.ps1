$ErrorActionPreference = 'Stop'
$trialScript = (Resolve-Path (Join-Path $PSScriptRoot '..\deployment\windows\Invoke-FiveProductForecastTrial.ps1')).Path
$launcherScript = (Resolve-Path (Join-Path $PSScriptRoot '..\deployment\windows\Invoke-ForecastProcess.ps1')).Path
$pythonExe = (Get-Command python -ErrorAction Stop).Source
$locationId = '11111111-1111-1111-1111-111111111111'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("InventoryPlusForecastTrialTests-$([guid]::NewGuid().ToString('N'))")
$jobIds = @(
    '00000000-0000-4000-8000-000000000001',
    '00000000-0000-4000-8000-000000000002',
    '00000000-0000-4000-8000-000000000003',
    '00000000-0000-4000-8000-000000000004',
    '00000000-0000-4000-8000-000000000005'
)

function Assert-Equal($actual, $expected, [string]$label) {
    if ($actual -ne $expected) { throw "$label`: expected '$expected', got '$actual'" }
}
function New-Fixture([string]$name) {
    $path = Join-Path $testRoot $name
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $path '.env') -Value 'fixture only' -Encoding Ascii
    @'
import json, os, pathlib, sys
with pathlib.Path('maintenance_calls.txt').open('a') as output:
    output.write('called\n')
print('2026-11-14 INFO fake maintenance request returned 200', file=sys.stderr)
args = sys.argv[1:]
if '--report-json-stdout' in args and (args[args.index('--max-products') + 1] != '5' or args[args.index('--max-pages') + 1] != '1'):
    print('ERROR trial bound was not passed to maintenance', file=sys.stderr)
    sys.exit(97)
if int(os.getenv('FORECAST_TEST_MAINT_EXIT', '0')):
    print('ERROR fake maintenance failure', file=sys.stderr)
jobs = [x for x in os.getenv('FORECAST_TEST_JOBS', '').split(',') if x]
print(json.dumps({'visited': int(os.getenv('FORECAST_TEST_VISITED', '5')),
                  'queued': len(jobs), 'queued_job_ids': jobs}), flush=True)
sys.exit(int(os.getenv('FORECAST_TEST_MAINT_EXIT', '0')))
'@ | Set-Content -LiteralPath (Join-Path $path 'run_forecast_maintenance.py') -Encoding Ascii
    @'
import os, pathlib, sys
args = sys.argv[1:]
job_id = args[args.index('--job-id') + 1] if '--job-id' in args else 'none'
with pathlib.Path('worker_calls.txt').open('a') as output:
    output.write(job_id + ' concurrency=' + (args[args.index('--concurrency') + 1] if '--concurrency' in args else '?') + '\n')
print('2026-11-14 INFO fake worker', file=sys.stderr)
if job_id == os.getenv('FORECAST_TEST_WORKER_FAIL_ID'):
    sys.exit(17)
sys.exit(int(os.getenv('FORECAST_TEST_WORKER_EXIT', '0')))
'@ | Set-Content -LiteralPath (Join-Path $path 'run_forecast_worker.py') -Encoding Ascii
    return $path
}
function Read-State([string]$path) {
    Get-Content -LiteralPath (Join-Path $path ".runtime\five-product-trial-$locationId.json") -Raw | ConvertFrom-Json
}
function Call-Trial([string]$path) {
    & $trialScript -ApprovedFiveProductTrial -PythonExe $pythonExe -BackendDir $path -LocationId $locationId
}
function Expect-TrialFailure([string]$path, [string]$contains) {
    try {
        Call-Trial $path
        throw 'Expected a trial failure.'
    } catch {
        if ($_.Exception.Message -eq 'Expected a trial failure.' -or
            -not $_.Exception.Message.Contains($contains)) { throw }
    }
}

New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
try {
    $env:FORECAST_TEST_MAINT_EXIT = '0'
    $env:FORECAST_TEST_WORKER_EXIT = '0'
    $env:FORECAST_TEST_VISITED = '5'

    # Exit 0 plus INFO on stderr is success; JSON remains on stdout.
    $case = New-Fixture 'stderr-info-and-json'
    $env:FORECAST_TEST_JOBS = $jobIds[0]
    Call-Trial $case
    Assert-Equal (Read-State $case).phase 'complete' 'INFO stderr completion'
    Assert-Equal ((Get-Content (Join-Path $case 'worker_calls.txt')).Count) 1 'one job dispatched'
    $stderrLog = @(Get-ChildItem (Join-Path $case '.runtime') -Filter '*maintenance.stderr.log')
    Assert-Equal $stderrLog.Count 1 'separate stderr log'
    if (-not (Get-Content $stderrLog[0].FullName -Raw).Contains('INFO fake maintenance')) {
        throw 'INFO stderr line was lost.'
    }
    Call-Trial $case
    Assert-Equal ((Get-Content (Join-Path $case 'maintenance_calls.txt')).Count) 1 'completed retry must not enqueue'
    Write-Host 'PASS: exit 0, INFO stderr, JSON/job ID, completed retry'

    $case = New-Fixture 'maintenance-failure'
    $env:FORECAST_TEST_MAINT_EXIT = '1'
    Expect-TrialFailure $case 'Maintenance exited with code 1'
    Assert-Equal (Read-State $case).phase 'maintenance_failed' 'maintenance failure checkpoint'
    $stderrLog = @(Get-ChildItem (Join-Path $case '.runtime') -Filter '*maintenance.stderr.log')
    if (-not (Get-Content $stderrLog[0].FullName -Raw).Contains('ERROR fake maintenance failure')) {
        throw 'Maintenance error diagnostic was lost.'
    }
    if (Test-Path (Join-Path $case 'worker_calls.txt')) { throw 'Worker ran after maintenance failure.' }
    Expect-TrialFailure $case 'prior trial stopped during maintenance'
    Assert-Equal ((Get-Content (Join-Path $case 'maintenance_calls.txt')).Count) 1 'failure retry must not enqueue'
    $env:FORECAST_TEST_MAINT_EXIT = '0'
    Write-Host 'PASS: exit 1 stops workers and prevents unsafe rerun'

    $case = New-Fixture 'no-jobs'
    $env:FORECAST_TEST_JOBS = ''
    Call-Trial $case
    Assert-Equal (Read-State $case).phase 'complete' 'no-jobs completion'
    if (Test-Path (Join-Path $case 'worker_calls.txt')) { throw 'Worker ran with no queued jobs.' }
    Write-Host 'PASS: no jobs queued'

    $case = New-Fixture 'existing-cursor'
    New-Item -ItemType Directory -Path (Join-Path $case '.runtime') -Force | Out-Null
    ('{"' + $locationId + '":"00000000-0000-4000-8000-000000000099"}') |
        Set-Content -LiteralPath (Join-Path $case '.runtime\forecast-maintenance.json') -Encoding Ascii
    Expect-TrialFailure $case 'maintenance cursor exists without a trial checkpoint'
    if (Test-Path (Join-Path $case 'maintenance_calls.txt')) { throw 'Existing cursor triggered an unapproved new batch.' }
    & $trialScript -ApprovedFiveProductTrial -AcknowledgeExistingCursor -PythonExe $pythonExe `
        -BackendDir $case -LocationId $locationId
    Assert-Equal ((Get-Content (Join-Path $case 'maintenance_calls.txt')).Count) 1 'acknowledged next batch'
    Write-Host 'PASS: ambiguous prior cursor requires explicit acknowledgment'

    $case = New-Fixture 'invalid-sixth-product'
    $env:FORECAST_TEST_VISITED = '6'
    $env:FORECAST_TEST_JOBS = $jobIds[0]
    Expect-TrialFailure $case 'exceeds or contradicts the five-product bound'
    if (Test-Path (Join-Path $case 'worker_calls.txt')) { throw 'Worker ran after an invalid six-product report.' }
    $env:FORECAST_TEST_VISITED = '5'
    Write-Host 'PASS: six-product report cannot dispatch workers'

    $case = New-Fixture 'five-jobs'
    $env:FORECAST_TEST_JOBS = $jobIds -join ','
    Call-Trial $case
    $calls = @(Get-Content (Join-Path $case 'worker_calls.txt'))
    Assert-Equal $calls.Count 5 'five-job dispatch bound'
    foreach ($i in 0..4) { Assert-Equal $calls[$i] "$($jobIds[$i]) concurrency=1" 'job ID and concurrency' }
    Write-Host 'PASS: five exact job IDs, concurrency 1'

    $case = New-Fixture 'worker-interrupted'
    $env:FORECAST_TEST_JOBS = $jobIds[0..1] -join ','
    $env:FORECAST_TEST_WORKER_FAIL_ID = $jobIds[1]
    Expect-TrialFailure $case 'Worker exited with code 17'
    Assert-Equal (Read-State $case).phase 'workers' 'worker retry checkpoint'
    Assert-Equal @((Read-State $case).processed_job_ids).Count 1 'first worker checkpoint'
    Remove-Item Env:FORECAST_TEST_WORKER_FAIL_ID
    Call-Trial $case
    Assert-Equal (Read-State $case).phase 'complete' 'resumed completion'
    Assert-Equal ((Get-Content (Join-Path $case 'maintenance_calls.txt')).Count) 1 'worker retry must not enqueue'
    $calls = @(Get-Content (Join-Path $case 'worker_calls.txt'))
    Assert-Equal $calls.Count 3 'failed worker retries only pending job'
    Assert-Equal $calls[2] "$($jobIds[1]) concurrency=1" 'resumed worker ID'
    Write-Host 'PASS: interrupted/failed worker resumes recorded job only'

    # The unattended wrapper must also tolerate INFO stderr in PowerShell 5.1.
    $case = New-Fixture 'scheduled-wrapper'
    $env:FORECAST_TEST_WORKER_EXIT = '0'
    $wrapperArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$launcherScript,
                     '-Mode','Worker','-BackendDir',$case,'-PythonExe',$pythonExe,
                     '-LocationId',$locationId)
    $wrapper = Start-Process -FilePath 'powershell.exe' -ArgumentList $wrapperArgs `
        -NoNewWindow -Wait -PassThru -RedirectStandardOutput (Join-Path $case 'wrapper.stdout.log') `
        -RedirectStandardError (Join-Path $case 'wrapper.stderr.log')
    Assert-Equal $wrapper.ExitCode 0 'scheduled wrapper INFO stderr exit code'
    $env:FORECAST_TEST_WORKER_EXIT = '17'
    $wrapper = Start-Process -FilePath 'powershell.exe' -ArgumentList $wrapperArgs `
        -NoNewWindow -Wait -PassThru -RedirectStandardOutput (Join-Path $case 'wrapper-fail.stdout.log') `
        -RedirectStandardError (Join-Path $case 'wrapper-fail.stderr.log')
    Assert-Equal $wrapper.ExitCode 17 'scheduled wrapper nonzero exit code'
    $env:FORECAST_TEST_MAINT_EXIT = '0'
    $wrapperArgs[6] = 'Maintenance'
    $wrapper = Start-Process -FilePath 'powershell.exe' -ArgumentList $wrapperArgs `
        -NoNewWindow -Wait -PassThru -RedirectStandardOutput (Join-Path $case 'wrapper-maint.stdout.log') `
        -RedirectStandardError (Join-Path $case 'wrapper-maint.stderr.log')
    Assert-Equal $wrapper.ExitCode 0 'scheduled maintenance INFO stderr exit code'
    Write-Host 'PASS: scheduled wrapper uses native exit codes'
    Write-Host 'PASS: all focused Windows trial cases'
} finally {
    foreach ($name in @('FORECAST_TEST_MAINT_EXIT','FORECAST_TEST_WORKER_EXIT','FORECAST_TEST_VISITED',
                       'FORECAST_TEST_JOBS','FORECAST_TEST_WORKER_FAIL_ID')) {
        Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    }
    $resolvedRoot = [System.IO.Path]::GetFullPath($testRoot)
    $resolvedTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if (-not $resolvedRoot.StartsWith($resolvedTemp, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to remove a test fixture outside the temporary directory.'
    }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}
