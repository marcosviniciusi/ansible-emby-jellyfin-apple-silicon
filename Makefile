SHELL := /bin/bash

# Override with: make MAC_PASSWORD=xxx update-all
MAC_PASSWORD ?= $(shell echo $$MAC_PASSWORD)

EXTRA ?=
ANSIBLE := MAC_PASSWORD=$(MAC_PASSWORD) ansible-playbook
ANSIBLE_ADHOC := MAC_PASSWORD=$(MAC_PASSWORD) ansible

.PHONY: help check ping preflight bootstrap bootstrap-base bootstrap-jelly bootstrap-emby \
        update-all update-emby update-jellyfin force-emby force-jellyfin \
        backup list-backups list-db-backups list-remote-backups ssh-key \
        stop-services start-services

help:
	@echo "Bootstrap (disaster-recovery / fresh install):"
	@echo "  preflight         - verify host readiness (FileVault, Homebrew, sudo, NFS)"
	@echo "  bootstrap         - full from-scratch install (preflight + mac_base + jellyfin + emby)"
	@echo "  bootstrap-base    - system base only (user, synthetic.conf, auto_nfs, keepalive)"
	@echo "  bootstrap-jelly   - install Jellyfin only (binary, plist, launchd)"
	@echo "  bootstrap-emby    - install Emby only (binary, plist, launchd)"
	@echo ""
	@echo "Operations:"
	@echo "  ping              - test connectivity to Mac"
	@echo "  check             - dry run version check (no changes)"
	@echo "  update-all        - update both Jellyfin and Emby if newer (+ DB backup)"
	@echo "  update-jellyfin   - update Jellyfin only (+ DB backup)"
	@echo "  update-emby       - update Emby only (+ DB backup)"
	@echo "  force-jellyfin    - reinstall Jellyfin regardless of version"
	@echo "  force-emby        - reinstall Emby regardless of version"
	@echo "  backup            - DB+config backup only, no app update"
	@echo "  stop-services     - stop Emby+Jellyfin and unmount NFS shares"
	@echo "  start-services    - mount NFS shares and start Emby+Jellyfin"
	@echo "  list-backups      - list app bundle backups on Mac"
	@echo "  list-db-backups   - list DB+config tarball backups on Mac (local)"
	@echo "  list-remote-backups - list DB+config tarball backups on NFS (off-machine)"
	@echo "  ssh-key           - copy local SSH key to Mac (one-time)"
	@echo ""
	@echo "Password: export MAC_PASSWORD=xxx  OR  make MAC_PASSWORD=xxx <target>"

ping:
	$(ANSIBLE_ADHOC) -i inventory.yml -m ping macmini

preflight:
	$(ANSIBLE) preflight.yml $(EXTRA)

bootstrap:
	$(ANSIBLE) bootstrap.yml $(EXTRA)

bootstrap-base:
	$(ANSIBLE) bootstrap-base.yml $(EXTRA)

bootstrap-jelly:
	$(ANSIBLE) bootstrap-jellyfin.yml $(EXTRA)

bootstrap-emby:
	$(ANSIBLE) bootstrap-emby.yml $(EXTRA)

check:
	$(ANSIBLE) update-all.yml --check --diff $(EXTRA)

update-all:
	$(ANSIBLE) update-all.yml $(EXTRA)

update-jellyfin:
	$(ANSIBLE) update-jellyfin.yml $(EXTRA)

update-emby:
	$(ANSIBLE) update-emby.yml $(EXTRA)

force-jellyfin:
	$(ANSIBLE) update-jellyfin.yml -e force_update=true $(EXTRA)

force-emby:
	$(ANSIBLE) update-emby.yml -e force_update=true $(EXTRA)

backup:
	$(ANSIBLE) backup-only.yml $(EXTRA)

stop-services:
	$(ANSIBLE) stop-services.yml $(EXTRA)

start-services:
	$(ANSIBLE) start-services.yml $(EXTRA)

list-backups:
	$(ANSIBLE_ADHOC) -i inventory.yml macmini -m shell -a 'ls -la /var/backups/mac-media/' --become

list-db-backups:
	$(ANSIBLE_ADHOC) -i inventory.yml macmini -m shell -a 'ls -lah /var/backups/mac-media/db/' --become

list-remote-backups:
	$(ANSIBLE_ADHOC) -i inventory.yml macmini -m shell --become -a \
	  'mkdir -p /private/tmp/nfs-backup && \
	   mount -t nfs -o vers=4,rw 192.168.253.250:/dmz3-backup /private/tmp/nfs-backup && \
	   ls -lah /private/tmp/nfs-backup/db/ ; \
	   umount /private/tmp/nfs-backup ; rmdir /private/tmp/nfs-backup'

ssh-key:
	@echo "Installing local SSH pubkey on Mac (one-time setup)..."
	@sshpass -p '$(MAC_PASSWORD)' ssh-copy-id -o StrictHostKeyChecking=no \
		-i ~/.ssh/id_rsa.pub mgabriel@192.168.251.66
	@echo "Done. You can now remove ansible_password from inventory and rely on key auth."
