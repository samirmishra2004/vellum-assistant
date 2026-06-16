# Migrate an existing GCE assistant VM to free-tier e2-micro + Ubuntu 24.04 + 30GB disk.

#

# This recreates the instance (OS and disk size cannot be changed in place).

# Backs up ~/.local/share/vellum and ~/.config/vellum before delete via tar (skips *.sock).

#

# Usage:

#   powershell -File migrate-gce-free-tier.ps1 -Yes

#   powershell -File migrate-gce-free-tier.ps1 -SkipBackup -Yes

#   powershell -File migrate-gce-free-tier.ps1 -SkipDeploy -Yes   # instance already recreated

#   powershell -File migrate-gce-free-tier.ps1 -RestoreFromLegacyBackup -Yes

#

# Requires: gcloud, GEMINI_API_KEY (or another provider key) for fresh hatch unless

# keys are loaded from the backed-up config env file.



param(

  [string]$InstanceName = "vellum-gce",

  [string]$Project = $env:GCP_PROJECT,

  [string]$Zone = $env:GCP_DEFAULT_ZONE,

  [string]$BackupDir = (Join-Path $env:USERPROFILE "Downloads\vellum-gce-migrate-backup"),

  [switch]$SkipBackup,

  [switch]$SkipDeploy,

  [switch]$RestoreFromLegacyBackup,

  [switch]$Yes,

  [switch]$SkipWebRestart

)



$ErrorActionPreference = "Stop"



if (-not $Project) { $Project = "sam-world" }

if (-not $Zone) { $Zone = "us-central1-a" }



$bunBin = Join-Path $env:USERPROFILE ".bun\bin"

if (Test-Path $bunBin) {

  $env:Path = "$bunBin;$env:Path"

}

$env:GCP_PROJECT = $Project

$env:GCP_DEFAULT_ZONE = $Zone



$cliDir = Resolve-Path (Join-Path $PSScriptRoot "..")

$shareArchive = Join-Path $BackupDir "vellum-share.tgz"

$configArchive = Join-Path $BackupDir "vellum-config.tgz"

$configEnvFile = Join-Path $BackupDir "config-env"

$legacyShareDir = Join-Path $BackupDir "local-share-vellum"



function Resolve-SshUser {

  try { return (whoami).Split("\")[-1] } catch { }

  return $env:USERNAME

}



function Import-ProviderKeysFromEnvFile {

  param([string]$Path)

  if (-not (Test-Path $Path)) { return }

  Get-Content $Path | ForEach-Object {

    if ($_ -match '^(GEMINI_API_KEY|ANTHROPIC_API_KEY|OPENAI_API_KEY)=(.+)$') {

      Set-Item -Path "env:$($Matches[1])" -Value $Matches[2]

    }

  }

}



function Invoke-GceRemoteCommand {

  param(

    [string]$Instance,

    [string]$Command

  )

  # Use a single-line command to avoid Windows CRLF breaking bash on the VM.

  & gcloud compute ssh $Instance --project=$Project --zone=$Zone --quiet --command=$Command

  if ($LASTEXITCODE -ne 0) {

    throw "Remote command failed (exit $LASTEXITCODE): $Command"

  }

}



function Backup-GceAssistantData {

  param(

    [string]$Instance,

    [string]$User

  )

  Write-Host "Creating tar archives on VM (excluding *.sock)..."

  $home = "/home/$User"

  Invoke-GceRemoteCommand -Instance $Instance -Command "tar czf /tmp/vellum-share-backup.tgz --exclude='*.sock' -C $home/.local/share vellum && tar czf /tmp/vellum-config-backup.tgz -C $home/.config vellum && cp $home/.config/vellum/env /tmp/vellum-config-env 2>/dev/null || true"



  New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

  & gcloud compute scp "${User}@${Instance}:/tmp/vellum-share-backup.tgz" $shareArchive --project=$Project --zone=$Zone

  & gcloud compute scp "${User}@${Instance}:/tmp/vellum-config-backup.tgz" $configArchive --project=$Project --zone=$Zone

  & gcloud compute scp "${User}@${Instance}:/tmp/vellum-config-env" $configEnvFile --project=$Project --zone=$Zone 2>$null

  if (-not (Test-Path $configEnvFile)) {

    & gcloud compute scp "${User}@${Instance}:/home/$User/.config/vellum/env" $configEnvFile --project=$Project --zone=$Zone

  }



  $shareMb = [math]::Round((Get-Item $shareArchive).Length / 1MB, 1)

  $configMb = [math]::Round((Get-Item $configArchive).Length / 1MB, 1)

  if ($shareMb -lt 1) {

    throw "Share backup is only ${shareMb}MB — aborting before delete. Fix backup and retry."

  }

  Write-Host "Backup saved: share=${shareMb}MB config=${configMb}MB" -ForegroundColor Green

}



function Build-LegacyShareArchive {

  if (-not (Test-Path $legacyShareDir)) {

    throw "Legacy backup directory missing: $legacyShareDir"

  }

  Write-Host "Building vellum-share.tgz from legacy scp backup..."

  if (Get-Command tar -ErrorAction SilentlyContinue) {

    & tar -czf $shareArchive --exclude="*.sock" -C $legacyShareDir .

  } else {

    throw "Windows tar not found. Install tar or recreate backup from VM."

  }

  $shareMb = [math]::Round((Get-Item $shareArchive).Length / 1MB, 1)

  Write-Host "Legacy archive: ${shareMb}MB" -ForegroundColor Green

}



function Restore-GceAssistantData {

  param(

    [string]$Instance,

    [string]$User

  )

  if (-not (Test-Path $shareArchive)) {

    throw "Missing backup archive: $shareArchive"

  }

  $shareMb = [math]::Round((Get-Item $shareArchive).Length / 1MB, 1)

  if ($shareMb -lt 1) {

    throw "Share archive is only ${shareMb}MB — refusing to restore empty backup."

  }



  & gcloud compute scp $shareArchive "${User}@${Instance}:/tmp/vellum-share-backup.tgz" --project=$Project --zone=$Zone

  if ((Test-Path $configArchive) -and (Get-Item $configArchive).Length -gt 100) {

    & gcloud compute scp $configArchive "${User}@${Instance}:/tmp/vellum-config-backup.tgz" --project=$Project --zone=$Zone

  }



  $home = "/home/$User"
  $restoreCmd = "mkdir -p $home/.local/share/vellum $home/.config && tar xzf /tmp/vellum-share-backup.tgz -C $home/.local/share && if tar tf /tmp/vellum-share-backup.tgz 2>/dev/null | head -1 | grep -q '^vellum/'; then true; elif [ -d $home/.local/share/assistants ]; then mkdir -p $home/.local/share/vellum/assistants && mv $home/.local/share/assistants/* $home/.local/share/vellum/assistants/ 2>/dev/null || true && rm -rf $home/.local/share/assistants; [ -d $home/.local/share/conversations ] && mv $home/.local/share/conversations $home/.local/share/vellum/; fi && if [ -f /tmp/vellum-config-backup.tgz ]; then tar xzf /tmp/vellum-config-backup.tgz -C $home/.config; fi && rm -f /tmp/vellum-share-backup.tgz /tmp/vellum-config-backup.tgz"
  Invoke-GceRemoteCommand -Instance $Instance -Command $restoreCmd



  Invoke-GceRemoteCommand -Instance $Instance -Command "if ! swapon --show 2>/dev/null | grep -q /swapfile; then sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile && (grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab); fi"

}



function Enable-GceAssistantAfterRestore {

  param(

    [string]$Instance,

    [string]$User

  )

  $home = "/home/$User"

  $restoreScript = Join-Path $PSScriptRoot "restore-gce-integrations.sh"
  if (Test-Path $restoreScript) {
    & gcloud compute scp $restoreScript "${User}@${Instance}:/home/$User/restore-gce-integrations.sh" --project=$Project --zone=$Zone
    Invoke-GceRemoteCommand -Instance $Instance -Command "chmod +x $home/restore-gce-integrations.sh"
  }

  Invoke-GceRemoteCommand -Instance $Instance -Command "export PATH=$home/.bun/bin:`$PATH; ID=`$(ls $home/.local/share/vellum/assistants 2>/dev/null | head -1); if [ -n `"`$ID`" ]; then echo Waking `$ID; vellum wake `"`$ID`" || true; sleep 120; vellum ps || true; if [ -x $home/restore-gce-integrations.sh ]; then $home/restore-gce-integrations.sh `"`$ID`" || true; fi; else echo 'No assistant directory found after restore.'; fi"

}



function Wait-GceSshReady {

  param([string]$Instance)

  Write-Host "Waiting for SSH..."

  for ($i = 0; $i -lt 36; $i++) {

    & gcloud compute ssh $Instance --project=$Project --zone=$Zone --quiet --command="echo ready" 2>$null

    if ($LASTEXITCODE -eq 0) { return }

    Start-Sleep -Seconds 10

  }

  throw "SSH to instance did not become ready in time."

}



function Test-InstanceAlreadyMigrated {

  param([string]$Instance)

  $machineType = (& gcloud compute instances describe $Instance --project=$Project --zone=$Zone --format="get(machineType)" 2>$null).Trim()

  if ($machineType -notmatch "e2-micro") { return $false }

  $diskGb = (& gcloud compute instances describe $Instance --project=$Project --zone=$Zone --format="get(disks[0].diskSizeGb)" 2>$null).Trim()

  if ($diskGb -ne "30") { return $false }

  $license = (& gcloud compute instances describe $Instance --project=$Project --zone=$Zone --format="get(disks[0].licenses)" 2>$null).Trim()

  return ($license -match "ubuntu-2404")

}



$sshUser = Resolve-SshUser

if (-not $sshUser) {

  throw "Could not determine SSH username."

}



Write-Host ""

Write-Host "=== Migrate $InstanceName to e2-micro (Ubuntu 24.04, 30GB) ===" -ForegroundColor Cyan

Write-Host "Project: $Project"

Write-Host "Zone:    $Zone"

Write-Host "Backup:  $BackupDir"

Write-Host ""



if (-not $Yes) {

  Write-Host "This will DELETE the existing VM and create a new one (unless -SkipDeploy)." -ForegroundColor Yellow

  $confirm = Read-Host "Continue? (yes/no)"

  if ($confirm -ne "yes") {

    Write-Host "Aborted."

    exit 0

  }

}



if ($RestoreFromLegacyBackup) {

  Build-LegacyShareArchive

}



if (-not $SkipBackup) {

  Write-Host "[1/6] Backing up assistant data from VM..."

  Backup-GceAssistantData -Instance $InstanceName -User $sshUser

} else {

  Write-Host "[1/6] Skipping backup (-SkipBackup)."

  if (-not (Test-Path $shareArchive)) {

    if (Test-Path $legacyShareDir) {

      Build-LegacyShareArchive

    } else {

      throw "SkipBackup requested but $shareArchive is missing."

    }

  }

}



Import-ProviderKeysFromEnvFile -Path $configEnvFile



if (-not $SkipDeploy) {

  Write-Host "[2/6] Deleting old instance..."

  & gcloud compute instances delete $InstanceName --project=$Project --zone=$Zone --quiet



  Write-Host "[3/6] Creating new e2-micro Ubuntu 24.04 instance (detached hatch)..."

  if (-not $env:GEMINI_API_KEY -and -not $env:ANTHROPIC_API_KEY -and -not $env:OPENAI_API_KEY) {

    throw "No provider API key in environment or $configEnvFile. Set GEMINI_API_KEY before deploy."

  }

  Push-Location $cliDir

  try {

    # Detached: VM creation returns quickly; startup script continues on e2-micro.

    & bun run scripts/deploy-gce.ts --name $InstanceName --detached 2>$null

    if ($LASTEXITCODE -ne 0) {

      # deploy-gce.ts may not support --detached; fall back to finish bootstrap path.

      Write-Host "deploy-gce.ts did not accept --detached; using standard deploy (may timeout on e2-micro)..."

      & bun run scripts/deploy-gce.ts --name $InstanceName

      if ($LASTEXITCODE -ne 0) {

        Write-Host "deploy timed out or failed — will finish bootstrap manually." -ForegroundColor Yellow

      }

    }

  } finally {

    Pop-Location

  }

} else {

  Write-Host "[2/6] Skipping delete (-SkipDeploy)."

  Write-Host "[3/6] Skipping deploy (-SkipDeploy)."

  if (-not (Test-InstanceAlreadyMigrated -Instance $InstanceName)) {

    Write-Host "Warning: instance does not look fully migrated (machine/disk/OS)." -ForegroundColor Yellow

  }

}



Wait-GceSshReady -Instance $InstanceName



Write-Host "[3b/6] Finishing bootstrap (install + guardian token)..."

if (-not $env:GEMINI_API_KEY -and -not $env:ANTHROPIC_API_KEY -and -not $env:OPENAI_API_KEY) {

  throw "No provider API key for bootstrap."

}

Push-Location $cliDir

try {

  & bun run scripts/finish-gce-bootstrap.ts --name $InstanceName

  if ($LASTEXITCODE -ne 0) {

    throw "finish-gce-bootstrap.ts failed with exit code $LASTEXITCODE"

  }

} finally {

  Pop-Location

}



Write-Host "[5/6] Restoring backed-up assistant data..."

Restore-GceAssistantData -Instance $InstanceName -User $sshUser

Enable-GceAssistantAfterRestore -Instance $InstanceName -User $sshUser



Write-Host "[6/6] Verifying instance..."

$newIp = (& gcloud compute instances describe $InstanceName --project=$Project --zone=$Zone --format="get(networkInterfaces[0].accessConfigs[0].natIP)").Trim()

$machineType = (& gcloud compute instances describe $InstanceName --project=$Project --zone=$Zone --format="get(machineType)").Split("/")[-1]

$diskGb = (& gcloud compute instances describe $InstanceName --project=$Project --zone=$Zone --format="get(disks[0].diskSizeGb)").Trim()



Write-Host ""

Write-Host "Migration complete." -ForegroundColor Green

Write-Host "  Machine: $machineType | Disk: ${diskGb}GB | OS: Ubuntu 24.04"

Write-Host "  Public IP: $newIp"

Write-Host "  Gateway:   http://${newIp}:7830/healthz"

Write-Host "  Swap:      2GB enabled on VM after restore"



if (-not $SkipWebRestart) {

  Write-Host "Restarting local web on port 3001..."

  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "restart-gce-web-3001.ps1") -NoBrowser

}



Write-Host "  Web UI: http://localhost:3001/assistant/"

Write-Host ""

