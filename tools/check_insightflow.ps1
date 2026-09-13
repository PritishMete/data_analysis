[CmdletBinding()]
param([int]$Port = 8000)
$ErrorActionPreference = 'Stop'
$Uri = "http://127.0.0.1:$Port/v1/system/diagnostics"

try { $d = Invoke-RestMethod -Uri $Uri -Method Get -TimeoutSec 5 }
catch { Write-Host 'INSIGHTFLOW HEALTH CHECK'; Write-Host 'Backend: FAIL'; Write-Host 'Recovery: Start the local InsightFlow backend.'; exit 1 }

Write-Host 'INSIGHTFLOW HEALTH CHECK'
Write-Host ("Backend: {0}" -f ($(if ($d.backend.status -eq 'healthy') {'PASS'} else {'FAIL'})))
Write-Host ("Detail Analysis build: {0}" -f ($(if ($d.frontend.status -eq 'healthy') {'PASS'} elseif ($d.frontend.status -eq 'stale') {'FAIL (STALE)'} else {'FAIL'})))
Write-Host ("Conversation state: {0}" -f ($(if ($d.services.conversation_state -eq 'healthy') {'PASS'} else {'FAIL'})))
Write-Host ("Report engine: {0}" -f ($(if ($d.services.report_generation -eq 'healthy') {'PASS'} else {'FAIL'})))
Write-Host ("Privacy guard: {0}" -f ($(if ($d.privacy.local_dataset_processing -and -not $d.privacy.raw_dataset_external_transmission) {'PASS'} else {'FAIL'})))

if ($d.recovery.Count -gt 0) {
  Write-Host 'Recovery:'
  $d.recovery | ForEach-Object { Write-Host ("- {0}: {1}" -f $_.title, $_.action) }
}

if ($d.overall_status -eq 'healthy') { Write-Host 'OVERALL: HEALTHY'; exit 0 }
Write-Host 'OVERALL: DEGRADED'
exit 1
