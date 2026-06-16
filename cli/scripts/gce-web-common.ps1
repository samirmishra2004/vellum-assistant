# Shared helpers for start/stop/restart GCE web client scripts.

$script:GceWebPorts = @{
  WebServer      = 3000
  GuardianTunnel = 17830
  MintTunnel     = 17831
}

$script:GceWebPortRangeStart = 3000
$script:GceWebPortRangeEnd   = 3010
$script:GceWebUrl            = "http://localhost:3000/assistant/"

function Get-GceWebPortRange {
  return $script:GceWebPortRangeStart..$script:GceWebPortRangeEnd
}

function Get-GceWebUrlForPort {
  param([int]$Port)
  return "http://localhost:$Port/assistant/"
}

function Set-GceWebPort {
  param(
    $Context,
    [int]$Port
  )
  $Context.Ports.WebServer = $Port
  $Context.WebUrl = Get-GceWebUrlForPort -Port $Port
}

function Get-GceWebScriptRoot {
  return Split-Path -Parent $MyInvocation.PSCommandPath
}

function Resolve-GceWebContext {
  param(
    [string]$AssistantName = "vellum-gce",
    [string]$Project = $env:GCP_PROJECT,
    [string]$Zone = $env:GCP_DEFAULT_ZONE
  )

  $scriptDir = Get-GceWebScriptRoot
  $cliDir = Resolve-Path (Join-Path $scriptDir "..")

  $paths = @(
    (Join-Path $env:USERPROFILE ".vellum.lock.json"),
    (Join-Path $env:LOCALAPPDATA "vellum\.vellum.lock.json")
  )
  foreach ($path in $paths) {
    if (-not (Test-Path $path)) { continue }
    try {
      $data = Get-Content $path -Raw | ConvertFrom-Json
      foreach ($entry in $data.assistants) {
        if ($entry.assistantId -eq $AssistantName) {
          if (-not $Project -and $entry.project) { $Project = $entry.project }
          if (-not $Zone -and $entry.zone) { $Zone = $entry.zone }
          break
        }
      }
    } catch {
      Write-Warning "Could not read lockfile at $path"
    }
    if ($Project -and $Zone) { break }
  }

  if (-not $Project) { $Project = "sam-world" }
  if (-not $Zone) { $Zone = "us-central1-a" }

  $bunBin = Join-Path $env:USERPROFILE ".bun\bin"
  if (Test-Path $bunBin) {
    $env:Path = "$bunBin;$env:Path"
  }

  return [PSCustomObject]@{
    AssistantName = $AssistantName
    Project       = $Project
    Zone          = $Zone
    CliDir        = $cliDir
    BunBin        = $bunBin
    WebUrl        = $script:GceWebUrl
    Ports         = $script:GceWebPorts
  }
}

function Test-PortBindable {
  param([int]$Port)
  $listener = $null
  try {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $Port)
    $listener.Start()
    return $true
  } catch {
    return $false
  } finally {
    if ($listener) {
      try { $listener.Stop() } catch { }
    }
  }
}

function Get-AvailableWebPort {
  param(
    [int]$Preferred = $script:GceWebPortRangeStart,
    [int]$Last = $script:GceWebPortRangeEnd
  )
  for ($port = $Preferred; $port -le $Last; $port++) {
    if (Test-PortBindable -Port $port) {
      return $port
    }
  }
  throw "No free web port in range $Preferred-$Last. Run stop-gce-web.bat and try again."
}

function Find-GceWebRunningUrl {
  param($Context)
  foreach ($port in (Get-GceWebPortRange)) {
    if (-not (Test-PortListening -Port $port)) { continue }
    $url = Get-GceWebUrlForPort -Port $port
    if (Wait-HttpReady -Url $url -TimeoutSec 3) {
      Set-GceWebPort -Context $Context -Port $port
      return $url
    }
  }
  return $null
}

function Set-GceWebEnvironment {
  param($Context)
  $env:GCP_PROJECT = $Context.Project
  $env:GCP_DEFAULT_ZONE = $Context.Zone
  $env:VELLUM_DISABLE_PLATFORM = "true"
  $env:VITE_VELLUM_DISABLE_PLATFORM = "true"
  $env:VITE_VELLUM_INITIAL_ASSISTANT_ID = $Context.AssistantName
}

function Get-PortListeners {
  param([int]$Port)
  $procIds = [System.Collections.Generic.HashSet[int]]::new()

  try {
    $conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    foreach ($conn in $conns) {
      $id = [int]$conn.OwningProcess
      if ($id -gt 0) {
        [void]$procIds.Add($id)
      }
    }
  } catch {
    # Fall back to netstat below.
  }

  if ($procIds.Count -eq 0) {
    $portPattern = ":$Port(?:\s|$)"
    $lines = netstat -ano -p TCP | Select-String "LISTENING" | Select-String $portPattern
    foreach ($line in $lines) {
      $parts = ($line.ToString().Trim() -split "\s+")
      $procIdText = $parts[-1]
      if ($procIdText -match "^\d+$") {
        $id = [int]$procIdText
        if ($id -gt 0) {
          [void]$procIds.Add($id)
        }
      }
    }
  }

  return @($procIds)
}

function Get-AlivePortListeners {
  param([int]$Port)
  $alive = @()
  foreach ($procId in (Get-PortListeners -Port $Port)) {
    if (Get-Process -Id $procId -ErrorAction SilentlyContinue) {
      $alive += $procId
    }
  }
  return $alive
}

function Stop-ProcessTree {
  param([int]$ProcId, [string]$Label = "PID $ProcId")
  if ($ProcId -le 0) { return $false }
  if (-not (Get-Process -Id $ProcId -ErrorAction SilentlyContinue)) {
    Write-Host "$Label already exited, skipping."
    return $false
  }
  Write-Host "Stopping $Label..."
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    & taskkill.exe /F /PID $ProcId /T *> $null
  } finally {
    $ErrorActionPreference = $prevEap
  }
  return $true
}

function Stop-GceWebClientProcesses {
  param($Context)
  $assistant = $Context.AssistantName
  $needles = @(
    "src/index.ts client $assistant",
    "src\index.ts client $assistant",
    "client $assistant --interface web",
    "client $assistant --interface web --disable-platform"
  )

  $stopped = 0
  $seen = [System.Collections.Generic.HashSet[int]]::new()
  $processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
  if (-not $processes) { return 0 }

  foreach ($proc in $processes) {
    $cmd = $proc.CommandLine
    if (-not $cmd) { continue }

    $matchesClient = $false
    foreach ($needle in $needles) {
      if ($cmd -like "*$needle*") {
        $matchesClient = $true
        break
      }
    }

    $matchesVite = ($cmd -match "apps[\\/]web") -and (
      $cmd -match "\bvite\b" -or $cmd -match "run dev"
    )

    if (-not $matchesClient -and -not $matchesVite) { continue }

    $procId = [int]$proc.ProcessId
    if ($procId -le 0 -or $seen.Contains($procId)) { continue }
    [void]$seen.Add($procId)
    if (Stop-ProcessTree -ProcId $procId -Label "web client process $procId") {
      $stopped++
    }
  }
  return $stopped
}

function Wait-PortFree {
  param(
    [int]$Port,
    [int]$TimeoutSec = 30
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  $zombieLogged = $false

  while ((Get-Date) -lt $deadline) {
    if (-not (Test-PortListening -Port $Port)) {
      return $true
    }

    $alive = Get-AlivePortListeners -Port $Port
    if ($alive.Count -gt 0) {
      foreach ($procId in $alive) {
        Stop-ProcessTree -ProcId $procId -Label "PID $procId (port $Port)"
      }
    } elseif (-not $zombieLogged) {
      Write-Host "Port $Port is stuck with no live owner (Windows socket cleanup). Waiting..."
      $zombieLogged = $true
    }

    Start-Sleep -Milliseconds 500
  }

  return -not (Test-PortListening -Port $Port)
}

function Test-PortListening {
  param([int]$Port)
  return (Get-PortListeners -Port $Port).Count -gt 0
}

function Stop-ListenersOnPort {
  param([int]$Port)
  $procIds = Get-PortListeners -Port $Port
  if ($procIds.Count -eq 0) {
    Write-Host "Port ${Port}: nothing listening."
    return 0
  }

  $stopped = 0
  foreach ($procId in $procIds) {
    if (Stop-ProcessTree -ProcId $procId -Label "PID $procId (port $Port)") {
      $stopped++
    }
  }
  return $stopped
}

function Stop-GceWebStack {
  param($Context)

  Write-Host "Stopping Vellum web client processes..."
  Stop-GceWebClientProcesses -Context $Context | Out-Null

  foreach ($port in (Get-GceWebPortRange)) {
    Write-Host "Stopping web server (port $port)..."
    Stop-ListenersOnPort -Port $port | Out-Null
  }
  Write-Host "Stopping guardian SSH tunnel (port $($Context.Ports.GuardianTunnel))..."
  Stop-ListenersOnPort -Port $Context.Ports.GuardianTunnel | Out-Null
  Write-Host "Stopping gateway mint tunnel (port $($Context.Ports.MintTunnel))..."
  Stop-ListenersOnPort -Port $Context.Ports.MintTunnel | Out-Null

  foreach ($port in @($Context.Ports.GuardianTunnel, $Context.Ports.MintTunnel)) {
    if (-not (Wait-PortFree -Port $port -TimeoutSec 15)) {
      Write-Warning "Port $port is still in use after stop."
    }
  }

  if (-not (Test-PortBindable -Port $script:GceWebPortRangeStart)) {
    Write-Host "Port $($script:GceWebPortRangeStart) is not bindable (stale Windows socket). Start will use the next free port." -ForegroundColor Yellow
  }
}

function Wait-HttpReady {
  param(
    [string]$Url,
    [int]$TimeoutSec = 120
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    try {
      $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 3
      if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 500) {
        return $true
      }
    } catch {
      # not ready yet
    }
    Start-Sleep -Seconds 2
  }
  return $false
}

function Invoke-GceGuardianLease {
  param($Context)
  Push-Location $Context.CliDir
  try {
    & bun run scripts/lease-gce-token.ts --name $Context.AssistantName
    if ($LASTEXITCODE -ne 0) {
      throw "lease-gce-token.ts failed with exit code $LASTEXITCODE"
    }
  } finally {
    Pop-Location
  }
}

function Get-GceWebClientLogPath {
  param($Context)
  $logDir = Join-Path $env:LOCALAPPDATA "vellum\logs"
  New-Item -ItemType Directory -Force -Path $logDir | Out-Null
  return Join-Path $logDir "gce-web-$($Context.AssistantName)-port$($Context.Ports.WebServer).log"
}

function Start-GceWebClient {
  param(
    $Context,
    [switch]$Background
  )
  $webPort = $Context.Ports.WebServer
  $webUrl = $Context.WebUrl
  $clientCmd = @"
`$env:Path = '$($Context.BunBin);' + `$env:Path
`$env:GCP_PROJECT = '$($Context.Project)'
`$env:GCP_DEFAULT_ZONE = '$($Context.Zone)'
`$env:VELLUM_DISABLE_PLATFORM = 'true'
`$env:VITE_VELLUM_DISABLE_PLATFORM = 'true'
`$env:VITE_VELLUM_INITIAL_ASSISTANT_ID = '$($Context.AssistantName)'
`$env:PORT = '$webPort'
`$env:VELLUM_WEB_URL = '$webUrl'
Set-Location '$($Context.CliDir)'
bun run src/index.ts client $($Context.AssistantName) --interface web --disable-platform
"@

  if ($Background) {
    $logFile = Get-GceWebClientLogPath -Context $Context
    $starterScript = Join-Path (Split-Path $logFile -Parent) "run-gce-web-$($Context.AssistantName)-port$webPort.ps1"
    @"
`$ErrorActionPreference = 'Continue'
`$logFile = '$logFile'
Add-Content -Path `$logFile -Value "`n==== Started `$(Get-Date -Format o) ===="
$clientCmd *>> `$logFile 2>&1
"@ | Set-Content -Path $starterScript -Encoding UTF8

    Start-Process powershell `
      -ArgumentList @("-NoProfile", "-WindowStyle", "Hidden", "-File", $starterScript) `
      -WindowStyle Hidden | Out-Null

    Write-Host "Web client running in background." -ForegroundColor Green
    Write-Host "Logs: $logFile" -ForegroundColor DarkGray
    return
  }

  Start-Process powershell -ArgumentList @("-NoExit", "-Command", $clientCmd) | Out-Null
}

function Start-GceWebClientWindow {
  param($Context)
  Start-GceWebClient -Context $Context
}

function Write-GceWebAuthHint {
  Write-Host ""
  Write-Host "If auth fails, hard-refresh (Ctrl+Shift+R) and clear localStorage:" -ForegroundColor Yellow
  Write-Host "  vellum:gw:token, vellum:gw:expiresAt, vellum:gw:tokenSource" -ForegroundColor Yellow
  Write-Host ""
}

function Start-GceWebStack {
  param(
    $Context,
    [switch]$NoLease,
    [switch]$NoBrowser,
    [switch]$SkipReadyWait,
    [switch]$Force,
    [switch]$Background
  )

  if ($Force) {
    Write-Host "Forcing clean restart..."
    Stop-GceWebStack -Context $Context
  } else {
    $runningUrl = Find-GceWebRunningUrl -Context $Context
    if ($runningUrl) {
      Write-Host "Web server already running at $runningUrl" -ForegroundColor Green
      if (-not $NoLease) {
        Write-Host "Refreshing guardian token (short SSH tunnel)..."
        Invoke-GceGuardianLease -Context $Context
      }
      if (-not $NoBrowser) {
        Write-Host "Opening browser..."
        Start-Process $runningUrl
      }
      Write-GceWebAuthHint
      return
    }
  }

  $staleListener = $false
  foreach ($port in (Get-GceWebPortRange)) {
    if ((Get-AlivePortListeners -Port $port).Count -gt 0) {
      $staleListener = $true
      break
    }
  }
  if ($staleListener) {
    Write-Host "Stopping stale web listeners..."
    Stop-GceWebStack -Context $Context
  }

  $webPort = Get-AvailableWebPort
  Set-GceWebPort -Context $Context -Port $webPort
  if ($webPort -ne $script:GceWebPortRangeStart) {
    Write-Host "Using port $webPort because $($script:GceWebPortRangeStart) is unavailable." -ForegroundColor Yellow
    Write-Host "Open: $($Context.WebUrl)" -ForegroundColor Yellow
  }

  if (-not $NoLease) {
    Write-Host "Leasing guardian token (short SSH tunnel)..."
    Invoke-GceGuardianLease -Context $Context
  } else {
    Write-Host "Skipping guardian token lease (-NoLease)."
  }

  if ($Background) {
    Write-Host "Starting web dev server in the background..."
  } else {
    Write-Host "Starting web dev server in a new window..."
  }
  Start-GceWebClient -Context $Context -Background:$Background

  if (-not $SkipReadyWait) {
    Write-Host "Waiting for $($Context.WebUrl) ..."
    if (-not (Wait-HttpReady -Url $Context.WebUrl -TimeoutSec 120)) {
      $hint = if ($Background) {
        "Check the log file under $env:LOCALAPPDATA\vellum\logs"
      } else {
        "Check the new PowerShell window for errors"
      }
      throw "Web server did not become ready within 120s. $hint."
    }
    Write-Host "Web server is up." -ForegroundColor Green
  }

  if (-not $NoBrowser) {
    Write-Host "Opening browser..."
    Start-Process $Context.WebUrl
  }

  Write-GceWebAuthHint
}
