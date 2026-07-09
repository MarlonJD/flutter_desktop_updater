$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
  Write-Host 'not run: Windows Inno smoke requires Windows.'
  exit 0
}

$iscc = Get-Command iscc -ErrorAction SilentlyContinue
if ($null -eq $iscc) {
  Write-Host 'not run: Inno Setup Compiler is not installed.'
  exit 0
}

New-Item -ItemType Directory -Force -Path reports | Out-Null
$diagnostics = Join-Path (Get-Location) 'reports/windows-inno-update-smoke-diagnostics.jsonl'
if (Test-Path -LiteralPath $diagnostics) {
  Remove-Item -LiteralPath $diagnostics -Force
}

Write-Host 'Windows Inno smoke prerequisites are available.'
Write-Host "Diagnostics: $diagnostics"
