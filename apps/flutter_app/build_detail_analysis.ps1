[CmdletBinding()]
param(
  [string]$ServingRoot = '',
  [string]$BaseHref = '/ui/',
  [string]$FirebaseWebApiKey = $env:INSIGHTFLOW_FIREBASE_WEB_API_KEY,
  [string]$FirebaseWebAppId = $env:INSIGHTFLOW_FIREBASE_WEB_APP_ID,
  [string]$FirebaseWebMessagingSenderId = $env:INSIGHTFLOW_FIREBASE_WEB_MESSAGING_SENDER_ID,
  [string]$FirebaseWebProjectId = $env:INSIGHTFLOW_FIREBASE_WEB_PROJECT_ID,
  [string]$FirebaseWebAuthDomain = $env:INSIGHTFLOW_FIREBASE_WEB_AUTH_DOMAIN,
  [string]$WorkspaceId = $env:INSIGHTFLOW_WORKSPACE_ID
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ServingRoot)) {
  throw 'Pass -ServingRoot with the backend directory that serves frontend/flutter_detail.'
}

$FlutterRoot = $PSScriptRoot
$StagingRoot = Join-Path $FlutterRoot 'build\detail_analysis_web'
$OutputRoot = Join-Path $ServingRoot 'frontend\flutter_detail'
$Target = Join-Path $FlutterRoot 'lib\detail_analysis_main.dart'

if (-not (Test-Path -LiteralPath $Target -PathType Leaf)) {
  throw "Detail Analysis entrypoint was not found: $Target"
}
if (-not (Test-Path -LiteralPath $ServingRoot -PathType Container)) {
  throw "Serving project was not found: $ServingRoot"
}

function Assert-SafeOutputPath([string]$Path, [string]$Root) {
  $resolvedPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
  $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
  if (-not $resolvedPath.StartsWith($resolvedRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to replace output outside the serving project: $resolvedPath"
  }
}

Assert-SafeOutputPath $OutputRoot $ServingRoot

if (Test-Path -LiteralPath $StagingRoot) {
  Remove-Item -LiteralPath $StagingRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $StagingRoot -Force | Out-Null

Push-Location $FlutterRoot
try {
  Write-Host "Building standalone Detail Analysis Flutter target..."
  $buildArgs = @(
    'build',
    'web',
    '--release',
    '--target',
    $Target,
    '--base-href',
    $BaseHref,
    '--output-dir',
    $StagingRoot
  )
  $dartDefines = @{
    'INSIGHTFLOW_FIREBASE_WEB_API_KEY' = $FirebaseWebApiKey
    'INSIGHTFLOW_FIREBASE_WEB_APP_ID' = $FirebaseWebAppId
    'INSIGHTFLOW_FIREBASE_WEB_MESSAGING_SENDER_ID' = $FirebaseWebMessagingSenderId
    'INSIGHTFLOW_FIREBASE_WEB_PROJECT_ID' = $FirebaseWebProjectId
    'INSIGHTFLOW_FIREBASE_WEB_AUTH_DOMAIN' = $FirebaseWebAuthDomain
    'INSIGHTFLOW_WORKSPACE_ID' = $WorkspaceId
  }
  foreach ($entry in $dartDefines.GetEnumerator()) {
    if (-not [string]::IsNullOrWhiteSpace($entry.Value)) {
      $buildArgs += "--dart-define=$($entry.Key)=$($entry.Value)"
    }
  }
  & flutter @buildArgs
  if ($LASTEXITCODE -ne 0) {
    throw "Flutter build failed with exit code $LASTEXITCODE."
  }
}
finally {
  Pop-Location
}

$standaloneIndex = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <base href="$BaseHref">
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <meta name="theme-color" content="#020715">
  <title>Detail Analysis</title>
</head>
<body>
  <script src="flutter_bootstrap.js" async></script>
</body>
</html>
"@
Set-Content -LiteralPath (Join-Path $StagingRoot 'index.html') -Value $standaloneIndex -Encoding utf8

# The shared Flutter web directory contains Excel-only helper assets. They are
# valid for the add-in build but must not ship with the standalone target.
Get-ChildItem -LiteralPath $StagingRoot -Recurse -File |
  Where-Object {
    $_.Name -eq 'deploy.ps1' -or
    $_.Name -like 'excel_*.js'
  } |
  Remove-Item -Force

if (Test-Path -LiteralPath $OutputRoot) {
  Remove-Item -LiteralPath $OutputRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
Copy-Item -Path (Join-Path $StagingRoot '*') -Destination $OutputRoot -Recurse -Force

$indexPath = Join-Path $OutputRoot 'index.html'
$mainJsPath = Join-Path $OutputRoot 'main.dart.js'
$bootstrapPath = Join-Path $OutputRoot 'flutter_bootstrap.js'
$frontendBuildId = (Get-FileHash -LiteralPath $mainJsPath -Algorithm SHA256).Hash.Substring(0, 12).ToLowerInvariant()
$indexText = Get-Content -LiteralPath $indexPath -Raw
$indexText = $indexText.Replace(
  '<meta name="theme-color" content="#020715">',
  ('<meta name="theme-color" content="#020715">' + [Environment]::NewLine +
   '  <meta name="detail-analysis-build-id" content="' + $frontendBuildId + '">')
)
Set-Content -LiteralPath $indexPath -Value $indexText -Encoding utf8
foreach ($required in @($indexPath, $mainJsPath, $bootstrapPath)) {
  if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
    throw "Standalone build is missing required file: $required"
  }
}

$requiredShaders = @(
  'lightweight_glass.frag',
  'interactive_indicator.frag',
  'liquid_glass_geometry_blended.frag',
  'liquid_glass_final_render.frag'
)
foreach ($shader in $requiredShaders) {
  $shaderPath = Join-Path $OutputRoot "assets\shaders\$shader"
  if (-not (Test-Path -LiteralPath $shaderPath -PathType Leaf)) {
    throw "Standalone Detail Analysis build is missing compiled shader asset: $shaderPath"
  }
}

$standaloneFiles = Get-ChildItem -LiteralPath $OutputRoot -Recurse -File
$officeMatch = Select-String -Path $standaloneFiles.FullName -Pattern 'appsforoffice\.com|office\.js' -CaseSensitive:$false -SimpleMatch:$false -ErrorAction SilentlyContinue
if ($officeMatch) {
  throw "Office.js or Excel add-in assumptions found in standalone output: $($officeMatch.Path -join ', ')"
}

$indexText = Get-Content -LiteralPath $indexPath -Raw
$mainJsText = Get-Content -LiteralPath $mainJsPath -Raw
if ($indexText -notmatch '<base href="/ui/">') {
  throw "Standalone index.html does not use the /ui/ base href."
}
if ($indexText -notmatch 'Detail Analysis') {
  throw "Standalone index.html does not identify the Detail Analysis application."
}
if ($indexText -notmatch "detail-analysis-build-id.*$frontendBuildId") {
  throw "Standalone index.html does not expose the generated frontend build identity."
}
if ($mainJsText -notmatch 'native-star-schema') {
  throw "Generated main.dart.js does not contain the native StarSchemaView marker."
}

Write-Host "Standalone Detail Analysis build verified: $OutputRoot"
Write-Host "Excel add-in source template was not changed: $(Join-Path $FlutterRoot 'web\index.html')"
