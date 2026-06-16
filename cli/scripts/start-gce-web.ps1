# Start Vellum GCE web dev server (guardian lease + Vite client).
#
# Usage:
#   .\start-gce-web.ps1
#   .\start-gce-web.ps1 -AssistantName vellum-gce
#   .\start-gce-web.ps1 -NoBrowser
#   .\start-gce-web.ps1 -NoLease
#   .\start-gce-web.ps1 -Force
#   .\start-gce-web.ps1 -Foreground   # visible PowerShell window (default is background)
#
# Double-click start-gce-web.bat to run with defaults.
# If port 3000 is already serving the app, refreshes the guardian token and
# opens the browser. If port 3000 is stuck, stops stale processes and starts fresh.

param(
  [string]$AssistantName = "vellum-gce",
  [string]$Project = $env:GCP_PROJECT,
  [string]$Zone = $env:GCP_DEFAULT_ZONE,
  [switch]$NoBrowser,
  [switch]$NoLease,
  [switch]$Force,
  [switch]$Foreground
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "gce-web-common.ps1")

$ctx = Resolve-GceWebContext -AssistantName $AssistantName -Project $Project -Zone $Zone
Set-GceWebEnvironment -Context $ctx

Write-Host ""
Write-Host "=== Start Vellum GCE web ===" -ForegroundColor Cyan
Write-Host "Assistant: $($ctx.AssistantName)"
Write-Host "Project:   $($ctx.Project)"
Write-Host "Zone:      $($ctx.Zone)"
Write-Host ""

Start-GceWebStack -Context $ctx -NoLease:$NoLease -NoBrowser:$NoBrowser -Force:$Force -Background:(-not $Foreground)
