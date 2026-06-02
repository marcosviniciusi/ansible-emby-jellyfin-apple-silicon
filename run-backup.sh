#!/bin/bash
# Daily backup script for Jellyfin + Emby
# Add to crontab: 0 2 * * * /path/to/run-backup.sh

set -euo pipefail

# Change to the ansible directory
cd "$(dirname "$0")"

# Load password from .secrets file (create it with: echo 'export MAC_PASSWORD="your_password"' > .secrets)
if [ -f .secrets ]; then
    source .secrets
else
    echo "ERROR: .secrets file not found. Create it with your MAC_PASSWORD"
    exit 1
fi

# Run the backup playbook
ansible-playbook -i inventory.yml backup-only.yml

# Optional: send notification
# echo "Backup completed at $(date)" | mail -s "Media Server Backup" your@email.com
