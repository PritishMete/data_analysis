[CmdletBinding()]
param([int]$Port = 8000)
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Python = Get-Command python -ErrorAction SilentlyContinue
if (-not $Python) { throw 'Python was not found on PATH.' }
if (-not (Test-Path (Join-Path $RepoRoot 'main.py'))) { throw 'InsightFlow backend main.py was not found.' }

$Base = "http://127.0.0.1:$Port"
$Diagnostics = "$Base/v1/system/diagnostics"
$Ui = "$Base/ui/"

function Get-Diagnostics {
  try { return Invoke-RestMethod -Uri $Diagnostics -Method Get -TimeoutSec 3 }
  catch { return $null }
}

function Get-PortOwners([int]$TargetPort) {
  try {
    $connections = Get-NetTCPConnection -LocalPort $TargetPort -State Listen -ErrorAction Stop
    return @($connections | Select-Object -ExpandProperty OwningProcess -Unique)
  } catch { return @() }
}

$current = Get-Diagnostics
if ($null -ne $current) {
  if ($current.success -and $current.overall_status -eq 'healthy') {
    Write-Host 'INSIGHTFLOW ALREADY RUNNING'
    Write-Host 'Backend: healthy'
    Write-Host ("Build: {0}" -f $current.frontend.detail_analysis_build_id)
    Write-Host ("URL: {0}" -f $Ui)
    Start-Process $Ui
    exit 0
  }
  Write-Host 'Port is already serving a process, but it is not a healthy InsightFlow backend.'
  Write-Host 'No unrelated process was terminated. Use restart_insightflow.ps1 only after verifying the process.'
  exit 1
}

$owners = Get-PortOwners $Port
if ($owners.Count -gt 0) {
  $verifiedInsightFlow = $false
  foreach ($pid in $owners) {
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$pid" -ErrorAction SilentlyContinue
    if ($process -and $process.CommandLine -and $process.CommandLine -match 'uvicorn' -and $process.CommandLine -match 'main:app' -and $process.CommandLine -match [regex]::Escape($RepoRoot)) {
      $verifiedInsightFlow = $true
    }
  }
  if (-not $verifiedInsightFlow) {
    Write-Host ("Port {0} is occupied by an unverified process." -f $Port)
    Write-Host 'No process was terminated. Choose another port or stop the verified owner manually.'
    exit 1
  }
  Write-Host 'A verified InsightFlow process owns the port, but diagnostics are unavailable.'
  Write-Host 'Use restart_insightflow.ps1 to recover it safely.'
  exit 1
}

$proc = Start-Process -FilePath $Python.Source -ArgumentList '-m','uvicorn','main:app','--app-dir',$RepoRoot,'--host','127.0.0.1','--port',$Port -WorkingDirectory $RepoRoot -PassThru -WindowStyle Hidden

$ready = $false
for ($i = 0; $i -lt 30; $i++) {
  Start-Sleep -Milliseconds 500
  if ($proc.HasExited) { throw "InsightFlow backend exited during startup (code $($proc.ExitCode))." }
  $check = Get-Diagnostics
  if ($null -ne $check) { $ready = $true; break }
}
if (-not $ready) { throw 'InsightFlow did not expose diagnostics within the startup timeout.' }

$final = Get-Diagnostics
if (-not $final.success) { throw 'Diagnostics endpoint returned an invalid response.' }
Write-Host 'INSIGHTFLOW READY'
Write-Host ("Backend: {0}" -f $final.backend.status)
Write-Host ("Detail Analysis: {0}" -f $final.frontend.status)
Write-Host ("Build: {0}" -f $final.frontend.detail_analysis_build_id)
Write-Host ("URL: {0}" -f $Ui)
Start-Process $Ui
