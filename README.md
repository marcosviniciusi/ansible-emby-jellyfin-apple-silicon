# ansible-mac-emby-jelly

Infrastructure as Code + operations automation for the **Emby + Jellyfin** media
stack running bare-metal on a Mac Mini (Apple Silicon) with media stored on a
remote NFS server.

> **What this repo covers:**
> - ✅ Bootstrap — install from scratch on a clean macOS host
> - ✅ Updates — pull the latest release, atomic binary swap, health check
> - ✅ Backups — SQLite + config snapshots, pushed off-machine to NFS

---

## Architecture

```
                           ┌─────────────────────────────────────────┐
                           │  Mac Mini (Apple Silicon)               │
                           │                                         │
                           │  /opt/jellyfin/jellyfin    :8097        │
                           │  /Applications/EmbyServer.app  :8096    │
                           │  ────────────────────────────────       │
                           │  /var/lib/jellyfin  (local SSD)         │
                           │  /var/lib/emby      (local SSD)         │
                           │                                         │
                           │  /data -> System/Volumes/Data/data      │
                           │  /data/videos     (autofs NFSv4 RO)     │
                           │  /data/nfs-midia  (autofs NFSv4 RW)     │
                           └──────────────┬──────────────────────────┘
                                          │ TCP 2049 (NFSv4)
                                          │ TCP keepalive every 2 min
                                          │ pf state timeout 5 days
                                          ▼
                           ┌─────────────────────────────────────────┐
                           │  NFS server (Linux)                     │
                           │                                         │
                           │  /export/videos                         │
                           │     ├ movies/                           │
                           │     ├ series/                           │
                           │     └ ...                               │
                           │                                         │
                           │  /export/nfs-midia                      │
                           │     ├ jellyfin/{cache,metadata,trickplay}│
                           │     └ emby/{cache,metadata}             │
                           │                                         │
                           │  /export/dmz3-backup    (off-machine)   │
                           │     └ db/*.tar.gz                       │
                           └─────────────────────────────────────────┘
```

### Where each kind of data lives

| Data | Path on Mac | Underlying storage |
|---|---|---|
| Media files (read-only) | `/data/videos/*` | NFS `<server>:/videos` |
| Jellyfin SQLite DB | `/var/lib/jellyfin/data/data/jellyfin.db` | **Local SSD** |
| Emby SQLite DB | `/var/lib/emby/data/library.db` | **Local SSD** |
| Jellyfin XML configs | `/var/lib/jellyfin/*.xml` | **Local SSD** |
| Emby XML configs + plugins | `/var/lib/emby/{config,plugins}` | **Local SSD** |
| Jellyfin metadata | `/data/nfs-midia/jellyfin/metadata` | NFS |
| Emby metadata | `/var/lib/emby/metadata` → symlink → `/data/nfs-midia/emby/metadata` | NFS |
| Jellyfin cache (anidb, omdb, etc) | `/data/nfs-midia/jellyfin/cache` (via `--cachedir`) | NFS |
| Emby cache | `/var/lib/emby/cache` → symlink → `/data/nfs-midia/emby/cache` | NFS |
| Jellyfin trickplay thumbnails | `/data/nfs-midia/jellyfin/trickplay` | NFS |
| **Jellyfin transcoding** | `/var/lib/jellyfin/transcoding-temp` | **Local SSD** |
| **Emby transcoding** | `/var/lib/emby/transcoding-temp` | **Local SSD** |
| Local backups (latest) | `/var/backups/mac-media/db/*.tar.gz` | **Local SSD** |
| Off-machine backups | NFS `<server>:/dmz3-backup/db/*.tar.gz` | NFS off-machine |

### Why Homebrew ffmpeg (not jellyfin-ffmpeg)

| App | ffmpeg used | Reason |
|---|---|---|
| **Jellyfin** | `/opt/homebrew/bin/ffmpeg` (Homebrew, v8.x) | Jellyfin's custom `jellyfin-ffmpeg` fork ships no macOS arm64 binaries — only Linux `.deb` packages. Homebrew's ffmpeg has VideoToolbox + AudioToolbox compiled in, which is what matters for hardware transcoding on Apple Silicon. |
| **Emby** | `embymediaserver-ffmpeg` (bundled inside the `.app`, v5.1-emby custom build) | Emby distributes its own ffmpeg fork inside the official macOS arm64 zip. |

Both support hardware H.264 / HEVC encode + decode via VideoToolbox on Apple
Silicon.

---

## Network topology (example homelab)

| Subnet | Used by |
|---|---|
| LAN (e.g. `192.168.250.0/24`) | Management — SSH/Ansible reaches the Mac over LAN |
| DMZ (e.g. `192.168.251.0/27`) | Mac on DMZ for external Jellyfin exposure + NFS traffic |
| NFS subnet (e.g. `192.168.253.0/24`) | NFS server |

### Firewall rule (OPNsense / pf example)

For NFS to survive long idle periods through a stateful firewall, add a
dedicated rule on the Mac's interface:

| Field | Value |
|---|---|
| Action | Pass |
| Protocol | TCP |
| Source | `<mac_ip>/32` |
| Destination | `<nfs_server_ip>/32` port `2049` |
| State type | **sloppy state** |
| **TCP established timeout** | **`432000`** (5 days, in seconds) |
| Gateway | **None** — do NOT force any WAN gateway |

⚠️ This rule must be placed **above** any "ALLOW INTERNET" rule that forces a
WAN gateway. Otherwise NFS packets get routed out the WAN.

---

## Repository layout

```
ansible-mac-emby-jelly/
├── ansible.cfg
├── inventory.yml
├── group_vars/macmini.yml          # environment-specific values (NFS server,
│                                   # tooling paths, identity)
├── Makefile                         # all interaction goes through `make`
│
├── preflight.yml                    # HOST READINESS: FileVault, sudo, NFS reachable
│
├── bootstrap.yml                    # FRESH INSTALL: preflight + base + jellyfin + emby
├── bootstrap-base.yml               #   system base only (incl. CLT + Homebrew)
├── bootstrap-jellyfin.yml           #   Jellyfin only
├── bootstrap-emby.yml               #   Emby only
│
├── update-all.yml                   # OPS: update both with DB backup
├── update-jellyfin.yml
├── update-emby.yml
├── backup-only.yml                  # OPS: backup without updating
├── stop-services.yml                # OPS: stop daemons + unmount NFS (maintenance)
├── start-services.yml               # OPS: mount NFS + start daemons (recovery)
│
└── roles/
    ├── mac_base/                    # system base
    │   ├── defaults/main.yml        #   ── documented defaults
    │   ├── handlers/main.yml
    │   ├── tasks/main.yml
    │   └── templates/
    │       ├── auto_nfs.j2
    │       ├── com.local.tcp-keepalive.plist.j2
    │       └── synthetic.conf.j2
    │
    ├── jellyfin_install/            # fresh install of Jellyfin
    │   ├── defaults/main.yml
    │   ├── tasks/main.yml
    │   └── templates/com.jellyfin.server.plist.j2
    │
    ├── emby_install/                # fresh install of Emby (incl. NFS symlinks)
    │   ├── defaults/main.yml
    │   ├── tasks/main.yml
    │   └── templates/com.embyserver.server.plist.j2
    │
    ├── jellyfin_update/             # version-checked update + DB backup
    │   ├── defaults/main.yml
    │   └── tasks/main.yml
    │
    ├── emby_update/                 # version-checked update + DB backup
    │   ├── defaults/main.yml
    │   └── tasks/main.yml
    │
    └── nfs_push/                    # off-machine NFS push (mount → cp → umount)
        ├── defaults/main.yml
        └── tasks/main.yml
```

### Make targets (quick reference)

Every interaction goes through `make <target>` — see `make help` for the
full list. Most-used:

| Target | What it does |
|---|---|
| `make ping` | Smoke test SSH + sudo |
| `make preflight` | Verify host readiness (FileVault, sudo, NFS reachable, power settings) |
| `make ssh-key` | One-time: copy controller's SSH pubkey to the Mac |
| `make bootstrap` | Full from-scratch install (auto-runs preflight first) |
| `make bootstrap-base` | System base only (user, autofs, Homebrew). **Requires reboot afterwards.** |
| `make bootstrap-jelly` / `bootstrap-emby` | One service only |
| `make check` | Dry-run update version check (no changes) |
| `make update-all` | Update both Jellyfin and Emby if newer is out (+ DB backup) |
| `make update-jellyfin` / `update-emby` | One service only |
| `make force-jellyfin` / `force-emby` | Reinstall even when on latest |
| `make backup` | DB+config snapshot, no binary swap |
| `make stop-services` | Stop daemons + unmount NFS (maintenance window) |
| `make start-services` | Mount NFS + start daemons (recovery from maintenance) |
| `make list-backups` / `list-db-backups` / `list-remote-backups` | List backups (local / DB tarballs / off-machine on NFS) |

### Variable layout

All values are split between two places:

1. **`roles/<role>/defaults/main.yml`** — role-specific defaults, documented
   in-line. These are the "sane defaults" any installation can start with.
2. **`group_vars/macmini.yml`** — environment-specific overrides. The NFS
   server address, your user ID, the path to ffmpeg, etc. Most users only
   need to edit this file.

Override precedence (highest wins):

```
-e var=value      (command line)
group_vars/macmini.yml
roles/<role>/defaults/main.yml
```

---

## Prerequisites

The setup involves three machines: a **controller** (where you run
Ansible), the **target Mac** (where the media servers run), and the
**NFS server** (where media + backups live). Every prereq below maps to
one of those three.

If you only want the short version: skip to
[Bootstrap (install from scratch)](#bootstrap-install-from-scratch),
then come back if `make preflight` fails.

---

### 1. Hardware

| | Requirement |
|---|---|
| Mac model | Apple Silicon (M1 / M2 / M3 / M4 — anything **arm64**). Intel Macs work in principle but `ffmpeg_path` and `brew_bin` need overriding, and `softwareupdate` install of CLT may diverge. |
| RAM | 8 GB minimum (16 GB+ if you transcode 4K) |
| Local SSD free space | ≥ 50 GB free for SQLite DBs, transcoding-temp, app bundles, and the rolling local backup tarballs (`/var/backups/mac-media`) |
| NFS server | Any Linux distro with NFSv4 support (kernel 3.10+). FreeBSD/Solaris work too. macOS-as-NFS-server is not tested. |

---

### 2. On the controller (your workstation)

```bash
brew install ansible sshpass
```

Detailed list:

| Tool | Why | Tested version |
|---|---|---|
| `ansible-core` | runs the playbooks | 2.16+ |
| `sshpass` | one-shot password push for `make ssh-key`. Not used after key is installed. | any |
| `git` | clone this repo | any |
| `/bin/bash` | the Makefile + a few inline shells use bashisms | any modern bash |
| `make` | every interaction goes through `make <target>` | any |
| `python3` | for Ansible itself; Homebrew installs it as a dep of `ansible-core` | 3.10+ |

No external Ansible collections are required — every task uses
`ansible.builtin.*`.

**Controller → Mac connectivity**: TCP/22 (SSH) must be reachable from
the controller to the Mac. If they're on different subnets, make sure
your firewall rules permit it.

---

### 3. On the target Mac

This is a **headless server** setup. macOS defaults assume a desktop user
at a keyboard, so a few settings have to change before bootstrap. The
[`preflight.yml`](preflight.yml) playbook verifies the hard requirements
automatically — run `make preflight` any time to get a status report.

#### 3.1 macOS version + architecture

| Item | Requirement |
|---|---|
| macOS version | Sequoia 15.x tested. Sonoma 14.x and Ventura 13.x should work (no version-gated APIs are used). |
| Architecture | **arm64**. Hard fail if `uname -m` returns anything else. |
| User-facing setup wizard | Complete it once (create the admin account, accept the EULA). The Mac must reach the login screen before Ansible can SSH in. |

#### 3.2 Administrator user account

The connecting SSH user must:

| | Why |
|---|---|
| Be a member of the `admin` group | Required for `sudo` (which every privileged task uses) AND for Homebrew to chown `/opt/homebrew`. |
| Have a real password (not Touch-ID only) | `MAC_PASSWORD` env var is passed to `ansible_become_password`. Touch ID can't satisfy a non-interactive `sudo`. |
| Know its own password | You'll set it in `MAC_PASSWORD` on the controller. |

To verify:

```bash
ssh <admin_user>@<mac_ip> 'id -Gn | grep -wq admin && echo ok'
```

#### 3.3 macOS system settings (manual, before bootstrap)

These can't be set by Ansible because they require interactive UI confirmations or affect the very transport Ansible would use.

| Setting | Where | Required value | Why |
|---|---|---|---|
| **Remote Login (SSH)** | System Settings → General → Sharing → Remote Login | **On**, Allow access for: All users (or just the admin user) | Ansible's transport. Without this nothing works. |
| **FileVault** | System Settings → Privacy & Security → FileVault | **Off** | Headless boot can't unlock the disk → LaunchDaemons never start. Disable BEFORE you start; decryption can take hours. |
| **Automatic login** | System Settings → Users & Groups → Automatic login | Off (default) | All services run as system LaunchDaemons; no GUI session is needed. |
| **Screen Lock** | System Settings → Lock Screen | Anything | Doesn't matter for daemons. Set to whatever fits your physical access model. |
| **Software Update → Auto-install macOS updates** | System Settings → General → Software Update | Up to you | Recommend **off** — surprise reboots break running streams. Update on a maintenance window. |
| **Wake on network access** | System Settings → Energy / Lock Screen | On | Lets you wake the Mac for maintenance with WoL. Equivalent to `pmset womp 1`. |

#### 3.4 macOS settings auto-checked by preflight

Preflight will **hard-fail** if any of these are wrong. Fix before re-running:

- Architecture is arm64
- `sudo` works (i.e. `MAC_PASSWORD` is valid and the user is in the `admin` group)
- FileVault is OFF

Preflight will **warn** (not block) on:

- `pmset` not set to `sleep=0`, `autorestart=1`, `womp=1` — fix with
  `sudo pmset -a sleep 0 disksleep 0 autorestart 1 powernap 0 womp 1`
- NFS server unreachable on TCP/2049 — fix the network / firewall / exports

Preflight will **report (info-only)**:

- SIP status — expected to be **enabled** (this project does NOT need SIP off)
- Xcode CLT — installed automatically by `mac_base` if missing
- Homebrew — installed automatically by `mac_base` if missing
- ffmpeg — installed by `jellyfin_install` if missing
- `/data` symlink state — only exists after the first `bootstrap-base` + reboot

#### 3.5 Installed automatically by `mac_base` (no action needed)

These used to be manual steps; they now run as part of `make bootstrap`.
You can pre-install any of them if you want (it just makes the first
bootstrap slightly faster), but you don't have to.

| Auto-installed thing | How | Time on a fresh Mac |
|---|---|---|
| Xcode Command Line Tools | `softwareupdate -i` via the `.com.apple.dt.CommandLineTools.installondemand.in-progress` trigger trick | 5-15 min |
| Homebrew | `NONINTERACTIVE=1` install script, run as `brew_install_user` (default = the connecting SSH user). `/opt/homebrew` is pre-created with the right ownership so the installer never prompts for sudo. | 2-5 min |
| ffmpeg | `brew install ffmpeg` (in the `jellyfin_install` role) | 1-2 min |

#### 3.6 Things to leave alone

| Setting | Recommended | Why |
|---|---|---|
| **SIP (System Integrity Protection)** | **Enabled** (macOS default) | This project only writes to non-SIP paths (`/etc/synthetic.conf`, `/etc/auto_master`, `/Library/LaunchDaemons`, `/Applications`, `/opt`, `/var/lib`, `/private`). Disabling SIP would weaken the system without any benefit. |
| **Gatekeeper** | Enabled | The roles strip `com.apple.quarantine` xattr from downloaded binaries automatically. |
| **/usr/bin/python3 shim** | Don't replace | Used by `ansible_python_interpreter`. The CLT install provides the real binary behind the shim. |

#### 3.7 Network on the Mac

| | Recommendation |
|---|---|
| IP address | **Static or DHCP reservation**. `inventory.yml` hard-codes the Mac's IP (`ansible_host`); a roaming IP breaks Ansible. |
| Outbound to internet | Required during bootstrap/update: `api.github.com`, `repo.jellyfin.org`, `raw.githubusercontent.com` (for Homebrew installer), `*.brew.sh`, Apple update servers. |
| Inbound TCP/22 (SSH) | From the controller's IP |
| Inbound TCP/8096 | From clients that watch Emby |
| Inbound TCP/8097 | From clients that watch Jellyfin |
| Outbound TCP/2049 (NFS) | To the NFS server |

#### 3.8 Verify everything

```bash
make preflight
```

`make bootstrap` runs preflight automatically before anything else, so a
fresh install can't accidentally start on an unready host.

---

### 4. On the NFS server (Linux example)

#### 4.1 Server software

| | Requirement |
|---|---|
| Kernel | NFSv4 support (Linux 3.10+) |
| `nfs-utils` (Linux) | `exportfs`, `rpc.nfsd` |
| NFSv4 enabled | Default on modern distros. Verify with `cat /proc/fs/nfsd/versions` shows `+4`. |
| Firewall | TCP/2049 reachable from the Mac's IP |
| Filesystem under `/export` | XFS or ext4 recommended; ZFS works fine |

#### 4.2 Required exports

`/etc/exports` must include four entries authorizing the Mac's IP:

```
/export                <mac_ip>(sync,ro,insecure,root_squash,fsid=0)
/export/videos         <mac_ip>(async,ro,insecure,root_squash,all_squash,
                                 anonuid=10000,anongid=10000,fsid=...)
/export/nfs-midia      <mac_ip>(async,rw,insecure,root_squash,all_squash,
                                 anonuid=10000,anongid=10000,fsid=...)
/export/dmz3-backup    <mac_ip>/32(async,rw,insecure,root_squash,all_squash,
                                    anonuid=10000,anongid=10000,fsid=...)
```

Important notes:
- `fsid=0` on `/export` is the **NFSv4 pseudoroot**. Without it the Mac
  mount fails with "Invalid argument".
- `anonuid/anongid=10000` map all writes to the `media` user (uid 10000),
  which matches the user this setup creates on the Mac. Change both
  sides together if you change `media_uid`/`media_gid` in `group_vars`.
- Replace each `fsid=...` with a unique UUID per export (`uuidgen`).
- After editing: `sudo exportfs -ra` (no `systemctl restart` needed for
  exports-only changes).
- Filesystem ownership under each export should match — `chown -R 10000:10000`
  the `nfs-midia` and `dmz3-backup` trees so the Mac (mapped to uid 10000)
  can write.

#### 4.3 Required directory layout

The Mac expects to find these subdirectories under the NFS exports
(the roles create them on first run, but the parent dirs must be
writable):

```
/export/nfs-midia/
  ├── jellyfin/{cache,metadata,trickplay}    # created by jellyfin_install
  └── emby/{cache,metadata}                  # created by emby_install

/export/dmz3-backup/
  └── db/                                    # created by nfs_push role
```

---

### 5. Network / firewall (between subnets)

If the controller, Mac, and NFS server are on different subnets, you
need rules permitting:

| Source | Destination | Port | Purpose |
|---|---|---|---|
| Controller | Mac | TCP/22 | Ansible SSH |
| Mac | NFS server | TCP/2049 | NFS traffic |
| Mac | Internet | TCP/443 | GitHub + Homebrew + Apple updates |
| Clients | Mac | TCP/8096 | Emby HTTP |
| Clients | Mac | TCP/8097 | Jellyfin HTTP |

For long-lived NFS on a stateful firewall, see the
[Firewall rule (OPNsense / pf example)](#firewall-rule-opnsense--pf-example)
section above and the [TCP keepalive](#tcp-keepalive-anti-nfs-hang) section below.

---

### 6. Credentials / secrets

You need exactly one secret on the controller: the Mac admin user's
password. The repo never stores it; it's read from `MAC_PASSWORD`.

```bash
export MAC_PASSWORD='your-mac-password'
```

For long-term use store it in the macOS Keychain (see
[Credentials](#credentials)) and let `make` pick it up. SSH key
authentication is recommended (`make ssh-key`, one-time), but the
sudo escalation still needs `MAC_PASSWORD`.

---

## Configuration

The minimum you need to edit is `group_vars/macmini.yml` (top section). The
most common changes:

| Variable | Default | Change when... |
|---|---|---|
| `nfs_server` | `192.168.253.250` | Your NFS server is at a different IP |
| `nfs_videos_export` | `/videos` | Your export path differs |
| `nfs_midia_export` | `/nfs-midia` | Your export path differs |
| `nfs_backup_export` | `/dmz3-backup` | You use a different export for backups |
| `media_uid` / `media_gid` | `10000` | You need a different mapped UID |
| `ffmpeg_path` | `/opt/homebrew/bin/ffmpeg` | Intel Mac (`/usr/local/bin/ffmpeg`) or a custom build |

Role-specific knobs (port numbers, install paths, retention counts) live in
each `roles/<role>/defaults/main.yml` with documentation. Override them in
`group_vars/macmini.yml` if you need to:

```yaml
# group_vars/macmini.yml
jellyfin_port: 8096      # if you don't run Emby on the same host
keep_db_backups: 10      # keep more local DB backups
nfs_backup_enabled: false # disable off-machine push
```

---

## Credentials

### Quick — password via env

```bash
export MAC_PASSWORD='your-mac-password'
```

### Recommended — SSH key (one-time)

```bash
export MAC_PASSWORD='your-mac-password'
make ssh-key
# after this, comment out `ansible_password:` in inventory.yml.
# `sudo` still needs the password, supplied via MAC_PASSWORD env.
```

### Storing in macOS Keychain (for cron)

```bash
# add once
security add-generic-password -a $USER -s mac-mini -w 'your-mac-password'

# retrieve in a script / crontab
MAC_PASSWORD=$(security find-generic-password -s mac-mini -w)
```

---

## Bootstrap (install from scratch)

```bash
cd ansible-mac-emby-jelly
export MAC_PASSWORD='your-mac-password'

# 0) Smoke test
make ping
#   media01 | SUCCESS => {"changed": false, "ping": "pong"}

# 1) System base: media user, synthetic.conf, auto_nfs, TCP keepalive
make bootstrap-base
```

⚠️ **A one-time reboot is required after bootstrap-base.** `/etc/synthetic.conf`
is only re-evaluated by macOS at boot, so `/data` does not become a symlink
until you reboot. Without `/data`, the NFS mounts fail.

```bash
ssh <mac_user>@<mac_ip> 'sudo shutdown -r now'

# wait ~1 minute, verify:
ssh <mac_user>@<mac_ip> 'ls -la /data'
# lrwxr-xr-x  1 root  wheel  24 ... /data -> System/Volumes/Data/data
```

Then install the applications:

```bash
# 2) Install both Jellyfin and Emby
make bootstrap

# or one at a time:
make bootstrap-jelly
make bootstrap-emby
```

### What each bootstrap role does internally

#### `mac_base`

1. Create `media` group (gid from `media_gid`) via `dscl`
2. Create `media` user (uid from `media_uid`, shell `/usr/bin/false`, no
   home) via `dscl`
3. Render `/etc/synthetic.conf` from template → declares `/data → System/Volumes/Data/data`
4. Append `/-  /etc/auto_nfs` to `/etc/auto_master` (only if missing)
5. Render `/etc/auto_nfs` from template → declares the two NFS mounts
6. Render `/Library/LaunchDaemons/com.local.tcp-keepalive.plist` from
   template → applies 4 sysctls at every boot
7. Apply the 4 TCP keepalive sysctls immediately (no reboot needed for
   keepalive)
8. Reload `automount` (handler)
9. Bootstrap the keepalive LaunchDaemon (handler)

#### `jellyfin_install`

1. Verify Homebrew ffmpeg is available; run `brew install ffmpeg` if not
2. Skip the rest if `/opt/jellyfin/jellyfin` already exists (idempotent)
3. Query GitHub: latest release of `jellyfin/jellyfin`
4. Download `https://repo.jellyfin.org/files/server/macos/latest-stable/arm64/jellyfin_<VER>-arm64.tar.xz`
5. Extract to `/opt/jellyfin`, chown to media user, strip quarantine xattr
6. Create `/var/lib/jellyfin/{,data,log,transcoding-temp}`
7. Render `com.jellyfin.server.plist` from template
8. `launchctl bootstrap system/com.jellyfin.server`
9. Poll `http://127.0.0.1:8097/System/Info/Public` until HTTP 200

#### `emby_install`

1. Skip the rest if `/Applications/EmbyServer.app` already exists
2. Query GitHub: latest **stable** release of `MediaBrowser/Emby.Releases`
   (skip prereleases unless `include_prereleases: true`)
3. Download the `embyserver-osx-arm64-<VER>.zip` asset
4. Extract, move the `.app` to `/Applications`, strip AppleDouble files,
   strip quarantine xattr
5. chown to `root:wheel` (Emby internally drops to the media user)
6. Create `/var/lib/emby/{,data,config,logs,plugins,transcoding-temp}`
7. **Create symlinks**:
   - `/var/lib/emby/cache → /data/nfs-midia/emby/cache`
   - `/var/lib/emby/metadata → /data/nfs-midia/emby/metadata`
8. Render `com.embyserver.server.plist` from template (with the
   `-service -noautoupdate` flags)
9. `launchctl bootstrap system/com.embyserver.server`
10. Poll `http://127.0.0.1:8096/System/Info/Public` until HTTP 200

---

## Updates (ongoing operations)

```bash
make update-all          # update both if a newer version is available
make update-jellyfin     # Jellyfin only
make update-emby         # Emby only

make force-jellyfin      # reinstall even when on the latest version
make force-emby
```

### Internal sequence of each update

1. **Query GitHub** for the latest release (Jellyfin from
   `jellyfin/jellyfin`, Emby from `MediaBrowser/Emby.Releases`)
2. **Read installed version** — `plutil -extract CFBundleVersion` for
   Emby; `jellyfin --version` for Jellyfin (note: Jellyfin exits with
   rc=1 even on success, the role uses `failed_when: false` for that
   task)
3. **If equal AND `force_update=false`:** `end_host` — no changes
4. **Download** the new binary (zip for Emby, tar.xz for Jellyfin)
5. **DB backup preflight** — `sqlite3 .backup` is run against the live
   DB (consistent online snapshot). The tarball includes:
   - SQLite snapshot(s)
   - XML configs
   - plugin binaries + their configurations
   - everything else under the data dir EXCEPT NFS symlinks, logs,
     and transcoding-temp
6. **NFS push** — mount the off-machine NFS share, `cp -p` the tarball,
   prune old remote backups, unmount (`always:` block — unmount runs
   even if the copy failed)
7. **Stop launchd**
8. **Move** the current binary directory to `{{ backup_dir }}/...` with
   a timestamp suffix
9. **Move in** the new binary directory
10. **chown** appropriately + strip quarantine xattr
11. **Start launchd**
12. **Poll** the HTTP endpoint until the daemon responds
13. **Prune** old local backups

Why the DB backup runs BEFORE stopping the daemon: if anything in the
backup pipeline fails, the daemon keeps running and no downtime is incurred.

---

## Backups

### Snapshot now without updating

```bash
make backup
```

Same as steps 5-6 of an update, no binary swap. Idempotent — safe to run as
often as you want.

### Listing

```bash
make list-backups        # local app bundle backups
make list-db-backups     # local DB tarballs
make list-remote-backups # off-machine DB tarballs (mounts NFS, lists, unmounts)
```

### What goes into the backup tarball

Only LOCAL data is included; NFS-backed directories are excluded.

**Emby (`/var/lib/emby/`):**
- ✅ `data/*.db` (live SQLite snapshots) and `data/livetv`, `data/ScheduledTasks`, txt files
- ✅ `config/` (system.xml, users, mb.lic, ScheduledTasks)
- ✅ `plugins/` (binaries + configuration)
- ❌ `cache/` (symlink → NFS) — excluded
- ❌ `metadata/` (symlink → NFS) — excluded
- ❌ `logs/`, `transcoding-temp/`

**Jellyfin (`/var/lib/jellyfin/`):**
- ✅ Root XML configs (system, network, encoding, branding, database, metadata, xbmcmetadata)
- ✅ `.jellyfin-config` marker, `logging.default.json`
- ✅ `.aspnet/DataProtection-Keys/` (auth keys)
- ✅ `data/data/jellyfin.db` (live SQLite snapshot)
- ✅ `data/data/{ScheduledTasks,collections,subtitles,playlists,device.txt}`
- ✅ `data/root/`, `data/plugins/`
- ❌ `data/data/trickplay` (symlink → NFS)
- ❌ `data/data/SQLiteBackups/` (Jellyfin's own internal backups)
- ❌ `data/data/jellyfin.db.before-*` (migration leftovers if any)
- ❌ `cache/`, `log/`, `.temp/`, `lost+found/`

### Retention

| Variable | Default | Defined in |
|---|---|---|
| `keep_backups` | 3 | `roles/{jellyfin,emby}_update/defaults/main.yml` |
| `keep_db_backups` | 5 | `roles/{jellyfin,emby}_update/defaults/main.yml` |
| `keep_remote_db_backups` | 30 | `roles/nfs_push/defaults/main.yml` |

Local DB backup sizes: Emby ≈ 150 MB, Jellyfin ≈ 600 MB (gz compressed
SQLite snapshots).

---

## TCP keepalive (anti-NFS-hang)

A LaunchDaemon (`com.local.tcp-keepalive`) applies four sysctls at every
boot. Their values come from `roles/mac_base/defaults/main.yml`:

| Sysctl | macOS default | Default we apply | Why |
|---|---|---|---|
| `net.inet.tcp.always_keepalive` | 0 (opt-in) | **1** (forced) | NFS client may not opt-in via `SO_KEEPALIVE` |
| `net.inet.tcp.keepidle` | 7,200,000 ms (2h) | **120,000 ms (2 min)** | macOS default is too lax for firewall state survival |
| `net.inet.tcp.keepintvl` | 75,000 ms | **30,000 ms** | Probe interval after first miss |
| `net.inet.tcp.keepcnt` | 8 | 8 (unchanged) | Probes before declaring dead |

Behavior: after 2 minutes of idle, the Mac sends a TCP probe. If no ACK,
it retries every 30 s up to 8 times — 4 minutes total before declaring
the connection dead. This refreshes the firewall's state-table entry well
before any sensible idle-timeout and detects a dead NFS server quickly.

Combined with the OPNsense rule (sloppy state + `tcp.established=432000`),
this eliminates the "NFS server not responding" symptom that occurs
when the firewall expires the state table during a quiet period.

---

## Idempotency

Every playbook is idempotent — running it again has no effect once the
desired state is reached.

```bash
$ make bootstrap-base
PLAY RECAP: ok=9 changed=0 failed=0

$ make update-all                  # when already on the latest version
PLAY RECAP: ok=17 changed=0 failed=0

$ make backup                       # changed=3 = the three new tarballs
PLAY RECAP: ok=14 changed=3 failed=0
```

---

## Scheduling (cron)

To take an automatic daily backup on the controller (not on the Mac):

```cron
# minute hour dow command
17 4 * * *  cd ~/git/.../ansible-mac-emby-jelly && \
            MAC_PASSWORD=$(security find-generic-password -s mac-mini -w) \
            make backup >> /tmp/mac-backup.log 2>&1
```

To also update both apps weekly at 5 am Sunday:

```cron
17 5 * * 0  cd ~/git/.../ansible-mac-emby-jelly && \
            MAC_PASSWORD=$(security find-generic-password -s mac-mini -w) \
            make update-all >> /tmp/mac-update.log 2>&1
```

---

## Troubleshooting

### NFS "not responding" on the Mac

```bash
ssh <mac_user>@<mac_ip>
mount | grep nfs                                  # is it mounted?
sudo umount -f /data/videos /data/nfs-midia       # force unmount
sudo automount -vc                                # reload autofs
ls /data/videos                                   # should remount on access
```

If it persists, check:
- The NFS server (`systemctl status nfs-server`)
- The firewall rule (sloppy state + extended TCP timeout)
- That the TCP keepalive LaunchDaemon is loaded:
  `sudo launchctl list | grep com.local.tcp-keepalive`

### Emby home page stuck on "loading"

Almost always a hung NFS cache or metadata mount. Follow the procedure
above.

### Syntax check before applying

```bash
for p in *.yml; do
  ansible-playbook -i inventory.yml --syntax-check "$p"
done
```

### See logs of last daemon run

```bash
ssh <mac_user>@<mac_ip> 'sudo tail -50 /var/lib/jellyfin/log/launchd-stdout.log'
ssh <mac_user>@<mac_ip> 'sudo tail -50 /var/lib/emby/logs/embyserver.txt'
```

### Inspect launchd state

```bash
ssh <mac_user>@<mac_ip> 'sudo launchctl print system/com.jellyfin.server | head -30'
ssh <mac_user>@<mac_ip> 'sudo launchctl print system/com.embyserver.server | head -30'
```

### Force restart a daemon without re-deploy

```bash
ssh <mac_user>@<mac_ip> 'sudo launchctl kickstart -k system/com.jellyfin.server'
ssh <mac_user>@<mac_ip> 'sudo launchctl kickstart -k system/com.embyserver.server'
```

---

## Known limitations

- **`jellyfin --version` returns rc=1** even on success → version-read
  task uses `failed_when: false`.
- **macOS rsync is v2.6.9** (very old, lacks `--info=stats2` and other
  modern flags) → the `nfs_push` role uses `/bin/cp -p` instead of rsync.
- **autofs on macOS rejects `nolocks`** with NFSv4 → option removed from
  the auto map.
- **`/etc/synthetic.conf` is only evaluated at boot** → the first
  bootstrap requires a manual reboot.
- **Emby `.app` downloaded via curl gets a quarantine xattr** → roles
  strip with `xattr -dr com.apple.quarantine`.
- **`launchctl bootout` drops active streams** — schedule updates during
  a low-use window.

---

## License

This is a personal homelab repo. No license — feel free to copy ideas or
fork it for your own use.
