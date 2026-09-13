[CmdletBinding()]
param([int]$Port = 8000)
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Python = Get-Command python -ErrorAction SilentlyContinue
if (-not $Python) { throw 'Python was not found on PATH.' }
$Base = "http://127.0.0.1:$Port"
$Diagnostics = "$Base/v1/system/diagnostics"

function Get-Diagnostics { try { Invoke-RestMethod -Uri $Diagnostics -TimeoutSec 3 } catch { $null } }

$processes = Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" |
  Where-Object {
    $_.CommandLine -and
    $_.CommandLine -match 'uvicorn' -and
    $_.CommandLine -match 'main:app' -and
    $_.CommandLine -match [regex]::Escape($RepoRoot)
  }

if ($processes.Count -eq 0) {
  $existing = Get-Diagnostics
  if ($null -ne $existing) {
    Write-Host 'A healthy diagnostics endpoint exists, but its owning process could not be verified as InsightFlow.'
    Write-Host 'No process was terminated.'
    exit 1
  }
} else {
  foreach ($p in @($processes)) {
    Stop-Process -Id ([int]$p.ProcessId) -Force
  }
  Start-Sleep -Milliseconds 800
}

& (Join-Path $PSScriptRoot 'start_insightflow.ps1') -Port $Port
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$final = Get-Diagnostics
if ($null -eq $final -or $final.overall_status -ne 'healthy') { Write-Host 'Restart completed but diagnostics are not healthy.'; exit 1 }
Write-Host 'INSIGHTFLOW RESTARTED AND HEALTHY'
