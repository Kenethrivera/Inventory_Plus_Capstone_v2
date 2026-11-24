# One build for forecasting API, maintenance, and worker

The digest covers 14 Python source files in `app/api`, `app/data`,
`app/forecasting`, and `app/seasonality`, plus the exact Python, LightGBM,
NumPy, and scikit-learn versions. It hashes raw bytes, including line endings.
Before alignment on 2026-11-22, the local producer computed
`c0188ca9ed522918233ce16141fe692614673756a91ed06e2c9a77b9cf714863`
using CRLF source and Python 3.13.17, LightGBM 4.7.0, NumPy 2.5.4, and
scikit-learn 1.9.1.
Failed LightGBM and Mean28 jobs carry this digest. The successful Blend jobs
carry `f8697a61c685fd9b57efdf1c61f97a8c1ef0024329073af7833aeac69d89476f`.
All 14 local source files match GitHub commit
`ae4817a2784acbf03c1c417f5507ddb5d3994553` after converting CRLF to LF.
There is no code-content difference in those digest inputs. Recomputing the
production digest with the LF bytes and Azure's Python 3.12.3, LightGBM 4.7.0,
NumPy 2.5.4, and scikit-learn 1.9.1 produces exactly `f8697a61...`. The
`c0188ca9...` versus `f8697a61...` mismatch is caused by both line endings
and Python version. This calculation does not prove what is currently running
on each host; compare the live manifests before preparing jobs.

| Digest input (under `forecasting_backend/`) | CRLF lines before alignment | Difference from commit before alignment |
| --- | ---: | --- |
| `app/api/adapters.py` | 1227 | Line endings only |
| `app/api/job_materialization.py` | 624 | Line endings only |
| `app/api/service.py` | 612 | Line endings only |
| `app/data/models.py` | 30 | Line endings only |
| `app/data/validation.py` | 55 | Line endings only |
| `app/forecasting/backtesting.py` | 170 | Line endings only |
| `app/forecasting/blend.py` | 224 | Line endings only |
| `app/forecasting/execution.py` | 182 | Line endings only |
| `app/forecasting/lightgbm_model.py` | 309 | Line endings only |
| `app/forecasting/mean28.py` | 144 | Line endings only |
| `app/forecasting/models.py` | 211 | Line endings only |
| `app/forecasting/product_specific_seasonal_lightgbm.py` | 349 | Line endings only |
| `app/forecasting/series.py` | 134 | Line endings only |
| `app/seasonality/calendar.py` | 154 | Line endings only |

For every row, the Git blob SHA-1 of the local file after CRLF-to-LF
normalization equals that file's blob SHA-1 in the Azure commit tree.

The local `forecasting_backend/.venv` actually runs Python 3.13.17, FastAPI
0.163.2, HTTPX 0.28.1, Pydantic 2.14.3, and Uvicorn 0.54.0. The `python`
command on PATH is also 3.13.17 but has FastAPI 0.162.0 and Pydantic 2.14.2;
the `py` launcher lists a separate 3.14 installation. The checked-in
`requirements.txt` pins 0.162.0 and 2.14.2. These FastAPI/Pydantic differences
are outside the current digest, but the deployed processes still need one
resolved dependency lock.

Local alignment completed on 2026-11-22: official signed Python 3.12.3 was
installed per user, `forecasting_backend/.venv3123` was created without
removing `.venv`, the pinned dependencies plus Windows-only `tzdata==2026.6`
were installed, and exactly the 14 digest inputs were converted from CRLF to
LF. The verified backup is
`forecasting_backend/.runtime/identity_backups/digest_sources_20261122T101722Z_cafbb387.zip`.
The production digest function and both read-only worker/maintenance manifest
commands returned exactly `f8697a61c685fd9b57efdf1c61f97a8c1ef0024329073af7833aeac69d89476f`.
The Windows Git configuration has `core.autocrlf=true`; `.gitattributes`
forces LF for future checkouts of forecast implementation modules.

`run_forecast_worker.py --identity-only` and
`run_forecast_maintenance.py --identity-only` print manifests without a database
connection or secret. Authenticated Admins can read the FastAPI manifest at
`GET /v1/forecasting/implementation-manifest`. Compare `runtime` and every
`files[].sha256` entry. The source hash list is authoritative for identifying
the exact mismatch. The API's compact `GET /v1/forecasting/model-identities`
reports the active four-model identities.

## Local Windows FastAPI alignment (completed)

Python 3.12.3 was installed with the signed official installer using this
command. It is already installed; do not rerun the installation on this host.

```powershell
$installer = Join-Path $env:TEMP 'python-3.12.3-amd64.exe'
$pyDir = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python3123'
Invoke-WebRequest 'https://www.python.org/ftp/python/3.12.3/python-3.12.3-amd64.exe' -OutFile $installer
if ((Get-AuthenticodeSignature $installer).Status -ne 'Valid') { throw 'Python installer signature is invalid' }
$install = Start-Process -FilePath $installer -ArgumentList @('/quiet','InstallAllUsers=0',"TargetDir=$pyDir",'PrependPath=0','Include_test=0','Include_launcher=0') -WindowStyle Hidden -Wait -PassThru
if ($install.ExitCode -ne 0) { throw "Python installation failed: $($install.ExitCode)" }
```

The backup was verified before converting the 14 source files, and the
production digest was checked immediately after conversion. The existing
`.venv` remains available. The VM's full transitive package list is not yet
available for comparison. To start FastAPI with the aligned local environment
after reviewing its operational configuration, run:

```powershell
Set-Location 'C:\inventory_plus_capstone_v2\Inventory_Plus_Capstone_v2-integration\forecasting_backend'
& .\.venv3123\Scripts\python.exe run_api.py
```

This starts FastAPI in the current console. It does not start the Azure worker
or maintenance process. The Python installer URL and command-line options are
published by Python.org.

Use the LF source tree at commit `ae4817a...` as the digest baseline and
Python 3.12.3 as the target runtime. If the VM already reports `f8697a61...`,
align the local FastAPI host first; no Azure code deployment is required for
the digest mismatch. If the VM does not match, overlay reviewed local changes
outside the 14 digest inputs onto one release artifact with a single resolved
dependency lock, then deploy it to all three processes. Keep `.env`,
credentials, and maintenance state outside the artifact. Do not copy a
platform-specific virtual environment between hosts.
FastAPI runs on the local Windows machine, where `forecasting_backend/.env`
sets `FORECAST_API_HOST=127.0.0.1` and `FORECAST_API_PORT=8000`.
The existing Linux worker/maintenance service units use
`/opt/inventory-plus/forecasting_backend/.venv/bin/python`. Before deploying
the diagnostic entry points to the VM, inspect its live identity without
starting a job:

```bash
cd /opt/inventory-plus/forecasting_backend
.venv/bin/python -B -c 'import platform, importlib.metadata as m; from app.api.job_materialization import _implementation_digest; print("digest", _implementation_digest()); print("python", platform.python_version()); [print(x, m.version(x)) for x in ("lightgbm", "numpy", "scikit-learn")]'
.venv/bin/python -m pip freeze --all
systemctl cat inventory-forecast-worker.service inventory-forecast-maintenance.service
```

If this reports `f8697a61...`, the VM's existing worker matches the desired
identity. No VM deployment is needed solely to fix local API job identities.
After any approved diagnostic deployment, the shorter checks are:

```text
cd /opt/inventory-plus/forecasting_backend
.venv/bin/python run_forecast_worker.py --identity-only
.venv/bin/python run_forecast_maintenance.py --identity-only
```

Both outputs and the authenticated API manifest must show the same
`implementation_digest`, source file hashes, runtime versions, and installed
package lock. The FastAPI host is local Windows; the Azure VM SSH destination
and its live service state still require operator confirmation. Confirm the
VM's active supervisors before using deployment commands. If the
checked-in systemd units are active, their restart sequence after approved
deployment and read-only verification is:

```text
sudo systemctl restart inventory-forecast-worker.service inventory-forecast-maintenance.service
systemctl status inventory-forecast-worker.service inventory-forecast-maintenance.service
journalctl -u inventory-forecast-worker.service -u inventory-forecast-maintenance.service --since today --no-pager
```

Check the worker startup `forecast_worker_identity` log and API manifest after
restart. Never weaken digest validation or alter historical job rows. Deploying
the LF/Python 3.12.3 implementation restores `f8697a61...` and changes the
implementation identity from `c0188ca9...` for the failed jobs. The normal identity also
contains the Manila business date, source revisions, and input digest. A new
daily run or a genuine source revision may therefore enqueue a new identity;
an identical request on the same day returns the existing terminal failure.
Recovery under that identical identity requires the separately authorized
operator workflow in `PHASE_6_RECOVERY.md`. Verify its RPC is installed before
relying on it; the checked-in recovery document says its Stage 6A correction
was not installed when that document was written.

## Pilot after approval and alignment

1. From an existing Admin session, search the snapshot overview for SKU
   `SIM-NEU-001`; record its UUID, location, unit, current revisions, and
   existing Blend `result_id`. Verify the API manifest matches the worker.
2. For `mean28`, `lightgbm`, and `seasonal_experimental`, call the existing
   authenticated `POST /v1/forecasting/jobs/bootstrap?product_id=<UUID>&model=<MODEL>`
   once per model. Record each returned job ID and outcome. If it returns a
   duplicate terminal failure, stop that model's pilot. Confirm the business
   date, revisions, and digests before considering the separately approved
   recovery workflow; a duplicate is not a successful retry.
3. Poll the existing product snapshot route with the requested model until it
   reports `completed` and a durable result ID. Verify requested model key,
   version, config digest, implementation digest, forecast dates, and fallback
   producer metadata. A queued or running job does not satisfy this check.
4. Verify the prior Blend result still reads successfully. Do not infer model
   success from its forecast value or from the UI's product count alone.

## Remaining 12-product pass

After the pilot, use the Admin Overview model selector with the simulation SKU
filter. Each page prepares at most five visible missing products for Mean28 or
LightGBM and one for Seasonal Experimental. Use the explicit bounded Prepare
button on subsequent pages. The backend enqueues idempotently and the worker
publishes each immutable result. Confirm 12 distinct product UUIDs times four
requested model keys through saved result IDs, current status, fallback
metadata, and the expected cold-start classifications. Seasonal Experimental
may legitimately use a fallback producer for unregistered products; its
requested-model result still has its own identity. Categories and units are
aggregations of compatible product results only.

No deployment, job preparation, worker run, test suite, or database mutation is
part of this file. Those steps require approval and live credentials.
