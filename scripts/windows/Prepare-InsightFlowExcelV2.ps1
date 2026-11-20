[CmdletBinding()]
param(
    [string]$SupabaseUrl,
    [string]$SupabasePublishableKey,
    [string]$AddinGuid,
    [string]$DbUser = "postgres",
    [string]$DbName = "insightflow_excel_test",
    [int]$BackendPort = 8000,
    [int]$PanePort = 3000
)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) { throw "Required command '$Name' was not found. Install it and reopen PowerShell." }
}
function New-RandomBytes([int]$Count) {
    $bytes = New-Object byte[] $Count
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return ,$bytes
}
function Stop-ProcessTree($Process) {
    if ($null -ne $Process -and -not $Process.HasExited) {
        & taskkill.exe /PID $Process.Id /T /F 2>$null | Out-Null
    }
}
function Clear-BackendEnvironment {
    Remove-Item Env:DATABASE_URL,Env:INSIGHTFLOW_EXCEL_HANDOFF_ENCRYPTION_KEY,Env:INSIGHTFLOW_EXCEL_HANDOFF_PAIRING_KEY,Env:SUPABASE_URL,Env:SUPABASE_PUBLISHABLE_KEY,Env:INSIGHTFLOW_CORS_ORIGINS,Env:BUILD_GIT_SHA,Env:AUTHZ_PERSISTENCE_PROVIDER -ErrorAction SilentlyContinue
}
function Wait-Url([string]$Url, [int]$Seconds = 45) {
    for ($i = 0; $i -lt $Seconds; $i++) {
        try { $response = Invoke-WebRequest -Uri $Url -TimeoutSec 3; if ($response.StatusCode -eq 200) { return } }
        catch { Start-Sleep -Seconds 1 }
    }
    throw "URL did not become reachable: $Url"
}

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..\")).Path
$flutterDir = Join-Path $repo "apps\flutter_app"
$manifest = Join-Path $flutterDir "excel\InsightFlow.localtest.addin.xml"
$migration37 = Join-Path $repo "migrations\0037_excel_auth_handoff.sql"
$migration38 = Join-Path $repo "migrations\0038_excel_auth_pairing.sql"
$localRoot = Join-Path $env:LOCALAPPDATA "InsightFlow\ExcelV2"
$certDir = Join-Path $localRoot "certs"
$catalogDir = Join-Path $localRoot "OfficeAddins"
$certFile = Join-Path $certDir "localhost.pem"
$keyFile = Join-Path $certDir "localhost-key.pem"
$runtimeManifest = Join-Path $catalogDir "InsightFlow.localtest.addin.xml"

foreach ($command in @("git", "python", "psql", "pg_isready", "createdb", "mkcert", "flutter", "node", "npx")) { Require-Command $command }
if (-not (Test-Path $manifest) -or -not (Test-Path $migration37) -or -not (Test-Path $migration38)) { throw "Run this script from a complete checkout of excel-v2-session-handoff." }
$branch = (& git -C $repo branch --show-current).Trim()
if ($branch -ne "excel-v2-session-handoff") { throw "Expected branch excel-v2-session-handoff; current branch is '$branch'. No files were changed." }
$head = (& git -C $repo rev-parse HEAD).Trim()
Write-Host "Repository: $repo"
Write-Host "Branch: $branch"
Write-Host "Commit: $head"

if ([string]::IsNullOrWhiteSpace($AddinGuid)) { throw "Supply the exact owner-approved stable add-in GUID with -AddinGuid. This script will not generate or prompt for an add-in identity." }
$parsedGuid = [guid]::Empty
if (-not [guid]::TryParse($AddinGuid, [ref]$parsedGuid) -or $parsedGuid -eq [guid]::Empty -or $parsedGuid.ToString() -eq "00000000-0000-0000-0000-000000000001") { throw "A valid owner-approved GUID is required. The tracked placeholder is not accepted; obtain the exact value from the add-in owner." }
$AddinGuid = $parsedGuid.ToString()

if (-not $SupabaseUrl) { $SupabaseUrl = Read-Host "Development Supabase project URL (https://<project-ref>.supabase.co)" }
if ($SupabaseUrl -notmatch '^https://[a-z0-9-]+\.supabase\.co/?$' -or $SupabaseUrl -match 'zfdgwnipdyrpbardqoql') { throw "Use a dedicated development Supabase project, not the connected production project." }
$SupabaseUrl = $SupabaseUrl.TrimEnd("/")
if (-not $SupabasePublishableKey) { $SupabasePublishableKey = Read-Host "Development Supabase publishable key (sb_publishable_... or legacy anon key)" }
if ([string]::IsNullOrWhiteSpace($SupabasePublishableKey) -or $SupabasePublishableKey -match 'service_role') { throw "A Supabase publishable/anon key is required. A service-role key is forbidden." }

$pgVersion = (& psql --version)
if ($pgVersion -notmatch 'PostgreSQL\)\s+16\.') { throw "Install PostgreSQL 16 client tools. Detected: $pgVersion" }
foreach ($port in @($BackendPort,$PanePort)) {
    if (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue) { throw "Port $port is already in use. Stop the existing process or choose another port." }
}
& pg_isready -h 127.0.0.1 -p 5432 | Out-Host
if ($LASTEXITCODE -ne 0) { throw "Local PostgreSQL is not accepting connections on 127.0.0.1:5432." }

$dbPasswordSecure = Read-Host "Local PostgreSQL password for role '$DbUser' (disposable local DB only)" -AsSecureString
$dbPassword = [Net.NetworkCredential]::new("", $dbPasswordSecure).Password
$env:PGPASSWORD = $dbPassword
try {
    $serverVersion = (& psql -h 127.0.0.1 -p 5432 -U $DbUser -d postgres -Atqc "SHOW server_version_num").Trim()
    if ([int]$serverVersion -lt 160000 -or [int]$serverVersion -ge 170000) { throw "Connected PostgreSQL server must be version 16. server_version_num=$serverVersion" }
    if ($DbName -notmatch '^insightflow_excel_test(_[a-z0-9_]+)?$') { throw "Database name must be insightflow_excel_test or insightflow_excel_test_<suffix>." }
    $exists = (& psql -h 127.0.0.1 -p 5432 -U $DbUser -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname = '$DbName'").Trim()
    if ($exists -eq "1") { throw "Database '$DbName' already exists. Use a fresh disposable database name; existing databases are never modified." }
    & createdb -h 127.0.0.1 -p 5432 -U $DbUser $DbName
    if ($LASTEXITCODE -ne 0) { throw "createdb failed." }
    & psql -h 127.0.0.1 -p 5432 -U $DbUser -d $DbName -v ON_ERROR_STOP=1 -f $migration37
    if ($LASTEXITCODE -ne 0) { throw "Migration 0037 failed. Stop and inspect the disposable database." }
    & psql -h 127.0.0.1 -p 5432 -U $DbUser -d $DbName -v ON_ERROR_STOP=1 -f $migration38
    if ($LASTEXITCODE -ne 0) { throw "Migration 0038 failed. Stop and inspect the disposable database." }
    $table = (& psql -h 127.0.0.1 -p 5432 -U $DbUser -d $DbName -Atqc "SELECT to_regclass('excel_handoff.transactions')").Trim()
    if ($table -ne "excel_handoff.transactions") { throw "Excel handoff table verification failed after migrations." }
} catch {
    $dbPassword = $null
    $dbPasswordSecure = $null
    throw
} finally { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue }

$dbUserEscaped = [uri]::EscapeDataString($DbUser)
$dbPasswordEscaped = [uri]::EscapeDataString($dbPassword)
$env:DATABASE_URL = "postgresql+psycopg://$($dbUserEscaped):$($dbPasswordEscaped)@127.0.0.1:5432/$DbName"
$env:INSIGHTFLOW_EXCEL_HANDOFF_ENCRYPTION_KEY = [Convert]::ToBase64String((New-RandomBytes 32)).Replace("+", "-").Replace("/", "_")
$env:INSIGHTFLOW_EXCEL_HANDOFF_PAIRING_KEY = [Convert]::ToBase64String((New-RandomBytes 32))
$env:SUPABASE_URL = $SupabaseUrl
$env:SUPABASE_PUBLISHABLE_KEY = $SupabasePublishableKey
$env:INSIGHTFLOW_CORS_ORIGINS = "https://localhost:$PanePort,http://localhost:$PanePort,https://127.0.0.1:$PanePort,http://127.0.0.1:$PanePort"
$env:BUILD_GIT_SHA = "local-$head"
$env:AUTHZ_PERSISTENCE_PROVIDER = "supabase"
Remove-Item Env:RENDER,Env:RENDER_SERVICE_ID -ErrorAction SilentlyContinue

$backend = $null
$pane = $null
try {
New-Item -ItemType Directory -Path $certDir,$catalogDir -Force | Out-Null
& mkcert -install
if ($LASTEXITCODE -ne 0) { throw "mkcert could not install its local development CA. Re-run elevated if Windows prompts for trust installation." }
& mkcert -cert-file $certFile -key-file $keyFile localhost 127.0.0.1 ::1
if ($LASTEXITCODE -ne 0) { throw "mkcert certificate creation failed." }

$xmlText = Get-Content -Raw -Path $manifest
$xmlText = [regex]::Replace($xmlText, '<Id>[^<]+</Id>', "<Id>$AddinGuid</Id>", 1)
$xmlText = $xmlText.Replace('https://localhost:3000/', "https://localhost:$PanePort/").Replace('https://localhost:3000</AppDomain>', "https://localhost:$PanePort</AppDomain>")
[xml]$xmlCheck = $xmlText
$idNode = $xmlCheck.SelectSingleNode("/*[local-name()='OfficeApp']/*[local-name()='Id']")
$sourceNode = $xmlCheck.SelectSingleNode("/*[local-name()='OfficeApp']/*[local-name()='DefaultSettings']/*[local-name()='SourceLocation']")
if ($null -eq $idNode -or $idNode.InnerText -ne $AddinGuid -or $null -eq $sourceNode -or $sourceNode.GetAttribute("DefaultValue") -ne "https://localhost:$PanePort/") { throw "Generated local manifest failed validation." }
Set-Content -Path $runtimeManifest -Value $xmlText -Encoding UTF8

Push-Location $repo
try {
    & python -c "import fastapi, sqlalchemy, psycopg, cryptography"
    if ($LASTEXITCODE -ne 0) { throw "Backend Python dependencies are missing. Install them with: python -m pip install -r requirements.txt" }
    & python -c "import uvicorn"
    if ($LASTEXITCODE -ne 0) { throw "Uvicorn is missing. Install the repository requirements first." }
    $quotedCert = '"' + $certFile + '"'
    $quotedKey = '"' + $keyFile + '"'
    $backendArgs = @("-m", "uvicorn", "main:app", "--host", "127.0.0.1", "--port", "$BackendPort", "--ssl-certfile", $quotedCert, "--ssl-keyfile", $quotedKey)
    $backend = Start-Process -FilePath "python" -ArgumentList $backendArgs -WorkingDirectory $repo -PassThru
} finally { Pop-Location }
} catch {
    Stop-ProcessTree $backend
    Clear-BackendEnvironment
    $dbPassword = $null
    $dbPasswordEscaped = $null
    throw "Certificate, manifest or backend startup preparation failed. $($_.Exception.Message)"
}

try { Wait-Url "https://localhost:$BackendPort/health" 60 }
catch {
    Stop-ProcessTree $backend
    Clear-BackendEnvironment
    $dbPassword = $null
    throw "Local HTTPS backend did not start. Check dependencies and local DB settings. $($_.Exception.Message)"
}

Clear-BackendEnvironment
$dbPassword = $null
$dbPasswordEscaped = $null
$dbPasswordSecure = $null
try {
Push-Location $flutterDir
try {
    & flutter pub get
    if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed." }
    & flutter build web --release --base-href "/" "--dart-define=INSIGHTFLOW_BACKEND_URL=https://localhost:$BackendPort" "--dart-define=INSIGHTFLOW_SUPABASE_URL=$SupabaseUrl" "--dart-define=INSIGHTFLOW_SUPABASE_PUBLISHABLE_KEY=$SupabasePublishableKey" "--dart-define=INSIGHTFLOW_AUTH_REDIRECT_URL=https://localhost:$PanePort/"
    if ($LASTEXITCODE -ne 0) { throw "Flutter Web release build failed." }
    $paneCommand = "npx --yes http-server build/web -a 127.0.0.1 -p $PanePort -S -C `"$certFile`" -K `"$keyFile`""
    $pane = Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", $paneCommand) -WorkingDirectory $flutterDir -PassThru
} finally { Pop-Location }

Wait-Url "https://localhost:$PanePort/" 60
} catch {
    Stop-ProcessTree $pane
    Stop-ProcessTree $backend
    throw "Windows test environment setup failed. Started services were stopped. $($_.Exception.Message)"
}
Write-Host ""
Write-Host "LOCAL EXCEL V2 TEST ENVIRONMENT READY" -ForegroundColor Green
Write-Host "Backend:        https://localhost:$BackendPort/health"
Write-Host "Task pane:      https://localhost:$PanePort/"
Write-Host "Local manifest: $runtimeManifest"
Write-Host "Add-in GUID:    $AddinGuid"
Write-Host "Backend PID:    $($backend.Id)"
Write-Host "Pane PID:       $($pane.Id)"
Write-Host "Database:       127.0.0.1:5432/$DbName (local disposable PostgreSQL 16)"
Write-Host "Local keys and DB password are process environment only. Do not paste them into logs or commit them."
Write-Host "Stop services after acceptance with:"
Write-Host "  taskkill.exe /PID $($pane.Id) /T /F"
Write-Host "  taskkill.exe /PID $($backend.Id) /T /F"
