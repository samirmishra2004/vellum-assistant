# Restart GCE guardian token lease + Vellum web dev server.
#
# Usage:
#   .\restart-gce-web.ps1
#   .\restart-gce-web.ps1 -AssistantName vellum-gce
#   .\restart-gce-web.ps1 -NoBrowser
#   .\restart-gce-web.ps1 -NoLease
#
# Double-click restart-gce-web.bat to run with defaults.

param(
  [string]$AssistantName = "vellum-gce",
  [string]$Project = $env:GCP_PROJECT,
  [string]$Zone = $env:GCP_DEFAULT_ZONE,
  [switch]$NoBrowser,
  [switch]$NoLease
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "gce-web-common.ps1")

$ctx = Resolve-GceWebContext -AssistantName $AssistantName -Project $Project -Zone $Zone
Set-GceWebEnvironment -Context $ctx

Write-Host ""
Write-Host "=== Vellum GCE web restart ===" -ForegroundColor Cyan
Write-Host "Assistant: $($ctx.AssistantName)"
Write-Host "Project:   $($ctx.Project)"
Write-Host "Zone:      $($ctx.Zone)"
Write-Host ""

Write-Host "[1/2] Stopping stale web server and SSH tunnels..."
Stop-GceWebStack -Context $ctx

Write-Host "[2/2] Starting web stack..."
Start-GceWebStack -Context $ctx -NoLease:$NoLease -NoBrowser:$NoBrowser
