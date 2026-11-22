# Rancher Desktop loves Docker for Windows

Rancher Desktop runs Linux containers (choose the **dockerd (moby)** engine to get the regular
`docker` CLI), but it can't run Windows containers. This project adds the open-source Docker engine
for **Windows containers** next to it, so you get both without Docker Desktop:

| Engine | Runs | Named pipe | CLI context |
|---|---|---|---|
| Rancher Desktop (moby) | Linux containers in WSL 2 | `\\.\pipe\docker_engine` | `default` |
| This module (`dockerd.exe`) | Windows containers, native | `\\.\pipe\docker_windows` | `docker-win` |

Both are driven by the same `docker` CLI (the one Rancher Desktop puts on your `PATH`). Switch
with `docker context use docker-win` / `docker context use default`, or per command with
`docker --context docker-win ...`.

Everything here is open source: Rancher Desktop (Apache-2.0) and the Moby engine/CLI/Compose
static binaries (Apache-2.0) from `download.docker.com`.

## Requirements

- Windows 11 or Windows 10 (Pro/Enterprise/Education for Windows containers), or Windows Server 2022+
- Windows PowerShell 5.1 or PowerShell 7+, run **as administrator** for install/remove
- Hyper-V is only needed if you use `--isolation=hyperv`. On Windows 11 / Server 2022+ hosts,
  `ltsc2022` images run with process isolation and don't need it. Windows 10 hosts need Hyper-V
  isolation for `ltsc2022` images.

## Setup

### 1. Import the module

In an **elevated** PowerShell:

```powershell
Import-Module .\Install-DockerdWin.psm1
```

### 2. Enable the Windows features

```powershell
Install-DockerPrerequisites            # Containers feature only
# Install-DockerPrerequisites -HyperV  # also Hyper-V, for --isolation=hyperv
```

Restart, then make sure WSL is current: `wsl --update` (elevated). If `wsl` isn't installed yet,
`wsl --install` sets it up.

### 3. Install Rancher Desktop

1. Download and install [Rancher Desktop](https://rancherdesktop.io/). (This is SUSE's desktop app,
   not the Rancher Kubernetes management server.)
1. In **Preferences → Container Engine**, select **dockerd (moby)**.
1. Disable Kubernetes under **Preferences → Kubernetes** if you don't need it.
1. Check `docker version` in a new terminal.

### 4. Install the Windows container engine

Re-import the module in an elevated PowerShell, then:

```powershell
Install-DockerDaemon
```

This:

- downloads the latest stable static engine from `download.docker.com` and verifies its SHA256,
- installs it to `C:\Program Files\DockerWindowsEngine` (deliberately **not** on `PATH`, so it
  never shadows Rancher Desktop's `docker.exe`),
- writes/merges `C:\ProgramData\docker\config\daemon.json` to listen on `\\.\pipe\docker_windows`,
- registers and starts the `docker` Windows service,
- creates a local `docker-users` group (and adds you) so you can use the engine without elevation.
  **Sign out and back in once** for the group membership to apply,
- creates the `docker-win` CLI context.

Useful options:

```powershell
Install-DockerDaemon -Version 29.10.0           # pin a version (default: latest)
Install-DockerDaemon -DefaultIsolation process  # default isolation (Docker's default is hyperv on client Windows)
Install-DockerDaemon -ContainerDiskSize 60GB    # container scratch disk (default 20GB)
Install-DockerDaemon -UseContext                # make docker-win your default context
Install-DockerDaemon -InstallCli                # also install docker.exe (only if you don't have Rancher Desktop)
```

Try it:

```powershell
docker --context docker-win run --rm --isolation=process mcr.microsoft.com/windows/nanoserver:ltsc2022 cmd /c ver
```

### 5. Docker Compose

Rancher Desktop already ships `docker compose` (and `buildx`) for both Windows and its WSL
distro, and it works against either context. You only need these if you don't use Rancher
Desktop or want a newer Compose than it bundles:

```powershell
Install-DockerComposeWin                 # latest, verified, into %USERPROFILE%\.docker\cli-plugins
```

```sh
./docker-compose_WSL.sh                  # inside a WSL distro; latest, verified
```

A single `docker compose up` talks to one engine, so a project can't mix Linux and Windows
containers. Run each side with its own `--context`.

## Day-to-day

```powershell
Update-DockerDaemon          # upgrade to the latest engine, keeping config, images and containers
Stop-DockerBackend           # stop the Windows engine (leaves WSL / Rancher Desktop alone)
Start-DockerBackend
Uninstall-DockerDaemon       # remove service, context and binaries; keeps images/containers
Uninstall-DockerDaemon -RemoveData   # ...and deletes C:\ProgramData\docker
```

The old function names (`Install-DockerDeamon`, `Remove-DockerDeamon`,
`Install-DockerPrerequirements`, `Uninstall-DockerPrerequirements`) still work as aliases.

## Changes from the 2022 version

- **Latest versions by default.** The engine and Compose versions are looked up at install
  time instead of being pinned to Docker 20.10.13 / Compose 2.3.3. Downloads are checked against
  their published SHA256.
- **Named pipe instead of unauthenticated TCP.** The engine used to listen on `tcp://localhost:2375`
  with no TLS, which gives every local process root-equivalent access. It now uses its own pipe,
  restricted to Administrators and the `docker-users` group. The self-signed certificate code
  is gone: TLS isn't needed for a pipe, and its "TLS mode" passed the *client* certificate as the
  server certificate, so it never worked.
- **Machine-wide install location.** Binaries used to go to the admin's `%LOCALAPPDATA%` (while
  running as a system service) and were prepended to the machine `PATH`, where `docker.exe`
  overrode Rancher Desktop's CLI. They now live in `Program Files`, off `PATH`.
- **Rancher Desktop stays up.** `Stop-DockerBackend` used to stop `vmcompute`/`vmms`, which also
  stops WSL 2 and therefore Rancher Desktop. It now stops only the engine.
- **Hyper-V is optional**, since process isolation doesn't need it (and Windows Home doesn't have it).
- **Fixed Compose paths.** The plugin was written to `$HOMEPATH` (no drive letter, so relative to
  the current drive); it now goes to `%USERPROFILE%\.docker\cli-plugins`. The WSL script no longer
  uses `curl -k`, which disabled certificate checks.
- Works in PowerShell 7 as well as Windows PowerShell 5.1.

## Troubleshooting

### `docker --context docker-win ...` says access denied

You aren't in `docker-users` yet, or haven't signed out and back in since being added. Elevated
shells always have access.

### Image/host version mismatch

`The container operating system does not match the host operating system`: use an image whose
build matches your host (e.g. `ltsc2025` on Windows 11 24H2 / Server 2025), or add
`--isolation=hyperv` (requires the Hyper-V feature).

### "There is not enough space on the disk" while building

Raise the scratch-disk size: `Install-DockerDaemon -ContainerDiskSize 100GB` (merges into
`daemon.json`), or edit `storage-opts` there and restart the `docker` service.

### `DOCKER_HOST` overrides the context

If `docker` warns that `DOCKER_HOST` overrides the context, clear it:
`$env:DOCKER_HOST = $null` (and remove it from your user/system environment variables).

### Troubleshoot WSL DNS

Older WSL versions sometimes don't set up DNS correctly. Check with `traceroute 1.1.1.1` (works)
and `traceroute github.com` (`bad address` means DNS is broken). Current WSL handles this
better, so try `wsl --update` first, or enable DNS tunneling by putting this in `%USERPROFILE%\.wslconfig`:

```ini
[wsl2]
dnsTunneling=true
```

then `wsl --shutdown`. As a last resort, add a `nameserver <your gateway IP>` line to
`/etc/resolv.conf` in the distro.

### Troubleshoot Kubernetes config issues

If you already use Kubernetes contexts in your WSL distro:

1. Back up `~/.kube/config` in WSL and any existing `/mnt/c/Users/<you>/.kube/config`.
1. Copy your WSL config to Windows: `cp ~/.kube/config /mnt/c/Users/<you>/.kube/`
1. In Rancher Desktop, **Troubleshooting → Reset Kubernetes**. This adds the `rancher-desktop`
   context to `C:\Users\<you>\.kube\config`.
1. Symlink it back into WSL: `ln -sf /mnt/c/Users/<you>/.kube/config ~/.kube/config`
