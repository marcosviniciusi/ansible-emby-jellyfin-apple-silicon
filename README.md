# ansible-mac-emby-jelly

Infrastructure as Code + operations automation for the **Emby + Jellyfin** media
stack running bare-metal on a Mac Mini (Apple Silicon) with media stored on a
remote NFS server.

> **What this repo covers:**
> - ✅ Bootstrap — install from scratch on a clean macOS host
> - ✅ Updates — pull the latest release, atomic binary swap, health check
> - ✅ Backups — SQLite + config snapshots, pushed off-machine to NFS
>
> **What it does NOT cover (manual or future):**
> - ❌ Restoring a DB from a backup tarball
> - ❌ Migrating data from a Kubernetes PVC

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
├── bootstrap.yml                    # FRESH INSTALL: base + jellyfin + emby
├── bootstrap-base.yml               #   system base only
├── bootstrap-jellyfin.yml           #   Jellyfin only
├── bootstrap-emby.yml               #   Emby only
│
├── update-all.yml                   # OPS: update both with DB backup
├── update-jellyfin.yml
├── update-emby.yml
├── backup-only.yml                  # OPS: backup without updating
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

### On the controller (your workstation, where Ansible runs)

```bash
brew install ansible sshpass
```

`sshpass` is only needed for the first connection. After `make ssh-key` your
SSH public key is installed on the Mac and password auth becomes optional
(`sudo` still needs the password — see Credentials section).

### On the target Mac

1. **macOS installed** (tested on Sequoia 15.x arm64; should work on any
   recent macOS).
2. **SSH enabled**: System Settings → General → Sharing → Remote Login →
   Allow All Users.
3. **Homebrew installed**:
   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   ```
4. **ffmpeg installed via Homebrew** (Jellyfin needs it):
   ```bash
   brew install ffmpeg
   ```
   The role will run this for you if missing, but it's faster to do it once
   by hand.
5. **The admin user's password** in hand to export as `MAC_PASSWORD` for
   sudo escalation.

### On the NFS server (Linux example)

`/etc/exports` must include three entries authorizing the Mac's IP:

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
- `fsid=0` on `/export` is the NFSv4 pseudoroot. Without it the Mac mount
  fails with "Invalid argument".
- `anonuid/anongid=10000` map all writes to the `media` user (uid 10000),
  which matches the user this Ansible setup creates on the Mac. Adjust if
  you change `media_uid`/`media_gid` in `group_vars`.
- Replace each `fsid=...` with a unique UUID per export (`uuidgen`).
- After editing: `sudo exportfs -ra` (no `systemctl restart` needed for
  exports-only changes).

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
