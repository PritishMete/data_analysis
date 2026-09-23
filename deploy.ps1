param(
  [string]$BaseHref = '/data_analysis/',
  [string]$RemoteUrl = 'https://github.com/PritishMete/data_analysis.git'
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
Push-Location $RepoRoot
try {
  flutter build web --base-href $BaseHref

  $BuildWeb = Join-Path $RepoRoot 'build\web'
  Push-Location $BuildWeb
  try {
    if (-not (Test-Path .git)) {
      git init
    }

    $originUrl = git remote get-url origin 2>$null
    if ($LASTEXITCODE -eq 0 -and $originUrl) {
      git remote remove origin
    }

    git remote add origin $RemoteUrl
    git add -A
    git commit -m "Deploy production web assets to gh-pages"
    git branch -M gh-pages
    git push -f origin gh-pages
  }
  finally {
    Pop-Location
  }
}
finally {
  Pop-Location
}
