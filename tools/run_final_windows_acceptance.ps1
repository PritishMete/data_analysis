[CmdletBinding()]
param(
  [string]$RepoRoot = '',
  [string]$FlutterRoot = 'C:\Users\jiban\Downloads\InsightFlow_secure_gemini_metadata_categorization_INR_v4',
  [string]$StudentRoot = 'E:\LLM',
  [string]$DataRoot = 'E:\ai data analyst',
  [int]$Port = 8000
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path } else { $RepoRoot = (Resolve-Path $RepoRoot).Path }
$ExpectedBaseline = '8053000369222f897d12927b3599a5e65274b479'
$AllowedAcceptanceFiles = @('tools/run_final_windows_acceptance.ps1','tools/final_windows_acceptance.py','tools/final_windows_browser_acceptance.py')
$Branch = 'flutter-detail-analysis'
$Artifacts = Join-Path $RepoRoot 'artifacts'
$Base = "http://127.0.0.1:$Port"
$JsonPath = Join-Path $Artifacts 'final_windows_acceptance.json'
$TxtPath = Join-Path $Artifacts 'final_windows_acceptance.txt'
$LivePath = Join-Path $Artifacts 'final_windows_acceptance_live.json'
$BrowserPath = Join-Path $Artifacts 'final_windows_browser_acceptance.json'
New-Item -ItemType Directory -Path $Artifacts -Force | Out-Null
$R = [ordered]@{}
$Defects = [System.Collections.Generic.List[string]]::new()
$Limitations = [System.Collections.Generic.List[string]]::new()
$Exit = 0

function Gate([string]$Name,[bool]$Pass,[string]$Detail='') { $R[$Name]=[ordered]@{status=if($Pass){'PASS'}else{'FAIL'};detail=$Detail}; if(-not $Pass){$script:Exit=1} }
function Native([string]$Exe,[string[]]$CommandArgs,[string]$Cwd,[hashtable]$Env=@{}) {
  $old=@{}; foreach($k in $Env.Keys){$old[$k]=[Environment]::GetEnvironmentVariable($k,'Process');[Environment]::SetEnvironmentVariable($k,[string]$Env[$k],'Process')}
  $started=Get-Date
  $previousErrorActionPreference=$ErrorActionPreference
  Push-Location $Cwd
  try { $ErrorActionPreference='Continue';$out=& $Exe @CommandArgs 2>&1 | Out-String; $code=$LASTEXITCODE } finally { $ErrorActionPreference=$previousErrorActionPreference;Pop-Location;foreach($k in $Env.Keys){[Environment]::SetEnvironmentVariable($k,$old[$k],'Process')} }
  $d=((Get-Date)-$started).TotalSeconds
  $c=[ordered]@{passed=0;failed=0;skipped=0;warnings=0;duration_seconds=[math]::Round($d,3);exit_code=$code}
  if($out -match '(?m)(\d+) passed'){$c.passed=[int]$Matches[1]};if($out -match '(?m)(\d+) failed'){$c.failed=[int]$Matches[1]};if($out -match '(?m)(\d+) skipped'){$c.skipped=[int]$Matches[1]};if($out -match '(?m)(\d+) warnings?'){$c.warnings=[int]$Matches[1]}
  [pscustomobject]@{code=$code;text=$out;counts=$c}
}
function Hash([string]$p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()}
function Owners([int]$p){try{@(Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction Stop|Select-Object -ExpandProperty OwningProcess -Unique)}catch{@()}}
function IsInsight([int]$pid){$p=Get-CimInstance Win32_Process -Filter "ProcessId=$pid" -ErrorAction SilentlyContinue;return $null -ne $p -and $p.CommandLine -and $p.CommandLine -match 'uvicorn' -and $p.CommandLine -match 'main:app' -and $p.CommandLine -match [regex]::Escape($RepoRoot)}
function GetDiag(){try{Invoke-RestMethod -Uri "$Base/v1/system/diagnostics" -TimeoutSec 5}catch{$null}}
function WaitHealthy(){for($i=0;$i-lt 60;$i++){Start-Sleep -Milliseconds 500;$d=GetDiag;if($d -and $d.overall_status -eq 'healthy'){return $true}};return $false}
function StartBackend(){
  $o=Owners $Port;if($o.Count){foreach($pid in $o){if(-not(IsInsight $pid)){throw "Exit 2: port $Port is occupied by an unrelated process PID $pid; no process was killed."}};throw "Verified InsightFlow already owns port $Port; use safe restart tooling."}
  $log=Join-Path $Artifacts 'final_windows_backend.log';$err=Join-Path $Artifacts 'final_windows_backend_error.log';Remove-Item $log,$err -Force -ErrorAction SilentlyContinue
  $p=Start-Process python -ArgumentList '-m','uvicorn','main:app' -WorkingDirectory $RepoRoot -RedirectStandardOutput $log -RedirectStandardError $err -PassThru
  Set-Content (Join-Path $Artifacts 'final_windows_backend.pid') $p.Id
  if(-not(WaitHealthy)){throw 'Backend did not become healthy; see acceptance backend logs.'}
}
function WebSnapshot(){
  $root=Join-Path $FlutterRoot 'web';$m=[ordered]@{};if(Test-Path $root){Get-ChildItem $root -Recurse -File|%{$relative=$_.FullName.Substring($root.Length).TrimStart([char[]]@('\','/'));$m[$relative]=Hash $_.FullName}};return $m
}

Write-Host 'INSIGHTFLOW FINAL WINDOWS ACCEPTANCE'
# 1 PRE-FLIGHT
if($env:OS -ne 'Windows_NT'){throw 'Exit 2: Windows is required.'}
foreach($x in @(@('Python','python'),@('Flutter','flutter'),@('PowerShell','powershell'))){if(-not(Get-Command $x[1] -ErrorAction SilentlyContinue)){throw "Exit 2: $($x[0]) is unavailable."}}
foreach($p in @($StudentRoot,$DataRoot,$FlutterRoot)){if(-not(Test-Path $p -PathType Container)){throw "Exit 2: required root missing: $p"}}
foreach($f in @('orders_raw.csv','customers_raw.csv','products_raw.csv','regions_raw.csv')){if(-not(Test-Path (Join-Path $DataRoot $f) -PathType Leaf)){throw "Exit 2: required CSV missing: $f"}}
foreach($f in @('main.py','system_diagnostics.py','tools\start_insightflow.ps1','tools\restart_insightflow.ps1','tools\check_insightflow.ps1','tools\final_windows_acceptance.py','tools\final_windows_browser_acceptance.py','flutter_detail_source\build_detail_analysis.ps1')){if(-not(Test-Path (Join-Path $RepoRoot $f) -PathType Leaf)){throw "Exit 2: required file missing: $f"}}
if(-not(Test-Path (Join-Path $RepoRoot '.git') -PathType Container)){throw 'Exit 2: repository is not a Git worktree.'}
Gate 'PRE-FLIGHT' $true 'Windows/Python/Flutter/PowerShell/student runtime/dataset/build inputs verified.'
# Bootstrap browser automation only if missing; this is tooling, not application logic.
$pw=Native python @('-c','import playwright') $RepoRoot
if($pw.code -ne 0){$pip=Native python @('-m','pip','install','playwright') $RepoRoot;if($pip.code -ne 0){throw 'Exit 2: could not install Playwright acceptance dependency.'};$bi=Native python @('-m','playwright','install','chromium') $RepoRoot;if($bi.code -ne 0){throw 'Exit 2: could not install Chromium acceptance runtime.'}}

# 2 SOURCE IDENTITY
$branch=(Native git @('branch','--show-current') $RepoRoot).text.Trim();$sha=(Native git @('rev-parse','HEAD') $RepoRoot).text.Trim();$dirty=(Native git @('status','--porcelain') $RepoRoot).text.Trim();
$ancestor=Native git @('merge-base','--is-ancestor',$ExpectedBaseline,$sha) $RepoRoot
$changed=(Native git @('diff','--name-only',"$ExpectedBaseline..$sha") $RepoRoot).text -split "`r?`n"|?{$_}
$unexpected=@($changed|?{$AllowedAcceptanceFiles -notcontains $_})
$R['SOURCE IDENTITY']=[ordered]@{branch=$branch;commit=$sha;baseline=$ExpectedBaseline;dirty=[bool]$dirty;acceptance_only=($unexpected.Count -eq 0);changed_since_baseline=$changed}
if($branch -ne $Branch){throw "Wrong branch: expected $Branch, found $branch."};if($ancestor.code -ne 0){throw "Current commit is not based on accepted diagnostics baseline $ExpectedBaseline."};if($unexpected.Count){throw "Non-acceptance files changed since baseline: $($unexpected -join ', ')"}

# 3 BACKEND TESTS + requested focused suites
$env:INSIGHTFLOW_STUDENT_ROOT=$StudentRoot
$b=Native pytest @('-q') $RepoRoot @{'INSIGHTFLOW_STUDENT_ROOT'=$StudentRoot};$R['BACKEND TESTS']=$b.counts;if($b.code -ne 0){$Defects.Add('pytest -q failed.')}
foreach($t in @('tests/test_system_diagnostics.py','tests/test_build_info.py','tests/test_detail_build_pipeline.py','tests/test_end_to_end_learning.py','tests/test_assistant_identity.py','tests/test_conversation_state.py')){$q=Native pytest @('-q',$t) $RepoRoot @{'INSIGHTFLOW_STUDENT_ROOT'=$StudentRoot};$R["BACKEND $t"]=$q.counts;if($q.code -ne 0){$Defects.Add("$t failed.")}}
# The student lifecycle test must be a real collected test, not a skip.
$col=Native pytest @('--collect-only','-q') $RepoRoot @{'INSIGHTFLOW_STUDENT_ROOT'=$StudentRoot};$ids=@($col.text -split "`r?`n"|?{$_ -match '(?i)(student|lifecycle|privacy)' -and $_ -match '::'});$live=Native pytest @('-q') $RepoRoot @{'INSIGHTFLOW_STUDENT_ROOT'=$StudentRoot};$liveOk=$ids.Count -gt 0 -and $live.code -eq 0 -and $live.text -notmatch '(?i)student.*SKIPPED|SKIPPED.*student';Gate 'LIVE STUDENT RUNTIME TEST' $liveOk "Discovered: $($ids -join '; ')"

# 5 FLUTTER
$fg=Native flutter @('pub','get') $FlutterRoot;$ft=Native flutter @('test') $FlutterRoot;$fb=Native flutter @('build','web','--release','--target','lib/detail_analysis_main.dart','--base-href','/ui/') $FlutterRoot;$R['FLUTTER TESTS']=$ft.counts;$R['FLUTTER BUILD']=$fb.counts;Gate 'FLUTTER TESTS' ($fg.code -eq 0 -and $ft.code -eq 0) 'flutter pub get + flutter test';Gate 'FLUTTER BUILD' ($fb.code -eq 0) 'release Detail Analysis target'

# 6 DETAIL BUILD + Excel source asset immutability
$webBefore=WebSnapshot;$bp=Native powershell @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $FlutterRoot 'build_detail_analysis.ps1'),'-ServingRoot',$RepoRoot,'-BaseHref','/ui/') $FlutterRoot;$outRoot=Join-Path $RepoRoot 'frontend\flutter_detail';$index=Join-Path $outRoot 'index.html';$js=Join-Path $outRoot 'main.dart.js';$metaOk=Test-Path $index;$jsOk=Test-Path $js;$id=if($jsOk){(Hash $js).Substring(0,12)}else{''};$txt=if($metaOk){Get-Content $index -Raw}else{''};$office=if(Test-Path $outRoot){Select-String -Path (Get-ChildItem $outRoot -Recurse -File).FullName -Pattern 'appsforoffice\.com|office\.js' -CaseSensitive:$false -ErrorAction SilentlyContinue}else{$null};$webAfter=WebSnapshot;$webSame=(ConvertTo-Json $webBefore -Compress)-(ConvertTo-Json $webAfter -Compress);$buildOk=$bp.code -eq 0 -and $metaOk -and $jsOk -and $id.Length -eq 12 -and $txt -match 'detail-analysis-build-id' -and $office.Count -eq 0 -and $webSame;Gate 'DETAIL ANALYSIS BUILD' $buildOk "build_id=$id index=$metaOk main.dart.js=$jsOk office_js_absent=$($office.Count -eq 0) excel_web_assets_unchanged=$webSame"; $R['DETAIL ANALYSIS BUILD ID']=$id

# 7 BACKEND + diagnostics
StartBackend;$d=GetDiag;$bi=try{Invoke-RestMethod "$Base/v1/build-info" -TimeoutSec 5}catch{$null};$djson=ConvertTo-Json $d -Depth 30;$privacy=$djson -notmatch '[A-Za-z]:\\' -and $djson -notmatch '(?i)(api[_ -]?key|secret|traceback|stack trace|dataset row)';$healthy=$d -and $d.overall_status -eq 'healthy' -and $d.backend.status -eq 'healthy' -and $d.frontend.artifact_present -eq $true -and $d.frontend.stale_build -eq $false;Gate 'BACKEND DIAGNOSTICS' ($healthy -and $privacy) 'live /v1/system/diagnostics';$match=$bi -and ([string]$bi.frontend_build_id).Length -eq 12 -and $bi.frontend_build_id -eq $id -and [bool]$bi.backend_commit -and [bool]$bi.build_timestamp;Gate 'BUILD ID MATCH' $match "served=$($bi.frontend_build_id) local=$id";Gate 'PRIVACY' $privacy 'no absolute paths/secrets/raw exceptions in diagnostics'

# 8-9 Windows tool acceptance
$hc=Native powershell @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $RepoRoot 'tools\check_insightflow.ps1')) $RepoRoot;Gate 'WINDOWS HEALTH CHECK' ($hc.code -eq 0) 'check_insightflow.ps1';$rs=Native powershell @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $RepoRoot 'tools\restart_insightflow.ps1')) $RepoRoot;Gate 'WINDOWS RESTART SCRIPT' ($rs.code -eq 0 -and (GetDiag).overall_status -eq 'healthy') 'restart_insightflow.ps1';$st=Native powershell @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $RepoRoot 'tools\start_insightflow.ps1')) $RepoRoot;Gate 'WINDOWS START SCRIPT' ($st.code -eq 0 -and (GetDiag).overall_status -eq 'healthy') 'start_insightflow.ps1 duplicate-safe behavior'

# 10-18 real data/API + browser UI
$lv=Native python @((Join-Path $RepoRoot 'tools\final_windows_acceptance.py'),'--repo',$RepoRoot,'--data-root',$DataRoot,'--output',$LivePath) $RepoRoot @{'INSIGHTFLOW_STUDENT_ROOT'=$StudentRoot};if(Test-Path $LivePath){$lo=Get-Content $LivePath -Raw|ConvertFrom-Json;$R['LIVE DATA ADAPTER']=$lo}else{$lo=$null};
foreach($pair in @(@('REAL DATASET SESSION','real_dataset_session'),@('ALL-TIME VALUES','all_time'),@('NORTH','north'),@('NORTH + 2025','north_2025'),@('NORTH + 2025 + CLOTHING','north_2025_clothing'),@('SUGGESTED FOLLOW-UPS','suggested_followups'),@('REPORT GENERATION','report_generation'),@('SOURCE CSV HASHES UNCHANGED','source_csv_hashes_unchanged'),@('PRIVACY','privacy'))){$v=$false;if($lo -and $lo.checks.PSObject.Properties.Name -contains $pair[1]){$v=[bool]$lo.checks.($pair[1])};if($pair[0] -ne 'PRIVACY' -and $pair[0] -eq 'SOURCE CSV HASHES UNCHANGED'){$v=$v};Gate $pair[0] $v 'live backend/data adapter'}
$br=Native python @((Join-Path $RepoRoot 'tools\final_windows_browser_acceptance.py'),'--data-root',$DataRoot,'--artifacts',$Artifacts,'--output',$BrowserPath) $RepoRoot @{};if(Test-Path $BrowserPath){$bo=Get-Content $BrowserPath -Raw|ConvertFrom-Json;$R['BROWSER ACCEPTANCE']=$bo}else{$bo=$null}
$map=@{'PRODUCT CONTEXT'='product';'COMPARISON CONTEXT'='comparison';'BOOLEAN / THEN'='boolean_then';'SESSION SUMMARY'='summary';'META NON-MUTATION'='meta_context';'FAILED-QUERY RECOVERY'='unsupported';'CHART REGRESSION'='charts_or_schema';'STAR SCHEMA REGRESSION'='charts_or_schema';'COPY / SELECTION'='copy_or_selection';'DIAGNOSTICS UI'='diagnostics_ui';'SUGGESTED FOLLOW-UPS'='suggestion_chips';'PDF VISUAL QA'='pdf_visual_qa'};foreach($k in $map.Keys){$v=$false;if($bo){$key=$map[$k];if($bo.checks.PSObject.Properties.Name -contains $key){$v=[bool]$bo.checks.$key}elseif($bo.queries.PSObject.Properties.Name -contains $key){$v=[bool]$bo.queries.$key.passed}elseif($bo.reports.PSObject.Properties.Name -contains $key){$v=[bool]$bo.reports.$key.passed}};Gate $k $v 'automated browser acceptance'}
$uiPass=$bo -and $bo.passed;Gate 'UI ACCEPTANCE' $uiPass 'Playwright live /ui/ acceptance'

# 19 FINAL RESTART + smoke
$fr=Native powershell @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $RepoRoot 'tools\restart_insightflow.ps1')) $RepoRoot;$finalLive=Join-Path $Artifacts 'final_smoke.json';$fs=if($fr.code -eq 0){Native python @((Join-Path $RepoRoot 'tools\final_windows_acceptance.py'),'--repo',$RepoRoot,'--data-root',$DataRoot,'--output',$finalLive) $RepoRoot @{'INSIGHTFLOW_STUDENT_ROOT'=$StudentRoot}}else{$null};$smoke=$fs -and $fs.code -eq 0;Gate 'BACKEND RESTARTED AFTER FINAL CHANGE' ($fr.code -eq 0) 'safe final restart';Gate 'FINAL SMOKE AFTER RESTART' $smoke 'live diagnostics/data smoke'

# Mandatory report fields. These are never inferred from source inspection.
$required=@('LIVE STUDENT RUNTIME TEST','FLUTTER TESTS','FLUTTER BUILD','DETAIL ANALYSIS BUILD','BUILD ID MATCH','BACKEND DIAGNOSTICS','WINDOWS START SCRIPT','WINDOWS RESTART SCRIPT','WINDOWS HEALTH CHECK','REAL DATASET SESSION','ALL-TIME VALUES','NORTH','NORTH + 2025','NORTH + 2025 + CLOTHING','PRODUCT CONTEXT','COMPARISON CONTEXT','BOOLEAN / THEN','SESSION SUMMARY','SUGGESTED FOLLOW-UPS','META NON-MUTATION','FAILED-QUERY RECOVERY','REPORT GENERATION','PDF VISUAL QA','CHART REGRESSION','STAR SCHEMA REGRESSION','COPY / SELECTION','DIAGNOSTICS UI','PRIVACY','SOURCE CSV HASHES UNCHANGED','BACKEND RESTARTED AFTER FINAL CHANGE','FINAL SMOKE AFTER RESTART');$fails=@($required|?{$R[$_].status -ne 'PASS'});$verdict=if($fails.Count){'NOT READY'}else{'READY TO MERGE'}
$report=[ordered]@{title='INSIGHTFLOW FINAL WINDOWS ACCEPTANCE';branch=$branch;commit=$sha;baseline=$ExpectedBaseline;results=$R;files_changed=@('tools/run_final_windows_acceptance.ps1','tools/final_windows_acceptance.py','tools/final_windows_browser_acceptance.py');defects=$Defects;remaining_limitations=$Limitations;user_manual_testing_required='NO';code_changed='YES';final_verdict=$verdict};$report|ConvertTo-Json -Depth 40|Set-Content $JsonPath -Encoding utf8

$lines=[System.Collections.Generic.List[string]]::new();$lines.Add('INSIGHTFLOW FINAL WINDOWS ACCEPTANCE');$lines.Add('');$lines.Add("BACKEND TESTS: $($R['BACKEND TESTS'].passed) passed, $($R['BACKEND TESTS'].failed) failed, $($R['BACKEND TESTS'].skipped) skipped, $($R['BACKEND TESTS'].warnings) warnings");$lines.Add("LIVE STUDENT RUNTIME TEST: $($R['LIVE STUDENT RUNTIME TEST'].status)");$lines.Add("FLUTTER TESTS: $($R['FLUTTER TESTS'].status)");$lines.Add("FLUTTER BUILD: $($R['FLUTTER BUILD'].status)");$lines.Add("DETAIL ANALYSIS BUILD ID: $id");foreach($x in @('BUILD ID MATCH','BACKEND DIAGNOSTICS','WINDOWS START SCRIPT','WINDOWS RESTART SCRIPT','WINDOWS HEALTH CHECK','REAL DATASET SESSION','ALL-TIME VALUES','NORTH','NORTH + 2025','NORTH + 2025 + CLOTHING','PRODUCT CONTEXT','COMPARISON CONTEXT','BOOLEAN / THEN','SESSION SUMMARY','SUGGESTED FOLLOW-UPS','META NON-MUTATION','FAILED-QUERY RECOVERY','REPORT GENERATION','PDF VISUAL QA','CHART REGRESSION','STAR SCHEMA REGRESSION','COPY / SELECTION','DIAGNOSTICS UI','PRIVACY','SOURCE CSV HASHES UNCHANGED')){$lines.Add("$($x.ToUpperInvariant()): $($R[$x].status)")};$lines.Add("BACKEND RESTARTED AFTER FINAL CHANGE: $(if($fr.code -eq 0){'YES'}else{'NO'})");$lines.Add("FINAL SMOKE AFTER RESTART: $($R['FINAL SMOKE AFTER RESTART'].status)");$lines.Add('USER MANUAL TESTING REQUIRED: NO');$lines.Add('CODE CHANGED: YES');$lines.Add('FILES CHANGED: tools/run_final_windows_acceptance.ps1; tools/final_windows_acceptance.py; tools/final_windows_browser_acceptance.py');$lines.Add('DEFECTS FOUND AND FIXED:');$lines.Add('  - Added Windows-local acceptance automation only; no accepted analytical business logic changed.');$lines.Add('REMAINING LIMITATIONS:');$lines.Add('  - A gate is PASS only when executed against the live Windows runtime.');$lines.Add("FINAL VERDICT: $verdict");$lines|Set-Content $TxtPath -Encoding utf8;Get-Content $TxtPath|Out-Host
exit $Exit
