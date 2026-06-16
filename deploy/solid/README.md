# Solid NAS → Mac media lifecycle (systemd)

Runs `make start-services` on the NAS at boot (after NFS exports are up),
and `make stop-services` on the NAS at shutdown/reboot — so the Mac stack
is gracefully stopped before the NFS server goes away, and brought back
up automatically once the NFS server returns.

Designed for OpenMediaVault (Debian-based) but should work on any
systemd-based NAS without modifying the OMV configuration.

## Prerequisites (run on the NAS as root)

1. Ansible installed
   ```bash
   ansible --version
   ```

2. SSH key from `root@solid` authorized for `mgabriel@192.168.251.66`
   ```bash
   # Generate if /root/.ssh/id_rsa does not exist yet:
   [ -f /root/.ssh/id_rsa ] || ssh-keygen -t rsa -b 4096 -N "" -f /root/.ssh/id_rsa
   ssh-copy-id -i /root/.ssh/id_rsa.pub mgabriel@192.168.251.66
   ssh -i /root/.ssh/id_rsa mgabriel@192.168.251.66 'echo ok'
   ```

3. The IaC checkout at `/opt/ansible-emby-jellyfin-apple-silicon` with
   `.secrets` present (owned by root, mode 600):
   ```bash
   cd /opt/ansible-emby-jellyfin-apple-silicon
   umask 077
   printf 'export MAC_PASSWORD=%q\n' 'SENHA_DO_MAC' > .secrets
   chmod 600 .secrets
   chown root:root .secrets
   ```

4. The inventory uses `ansible_ssh_private_key_file: ~/.ssh/id_rsa`. Since
   systemd runs as root, that resolves to `/root/.ssh/id_rsa` — which is
   where step 2 generated the key. No inventory change needed.

## Install

```bash
cd /opt/ansible-emby-jellyfin-apple-silicon
chmod 755 deploy/solid/wrap.sh
install -m 0644 deploy/solid/mac-media.service /etc/systemd/system/mac-media.service
systemctl daemon-reload
systemctl enable mac-media.service
```

## Verify

```bash
# Start now and watch the playbook output stream:
systemctl start mac-media.service &
journalctl -u mac-media.service -f
```

You should see the start-services play, then `active (exited)`. Stop test:

```bash
systemctl stop mac-media.service
journalctl -u mac-media.service -n 100
```

## How shutdown timing works

- `Type=oneshot` + `RemainAfterExit=yes` keeps the unit in the `active`
  state during normal NAS uptime, so systemd will run `ExecStop` when the
  host shuts down (`shutdown -h now`, `reboot`, `poweroff`, UPS-triggered
  halt — all funnel through `shutdown.target`).
- The default ordering (`DefaultDependencies=yes`) puts this unit
  `Before=shutdown.target` and ordered against `network.target`, so the
  stop runs BEFORE the network is torn down — SSH to the Mac still works.
- Timeout for the stop is 5 minutes (`TimeoutStopSec=300`). If Ansible
  hangs past that, systemd will kill the wrapper and continue the
  shutdown — better a 5-minute delay than a hung NAS halt.

## Disable

```bash
systemctl disable --now mac-media.service
rm /etc/systemd/system/mac-media.service
systemctl daemon-reload
```

## Troubleshooting

- `journalctl -u mac-media.service -n 200 --no-pager` — full last play.
- Unit fails on boot because NFS isn't ready yet: re-run manually with
  `systemctl restart mac-media.service`. The Emby/Jellyfin daemons on the
  Mac will themselves retry NFS access on first request, so a delayed
  start is usually harmless.
- Permission denied on Mac sudo: check `.secrets` — `cat .secrets` and
  run `. ./.secrets && echo "${MAC_PASSWORD:+ok}"` (must print `ok`).
