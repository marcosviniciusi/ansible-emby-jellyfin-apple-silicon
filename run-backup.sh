#!/bin/bash
# Daily backup script for Jellyfin + Emby
# This script can be placed anywhere (e.g., /usr/local/bin/backup-media-servers.sh)
# Add to crontab: 0 2 * * * /usr/local/bin/backup-media-servers.sh

set -euo pipefail

# Ansible playbook directory
ANSIBLE_DIR="/opt/ansible-emby-jellyfin-apple-silicon"

# Check if ansible directory exists
if [ ! -d "$ANSIBLE_DIR" ]; then
    echo "ERROR: Ansible directory not found: $ANSIBLE_DIR"
    exit 1
fi

# Change to the ansible directory
cd "$ANSIBLE_DIR"

# Load password from .secrets file
if [ -f "$ANSIBLE_DIR/.secrets" ]; then
    source "$ANSIBLE_DIR/.secrets"
else
    echo "ERROR: .secrets file not found at $ANSIBLE_DIR/.secrets"
    echo "Create it with: echo 'export MAC_PASSWORD=\"your_password\"' > $ANSIBLE_DIR/.secrets"
    echo "               chmod 600 $ANSIBLE_DIR/.secrets"
    exit 1
fi

# Log start
echo "=== Backup started at $(date) ==="

# Run the backup playbook
if ansible-playbook -i inventory.yml backup-only.yml; then
    echo "=== Backup completed successfully at $(date) ==="
    exit 0
else
    echo "=== Backup FAILED at $(date) ==="
    exit 1
fi
