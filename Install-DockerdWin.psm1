<#
 .Synopsis
  Install and manage a native Docker daemon (Moby) for Windows containers next to Rancher Desktop.

 .Description
  Installs the open-source static dockerd.exe from download.docker.com as a Windows service that
  listens on its own named pipe (\\.\pipe\docker_windows by default), so it never clashes with
  Rancher Desktop's Linux engine on \\.\pipe\docker_engine. A docker CLI context ("docker-win")
  points at it, so you switch engines with `docker context use` or `docker --context docker-win`.

  Works in Windows PowerShell 5.1 and PowerShell 7+. Install/remove commands need an elevated shell.

 .Example
   Import-Module .\Install-DockerdWin.psm1
   Install-DockerPrerequisites          # enables the Containers feature; reboot afterwards
   Install-DockerDaemon                 # latest stable engine, pipe + context "docker-win"
   docker --context docker-win run --rm --isolation=process mcr.microsoft.com/windows/nanoserver:ltsc2022 cmd /c ver
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:StaticBaseUrl   = "https://download.docker.com/win/static/stable/x86_64"
$script:ConfigDir       = Join-Path $env:ProgramData "docker\config"
$script:ConfigFile      = Join-Path $script:ConfigDir "daemon.json"
$script:DefaultInstall  = Join-Path $env:ProgramFiles "DockerWindowsEngine"

# ---------------------------------------------------------------- helpers

function Assert-Elevated {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Administrator privileges required. Please run PowerShell elevated."
    }
}

function Enable-Tls12 {
    # Windows PowerShell 5.1 may default to TLS 1.0/1.1
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

function Get-RemoteFile {
    param([Parameter(Mandatory)][string] $Uri, [Parameter(Mandatory)][string] $OutFile)
    Enable-Tls12
    $old = $ProgressPreference
    $ProgressPreference = "SilentlyContinue"   # progress bar makes iwr ~10x slower in 5.1
    try { Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $OutFile }
    finally { $ProgressPreference = $old }
}

function Assert-Sha256 {
    param([Parameter(Mandatory)][string] $File, [Parameter(Mandatory)][string] $ShaUri, [switch] $AllowMissing)
    $shaFile = "$File.sha256"
    try { Get-RemoteFile -Uri $ShaUri -OutFile $shaFile }
    catch {
        if ($AllowMissing) { Write-Warning "No published checksum at $ShaUri; skipping verification."; return }
        throw
    }
    $expected = ((Get-Content $shaFile -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
    $actual = (Get-FileHash -Algorithm SHA256 $File).Hash.ToLowerInvariant()
    Remove-Item $shaFile -Force
    if ($expected -ne $actual) {
        throw "SHA256 mismatch for $(Split-Path $File -Leaf): expected $expected, got $actual"
    }
}

function Find-DockerCli {
    param([string] $InstallDir = $script:DefaultInstall)
    $cmd = Get-Command docker -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $local = Join-Path $InstallDir "docker.exe"
    if (Test-Path $local) { return $local }
    return $null
}

function Get-DockerStaticVersion {
    <#
     .Synopsis
      Returns the newest stable Docker version published as Windows static binaries.
    #>
    Enable-Tls12
    $html = (Invoke-WebRequest -UseBasicParsing -Uri "$script:StaticBaseUrl/").Content
    $versions = [regex]::Matches($html, 'docker-(?:engine_)?(\d+\.\d+\.\d+)\.zip') |
        ForEach-Object { [version] $_.Groups[1].Value } |
        Sort-Object -Unique -Descending
    if (-not $versions) { throw "Could not find any Docker versions at $script:StaticBaseUrl/" }
    return $versions[0].ToString()
}
Export-ModuleMember -Function Get-DockerStaticVersion

# ---------------------------------------------------------------- prerequisites

function Install-DockerPrerequisites {
    <#
     .Synopsis
      Enables the Windows "Containers" feature (and optionally Hyper-V). Reboot afterwards.
     .Parameter HyperV
      Also enable Hyper-V. Only needed for --isolation=hyperv (e.g. images older/newer than
      the host build, or Windows 10 hosts running ltsc2022 images). Process isolation on
      Windows 11 / Server 2022+ does not need it. Not available on Windows Home.
    #>
    param([switch] $HyperV)
    Assert-Elevated

    $restart = $false
    $features = @("Containers")
    if ($HyperV) { $features += "Microsoft-Hyper-V" }
    foreach ($f in $features) {
        $state = (Get-WindowsOptionalFeature -Online -FeatureName $f).State
        if ($state -ne "Enabled") {
            $r = Enable-WindowsOptionalFeature -Online -FeatureName $f -All -NoRestart
            if ($r.RestartNeeded) { $restart = $true }
        }
    }

    Write-Host "Make sure WSL is current for Rancher Desktop: run 'wsl --update' (elevated)."
    if ($restart) { Write-Warning "A restart is required before installing the daemon." }
}
Export-ModuleMember -Function Install-DockerPrerequisites

function Uninstall-DockerPrerequisites {
    param([switch] $HyperV)
    Assert-Elevated
    Disable-WindowsOptionalFeature -Online -FeatureName "Containers" -NoRestart | Out-Null
    if ($HyperV) { Disable-WindowsOptionalFeature -Online -FeatureName "Microsoft-Hyper-V" -NoRestart | Out-Null }
    Write-Warning "Restart to finish removing the features."
}
Export-ModuleMember -Function Uninstall-DockerPrerequisites

# ---------------------------------------------------------------- daemon

function Install-DockerDaemon {
    <#
     .Synopsis
      Downloads the static Docker engine for Windows, registers it as a service on its own
      named pipe, and creates a docker CLI context for it.
     .Parameter Version
      Docker version (e.g. 29.10.0) or "latest" (default).
     .Parameter PipeName
      Named pipe to listen on. Must differ from Rancher Desktop's "docker_engine".
     .Parameter AccessGroup
      Local group whose members may use the pipe without elevation. Created if missing and the
      current user is added (sign out/in afterwards for it to take effect).
     .Parameter DefaultIsolation
      "process" or "hyperv" sets the daemon default; omit to keep Docker's default
      (hyperv on Windows client, process on Windows Server).
     .Parameter ContainerDiskSize
      Default container scratch-disk size, e.g. "60GB" (Docker's default is 20GB).
     .Parameter InstallCli
      Also install the matching docker.exe CLI. Not needed when Rancher Desktop is installed,
      because its CLI is already on PATH; this copy is NOT added to PATH to avoid shadowing it.
     .Parameter UseContext
      Switch the current user's default context to the Windows engine afterwards.
    #>
    param(
        [string] $Version = "latest",
        [string] $InstallDir = $script:DefaultInstall,
        [string] $ServiceName = "docker",
        [string] $PipeName = "docker_windows",
        [string] $ContextName = "docker-win",
        [string] $AccessGroup = "docker-users",
        [ValidateSet("process", "hyperv")] [string] $DefaultIsolation,
        [string] $ContainerDiskSize,
        [switch] $InstallCli,
        [switch] $UseContext
    )
    Assert-Elevated

    if ($PipeName -eq "docker_engine") {
        throw "Pipe 'docker_engine' is used by Rancher Desktop; choose another -PipeName."
    }
    if ((Get-WindowsOptionalFeature -Online -FeatureName "Containers").State -ne "Enabled") {
        throw "The Windows 'Containers' feature is not enabled. Run Install-DockerPrerequisites and restart."
    }

    if ($Version -eq "latest") { $Version = Get-DockerStaticVersion }
    Write-Host "Installing Docker engine $Version for Windows containers..."

    if (Get-Service $ServiceName -ErrorAction SilentlyContinue) {
        Write-Host "Existing '$ServiceName' service found, replacing it."
        Uninstall-DockerDaemon -ServiceName $ServiceName -ContextName $ContextName -InstallDir $InstallDir -KeepFiles
    }

    $work = Join-Path $env:TEMP "docker-win-install-$Version"
    New-Item $work -ItemType Directory -Force | Out-Null
    try {
        # Newer releases ship engine and CLI as separate zips; older ones only as docker-X.zip.
        $engineZip = Join-Path $work "engine.zip"
        $engineName = "docker-engine_$Version.zip"
        try {
            Get-RemoteFile -Uri "$script:StaticBaseUrl/$engineName" -OutFile $engineZip
        }
        catch {
            $engineName = "docker-$Version.zip"
            Get-RemoteFile -Uri "$script:StaticBaseUrl/$engineName" -OutFile $engineZip
        }
        # older docker-X.zip releases have no .sha256 next to them
        Assert-Sha256 -File $engineZip -ShaUri "$script:StaticBaseUrl/$engineName.sha256" -AllowMissing

        $extract = Join-Path $work "extract"
        Expand-Archive $engineZip -DestinationPath $extract -Force

        if ($InstallCli -and $engineName -like "docker-engine_*") {
            $cliZip = Join-Path $work "cli.zip"
            Get-RemoteFile -Uri "$script:StaticBaseUrl/docker-cli_$Version.zip" -OutFile $cliZip
            Assert-Sha256 -File $cliZip -ShaUri "$script:StaticBaseUrl/docker-cli_$Version.zip.sha256"
            Expand-Archive $cliZip -DestinationPath $extract -Force
        }

        New-Item $InstallDir -ItemType Directory -Force | Out-Null
        $dockerd = Get-ChildItem $extract -Recurse -Filter dockerd.exe | Select-Object -First 1
        if (-not $dockerd) { throw "dockerd.exe not found in $engineName" }
        Copy-Item (Join-Path $dockerd.DirectoryName "*") $InstallDir -Recurse -Force
        if ($InstallCli) {
            Get-ChildItem $extract -Recurse -Filter docker.exe |
                Select-Object -First 1 | ForEach-Object { Copy-Item $_.FullName $InstallDir -Force }
        }
    }
    finally {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Pipe access for non-admin users
    if ($AccessGroup) {
        if (-not (Get-LocalGroup -Name $AccessGroup -ErrorAction SilentlyContinue)) {
            New-LocalGroup -Name $AccessGroup -Description "Users allowed to use the Windows Docker engine" | Out-Null
        }
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        if (-not (Get-LocalGroupMember -Group $AccessGroup -ErrorAction SilentlyContinue | Where-Object Name -eq $me)) {
            Add-LocalGroupMember -Group $AccessGroup -Member $me
            Write-Warning "Added $me to '$AccessGroup'. Sign out and back in to use the engine without elevation."
        }
    }

    # daemon.json: merge into any existing config rather than clobbering it
    New-Item $script:ConfigDir -ItemType Directory -Force | Out-Null
    $config = @{}
    if (Test-Path $script:ConfigFile) {
        $existing = Get-Content $script:ConfigFile -Raw | ConvertFrom-Json
        foreach ($p in $existing.PSObject.Properties) { $config[$p.Name] = $p.Value }
    }
    $config["hosts"] = @("npipe:////./pipe/$PipeName")
    if ($AccessGroup) { $config["group"] = $AccessGroup }
    if ($DefaultIsolation) { $config["exec-opts"] = @("isolation=$DefaultIsolation") }
    if ($ContainerDiskSize) { $config["storage-opts"] = @("size=$ContainerDiskSize") }
    # BOM-less UTF-8: dockerd rejects a BOM, which Set-Content -Encoding UTF8 writes in 5.1
    [IO.File]::WriteAllText($script:ConfigFile, ($config | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))

    $dockerdExe = Join-Path $InstallDir "dockerd.exe"
    & $dockerdExe --register-service --service-name $ServiceName --config-file $script:ConfigFile
    if ($LASTEXITCODE) { throw "dockerd --register-service failed ($LASTEXITCODE)" }
    Start-Service $ServiceName

    # CLI context (per user)
    $cli = Find-DockerCli -InstallDir $InstallDir
    if (-not $cli) {
        Write-Warning "No docker CLI found. Install Rancher Desktop or re-run with -InstallCli, then run: docker context create $ContextName --docker `"host=npipe:////./pipe/$PipeName`""
        return
    }
    & $cli context inspect $ContextName *> $null
    if ($LASTEXITCODE -eq 0) {
        & $cli context update $ContextName --docker "host=npipe:////./pipe/$PipeName" | Out-Null
    }
    else {
        & $cli context create $ContextName --description "Windows containers (native dockerd)" --docker "host=npipe:////./pipe/$PipeName" | Out-Null
    }
    if ($UseContext) { & $cli context use $ContextName | Out-Null }

    & $cli --context $ContextName version
    Write-Host "Done. Use 'docker --context $ContextName ...' or 'docker context use $ContextName'."
}
Export-ModuleMember -Function Install-DockerDaemon

function Update-DockerDaemon {
    <#
     .Synopsis
      Re-installs the engine at the given (default: latest) version, keeping daemon.json and data.
    #>
    param([string] $Version = "latest", [string] $InstallDir = $script:DefaultInstall, [string] $ServiceName = "docker")
    Assert-Elevated
    if ($Version -eq "latest") { $Version = Get-DockerStaticVersion }
    $current = $null
    $exe = Join-Path $InstallDir "dockerd.exe"
    if (Test-Path $exe) { $current = (& $exe --version) -replace '^Docker version ([^,]+),.*$', '$1' }
    if ($current -eq $Version) { Write-Host "Already at $Version."; return }
    Write-Host "Updating $current -> $Version"
    $cfg = if (Test-Path $script:ConfigFile) { Get-Content $script:ConfigFile -Raw | ConvertFrom-Json } else { $null }
    $pipe = "docker_windows"
    $group = "docker-users"
    if ($cfg -and ($cfg.PSObject.Properties.Name -contains "hosts")) { $pipe = ($cfg.hosts | Select-Object -First 1) -replace '^npipe:////\./pipe/', '' }
    if ($cfg -and ($cfg.PSObject.Properties.Name -contains "group")) { $group = $cfg.group }
    $withCli = Test-Path (Join-Path $InstallDir "docker.exe")
    Install-DockerDaemon -Version $Version -InstallDir $InstallDir -ServiceName $ServiceName -PipeName $pipe -AccessGroup $group -InstallCli:$withCli
}
Export-ModuleMember -Function Update-DockerDaemon

function Uninstall-DockerDaemon {
    <#
     .Synopsis
      Stops and unregisters the service and removes the CLI context. Images/containers in
      C:\ProgramData\docker are kept unless -RemoveData is given.
    #>
    param(
        [string] $ServiceName = "docker",
        [string] $ContextName = "docker-win",
        [string] $InstallDir = $script:DefaultInstall,
        [switch] $KeepFiles,
        [switch] $RemoveData
    )
    Assert-Elevated

    if (Get-Service $ServiceName -ErrorAction SilentlyContinue) {
        Stop-Service $ServiceName -ErrorAction SilentlyContinue
        $exe = Join-Path $InstallDir "dockerd.exe"
        if (Test-Path $exe) {
            & $exe --unregister-service --service-name $ServiceName
        }
        else {
            sc.exe delete $ServiceName | Out-Null
        }
    }

    $cli = Find-DockerCli -InstallDir $InstallDir
    if ($cli) {
        $currentCtx = (& $cli context show 2>$null)
        if ($currentCtx -eq $ContextName) { & $cli context use default | Out-Null }
        & $cli context rm $ContextName --force *> $null
    }

    if (-not $KeepFiles) { Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue }
    if ($RemoveData) {
        # Windows container layers have ACLs that block plain deletes; this is the documented-safe path
        Write-Warning "Removing $env:ProgramData\docker (images, containers, volumes, daemon.json)."
        Remove-Item (Join-Path $env:ProgramData "docker") -Recurse -Force
    }
}
Export-ModuleMember -Function Uninstall-DockerDaemon

function Start-DockerBackend {
    param([string] $ServiceName = "docker")
    Start-Service $ServiceName
}
Export-ModuleMember -Function Start-DockerBackend

function Stop-DockerBackend {
    # Only the engine: stopping vmcompute/vmms would also take down WSL 2 and Rancher Desktop.
    param([string] $ServiceName = "docker")
    Stop-Service $ServiceName
}
Export-ModuleMember -Function Stop-DockerBackend

# ---------------------------------------------------------------- compose

function Install-DockerComposeWin {
    <#
     .Synopsis
      Installs the docker compose CLI plugin for the current user.
     .Description
      Rancher Desktop already ships docker compose (and buildx); only use this without
      Rancher Desktop, or to get a newer compose than it bundles.
    #>
    param([string] $Version = "latest")
    Enable-Tls12
    if ($Version -eq "latest") {
        $Version = (Invoke-RestMethod -UseBasicParsing -Uri "https://api.github.com/repos/docker/compose/releases/latest").tag_name
    }
    if ($Version -notlike "v*") { $Version = "v$Version" }

    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "aarch64" } else { "x86_64" }
    $asset = "docker-compose-windows-$arch.exe"
    $base = "https://github.com/docker/compose/releases/download/$Version"
    $pluginDir = Join-Path $env:USERPROFILE ".docker\cli-plugins"
    New-Item $pluginDir -ItemType Directory -Force | Out-Null
    $target = Join-Path $pluginDir "docker-compose.exe"

    Get-RemoteFile -Uri "$base/$asset" -OutFile "$target.download"
    Assert-Sha256 -File "$target.download" -ShaUri "$base/$asset.sha256"
    Move-Item "$target.download" $target -Force
    Write-Host "Installed docker compose $Version to $target"
}
Export-ModuleMember -Function Install-DockerComposeWin

# ---------------------------------------------------------------- backward-compatible names

Set-Alias -Name Install-DockerDeamon -Value Install-DockerDaemon
Set-Alias -Name Remove-DockerDeamon -Value Uninstall-DockerDaemon
Set-Alias -Name Install-DockerPrerequirements -Value Install-DockerPrerequisites
Set-Alias -Name Uninstall-DockerPrerequirements -Value Uninstall-DockerPrerequisites
Export-ModuleMember -Alias Install-DockerDeamon, Remove-DockerDeamon, Install-DockerPrerequirements, Uninstall-DockerPrerequirements
