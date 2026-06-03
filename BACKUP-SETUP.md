# Automated Backup Setup

This guide explains how to configure daily automated backups of Jellyfin
and Emby using SSH key authentication.

## 1. Prepare the host that will run the backups

### Install the repository under /opt

```bash
# Clone the repository
sudo git clone <repo-url> /opt/ansible-emby-jellyfin-apple-silicon

# Adjust ownership (replace YOUR_USER / YOUR_GROUP with your account)
sudo chown -R YOUR_USER:YOUR_GROUP /opt/ansible-emby-jellyfin-apple-silicon
```

## 2. Configure SSH key authentication

### Generate an SSH key (if you don't have one yet)

```bash
ssh-keygen -t rsa -b 4096 -C "backup@mediaserver"
# Press Enter to accept the default location (~/.ssh/id_rsa)
# Press Enter for no passphrase (or set one if you prefer)
```

### Copy the key to the Mac Mini

```bash
cd /opt/ansible-emby-jellyfin-apple-silicon
make ssh-key MAC_PASSWORD=your_mac_password
```

### Test the SSH connection

```bash
ssh mgabriel@192.168.251.66
# Should connect without prompting for a password
```

## 3. Create the sudo (become) password file

The SSH key removes the SSH password prompt, but Ansible still needs the
sudo password for privileged operations.

```bash
# Create the .secrets file (NOT committed to git)
cd /opt/ansible-emby-jellyfin-apple-silicon
echo 'export MAC_PASSWORD="your_sudo_password"' > .secrets
chmod 600 .secrets
```

## 4. Install the backup script

```bash
# Copy the script to /usr/local/bin
sudo cp /opt/ansible-emby-jellyfin-apple-silicon/run-backup.sh /usr/local/bin/backup-media-servers.sh
sudo chmod +x /usr/local/bin/backup-media-servers.sh
```

## 5. Test the backup manually

```bash
# Run the backup
/usr/local/bin/backup-media-servers.sh

# Should run without prompting for the SSH password
# (the .secrets file supplies the sudo password)
```

## 6. Configure the daily automatic run

### Option A: Using cron (Linux/macOS)

```bash
# Edit your crontab
crontab -e

# Add a daily backup at 2 AM:
0 2 * * * /usr/local/bin/backup-media-servers.sh >> /var/log/media-backup.log 2>&1

# Create the log file (first time only)
sudo touch /var/log/media-backup.log
sudo chown YOUR_USER /var/log/media-backup.log
```

### Option B: Using a systemd timer (Linux)

Create the service unit:

```bash
sudo tee /etc/systemd/system/media-backup.service > /dev/null <<'EOF'
[Unit]
Description=Backup Jellyfin and Emby databases
After=network.target

[Service]
Type=oneshot
User=YOUR_USER
ExecStart=/usr/local/bin/backup-media-servers.sh
StandardOutput=journal
StandardError=journal
EOF
```

Create the timer:

```bash
sudo tee /etc/systemd/system/media-backup.timer > /dev/null <<'EOF'
[Unit]
Description=Daily backup of Jellyfin and Emby
Requires=media-backup.service

[Timer]
OnCalendar=daily
OnCalendar=02:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
```

Enable the timer:

```bash
sudo systemctl daemon-reload
sudo systemctl enable media-backup.timer
sudo systemctl start media-backup.timer

# Check status
sudo systemctl status media-backup.timer
sudo systemctl list-timers --all | grep media-backup
```

## 7. Check the logs

### With cron:
```bash
tail -f /var/log/media-backup.log
```

### With systemd:
```bash
journalctl -u media-backup.service -f
```

## 8. Verify the resulting backups

Backups are written to:
- **Locally on the Mac Mini**: `/var/backups/mac-media/db/`
- **Remote NFS**: as configured in `nfs_backup_export`

```bash
# List local backups on the Mac Mini
ssh mgabriel@192.168.251.66 'ls -lh /var/backups/mac-media/db/'

# Or use the Makefile
cd /opt/ansible-emby-jellyfin-apple-silicon
make list-db-backups
```

## File layout

```
/opt/ansible-emby-jellyfin-apple-silicon/
├── .secrets                    # sudo password (NOT versioned)
├── inventory.yml               # Configured with SSH key
├── backup-only.yml             # Backup playbook
├── group_vars/macmini.yml      # Variables (paths, retention, etc.)
└── run-backup.sh               # Backup script (copied to /usr/local/bin)

/usr/local/bin/
└── backup-media-servers.sh     # Script that runs the backup
```

## Security

- ✅ Private SSH key protected (`~/.ssh/id_rsa`, mode 600)
- ✅ `.secrets` file protected (mode 600)
- ✅ `.secrets` is in `.gitignore` (will not be committed)
- ⚠️ Consider using Ansible Vault to encrypt passwords in production

## Troubleshooting

### Error: "Permission denied (publickey,password)"
- Confirm the SSH key was copied: `make ssh-key MAC_PASSWORD=password`
- Test the SSH connection manually: `ssh mgabriel@192.168.251.66`

### Error: "BECOME password required"
- Confirm the `.secrets` file exists and is correct
- Confirm `MAC_PASSWORD` is exported correctly

### Error: "Variable 'xxx' is undefined"
- Confirm every variable is defined in `group_vars/macmini.yml`
- Confirm you're using the right inventory: `-i inventory.yml`

### The backup didn't run at the scheduled time
- **Cron**: check logs with `tail /var/log/media-backup.log`
- **Systemd**: check with `systemctl status media-backup.timer`
- Confirm the script path is correct
