# Restart Vellum GCE web on a fixed port (default 3001).
# Runs the web client in a hidden background process by default (safe to close this window).
param(
  [string]$AssistantName = "vellum-gce",
  [string]$Project = $env:GCP_PROJECT,
  [string]$Zone = $env:GCP_DEFAULT_ZONE,
  [int]$WebPort = 3001,
  [switch]$NoBrowser,
  [switch]$NoLease,
  [switch]$Foreground
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "gce-web-common.ps1")

$ctx = Resolve-GceWebContext -AssistantName $AssistantName -Project $Project -Zone $Zone
Set-GceWebEnvironment -Context $ctx
Set-GceWebPort -Context $ctx -Port $WebPort

Write-Host ""
Write-Host "=== Vellum GCE web restart (port $WebPort) ===" -ForegroundColor Cyan
Write-Host "Assistant: $($ctx.AssistantName)"
Write-Host "URL:       $($ctx.WebUrl)"
Write-Host ""

Write-Host "[1/2] Stopping stale web server and SSH tunnels..."
Stop-GceWebStack -Context $ctx

Write-Host "[2/2] Starting web stack on port $WebPort..."
if (-not $NoLease) {
  Write-Host "Leasing guardian token..."
  Invoke-GceGuardianLease -Context $ctx
}

$background = -not $Foreground
if ($background) {
  Write-Host "Starting web dev server in the background..."
} else {
  Write-Host "Starting web dev server in a new window..."
}
Start-GceWebClient -Context $ctx -Background:$background

Write-Host "Waiting for $($ctx.WebUrl) ..."
if (-not (Wait-HttpReady -Url $ctx.WebUrl -TimeoutSec 180)) {
  $hint = if ($background) {
    "Check the log under $env:LOCALAPPDATA\vellum\logs"
  } else {
    "Check the new PowerShell window for errors"
  }
  throw "Web server did not become ready within 180s. $hint."
}

Write-Host "Ready: $($ctx.WebUrl)" -ForegroundColor Green
Write-GceWebAuthHint

if (-not $NoBrowser) {
  Write-Host "Opening browser..."
  Start-Process $ctx.WebUrl
}
