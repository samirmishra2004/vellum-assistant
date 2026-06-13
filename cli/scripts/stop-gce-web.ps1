# Stop Vellum GCE web dev server and local SSH tunnels.
#
# Usage:
#   .\stop-gce-web.ps1
#   .\stop-gce-web.ps1 -AssistantName vellum-gce
#
# Double-click stop-gce-web.bat to run with defaults.

param(
  [string]$AssistantName = "vellum-gce"
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "gce-web-common.ps1")

$ctx = Resolve-GceWebContext -AssistantName $AssistantName

Write-Host ""
Write-Host "=== Stop Vellum GCE web ===" -ForegroundColor Cyan
Write-Host "Assistant: $($ctx.AssistantName)"
Write-Host ""

Stop-GceWebStack -Context $ctx

Write-Host ""
Write-Host "Stopped (or nothing was running)." -ForegroundColor Green
Write-Host ""
