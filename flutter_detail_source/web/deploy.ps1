param(
  [string]$BaseHref = '/data_analysis/',
  [string]$GhPagesBranch = 'gh-pages',
  [string]$FirebaseWebApiKey = $env:INSIGHTFLOW_FIREBASE_WEB_API_KEY,
  [string]$FirebaseWebAppId = $env:INSIGHTFLOW_FIREBASE_WEB_APP_ID,
  [string]$FirebaseWebMessagingSenderId = $env:INSIGHTFLOW_FIREBASE_WEB_MESSAGING_SENDER_ID,
  [string]$FirebaseWebProjectId = $env:INSIGHTFLOW_FIREBASE_WEB_PROJECT_ID,
  [string]$FirebaseWebAuthDomain = $env:INSIGHTFLOW_FIREBASE_WEB_AUTH_DOMAIN,
  [string]$GoogleWebClientId = $env:INSIGHTFLOW_GOOGLE_WEB_CLIENT_ID,
  [string]$WorkspaceId = $env:INSIGHTFLOW_WORKSPACE_ID
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
Push-Location $RepoRoot
$DeployDir = Join-Path ([System.IO.Path]::GetTempPath()) ("insightflow-gh-pages-" + [guid]::NewGuid().ToString('N'))
try {
  $SourceCommit = (git rev-parse HEAD).Trim()
  $CurrentBranch = (git branch --show-current).Trim()
  if ($CurrentBranch -ne 'feature/data-workspace') {
    throw "Refusing deployment from '$CurrentBranch'. Expected feature/data-workspace."
  }

  $requiredDefines = @{
    'INSIGHTFLOW_FIREBASE_WEB_API_KEY' = $FirebaseWebApiKey
    'INSIGHTFLOW_FIREBASE_WEB_APP_ID' = $FirebaseWebAppId
    'INSIGHTFLOW_FIREBASE_WEB_MESSAGING_SENDER_ID' = $FirebaseWebMessagingSenderId
    'INSIGHTFLOW_FIREBASE_WEB_PROJECT_ID' = $FirebaseWebProjectId
    'INSIGHTFLOW_FIREBASE_WEB_AUTH_DOMAIN' = $FirebaseWebAuthDomain
    'INSIGHTFLOW_GOOGLE_WEB_CLIENT_ID' = $GoogleWebClientId
    'INSIGHTFLOW_WORKSPACE_ID' = $WorkspaceId
  }
  $missingDefines = @(
    $requiredDefines.GetEnumerator() |
      Where-Object { [string]::IsNullOrWhiteSpace($_.Value) } |
      ForEach-Object { $_.Key }
  )
  if ($missingDefines.Count -gt 0) {
    throw "Missing Firebase/Workspace build configuration: $($missingDefines -join ', ')"
  }

  $buildArgs = @('build', 'web', '--release', '--no-wasm-dry-run', '--base-href', $BaseHref)
  foreach ($entry in $requiredDefines.GetEnumerator()) {
    $buildArgs += "--dart-define=$($entry.Key)=$($entry.Value)"
  }
  flutter @buildArgs

  $BuildWeb = Join-Path $RepoRoot 'build\web'
  $IndexPath = Join-Path $BuildWeb 'index.html'
  if (-not (Test-Path $IndexPath)) {
    throw "Flutter build did not produce build\web\index.html."
  }

  $Index = Get-Content -Raw -Path $IndexPath
  $Index = $Index.Replace('__INSIGHTFLOW_BUILD_COMMIT__', $SourceCommit)
  Set-Content -Path $IndexPath -Value $Index -NoNewline

  foreach ($Required in @(
    'index.html',
    'flutter_bootstrap.js',
    'main.dart.js',
    'excel_data_processor.js',
    'excel_helper.js',
    'excel_quality_report_generator.js'
  )) {
    if (-not (Test-Path (Join-Path $BuildWeb $Required))) {
      throw "Excel-enabled build is missing required asset: $Required"
    }
  }

  if ($Index -notmatch 'https://appsforoffice\.microsoft\.com/lib/1/hosted/office\.js') {
    throw 'Excel build is missing Office.js.'
  }
  if ($Index -notmatch [regex]::Escape($SourceCommit)) {
    throw 'Excel build source marker was not stamped.'
  }

  git fetch origin $GhPagesBranch
  git worktree add --detach $DeployDir ("origin/" + $GhPagesBranch)
  try {
    git -C $DeployDir rm -r --ignore-unmatch .
    Get-ChildItem -LiteralPath $BuildWeb -Force | ForEach-Object {
      Copy-Item -LiteralPath $_.FullName -Destination $DeployDir -Recurse -Force
    }

    git -C $DeployDir add -A
    if (git -C $DeployDir diff --cached --quiet) {
      Write-Host "No deployment changes for $SourceCommit."
      return
    }

    git -C $DeployDir -c user.name='PritishMete' -c user.email='jaiphotoshoot@gmail.com' `
      commit -m "Deploy Excel add-in $SourceCommit"
    git -C $DeployDir push origin ("HEAD:" + $GhPagesBranch)
  }
  finally {
    git worktree remove --force $DeployDir
  }
}
finally {
  if (Test-Path $DeployDir) {
    Remove-Item -Recurse -Force $DeployDir -ErrorAction SilentlyContinue
  }
  Pop-Location
}
