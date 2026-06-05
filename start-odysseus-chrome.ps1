[CmdletBinding()]
param(
  [switch]$NoOpen
)

$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Port = 7000
$Url = "http://127.0.0.1:$Port"
$Python = Join-Path $ProjectRoot "venv\Scripts\python.exe"
$LogDir = Join-Path $ProjectRoot "logs"
$StdoutLog = Join-Path $LogDir "odysseus-shortcut.out.log"
$StderrLog = Join-Path $LogDir "odysseus-shortcut.err.log"

function Test-OdysseusListening {
  try {
    $conn = Get-NetTCPConnection -LocalAddress "127.0.0.1" -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    return [bool]$conn
  } catch {
    return $false
  }
}

function Get-ChromePath {
  $candidates = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
  )
  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) {
      return $candidate
    }
  }
  return $null
}

if (-not (Test-Path -LiteralPath $Python)) {
  throw "Python venv not found: $Python"
}

if (-not (Test-OdysseusListening)) {
  New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
  $env:DEBUG = "false"
  Start-Process `
    -FilePath $Python `
    -ArgumentList @("-m", "uvicorn", "app:app", "--host", "127.0.0.1", "--port", "$Port") `
    -WorkingDirectory $ProjectRoot `
    -WindowStyle Hidden `
    -RedirectStandardOutput $StdoutLog `
    -RedirectStandardError $StderrLog | Out-Null

  $deadline = (Get-Date).AddSeconds(45)
  while ((Get-Date) -lt $deadline) {
    if (Test-OdysseusListening) { break }
    Start-Sleep -Milliseconds 500
  }
}

if (-not $NoOpen) {
  $Chrome = Get-ChromePath
  if ($Chrome) {
    Start-Process -FilePath $Chrome -ArgumentList @($Url)
  } else {
    Start-Process $Url
  }
}
