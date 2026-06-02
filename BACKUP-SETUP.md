# Configuração de Backup Automatizado

Este guia explica como configurar backups diários automáticos do Jellyfin e Emby usando SSH key authentication.

## 1. Preparar o ambiente no servidor que executará os backups

### Instalar o repositório em /opt

```bash
# Clone o repositório
sudo git clone <url-do-repositorio> /opt/ansible-emby-jellyfin-apple-silicon

# Ajustar permissões (substitua SEU_USUARIO pelo seu usuário)
sudo chown -R SEU_USUARIO:SEU_GRUPO /opt/ansible-emby-jellyfin-apple-silicon
```

## 2. Configurar autenticação SSH com chave

### Gerar chave SSH (se ainda não tiver)

```bash
ssh-keygen -t rsa -b 4096 -C "backup@mediaserver"
# Pressione Enter para aceitar o local padrão (~/.ssh/id_rsa)
# Pressione Enter para não usar passphrase (ou use se preferir)
```

### Copiar a chave para o Mac Mini

```bash
cd /opt/ansible-emby-jellyfin-apple-silicon
make ssh-key MAC_PASSWORD=sua_senha_do_mac
```

### Testar a conexão SSH

```bash
ssh mgabriel@192.168.251.66
# Deve conectar sem pedir senha
```

## 3. Criar arquivo de senha para sudo (become)

A chave SSH elimina a senha do SSH, mas o Ansible ainda precisa da senha do sudo para operações privilegiadas.

```bash
# Criar arquivo .secrets (NÃO será versionado no git)
cd /opt/ansible-emby-jellyfin-apple-silicon
echo 'export MAC_PASSWORD="sua_senha_do_sudo"' > .secrets
chmod 600 .secrets
```

## 4. Instalar o script de backup

```bash
# Copiar script para /usr/local/bin
sudo cp /opt/ansible-emby-jellyfin-apple-silicon/run-backup.sh /usr/local/bin/backup-media-servers.sh
sudo chmod +x /usr/local/bin/backup-media-servers.sh
```

## 5. Testar o backup manualmente

```bash
# Executar o backup
/usr/local/bin/backup-media-servers.sh

# Deve executar sem pedir senha SSH (apenas usa a senha do .secrets para sudo)
```

## 6. Configurar execução automática diária

### Opção A: Usando cron (Linux/macOS)

```bash
# Editar crontab
crontab -e

# Adicionar linha para backup diário às 2h da manhã:
0 2 * * * /usr/local/bin/backup-media-servers.sh >> /var/log/media-backup.log 2>&1

# Criar o arquivo de log (primeira vez)
sudo touch /var/log/media-backup.log
sudo chown SEU_USUARIO /var/log/media-backup.log
```

### Opção B: Usando systemd timer (Linux)

Crie o serviço:

```bash
sudo tee /etc/systemd/system/media-backup.service > /dev/null <<'EOF'
[Unit]
Description=Backup Jellyfin and Emby databases
After=network.target

[Service]
Type=oneshot
User=SEU_USUARIO
ExecStart=/usr/local/bin/backup-media-servers.sh
StandardOutput=journal
StandardError=journal
EOF
```

Crie o timer:

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

Ativar o timer:

```bash
sudo systemctl daemon-reload
sudo systemctl enable media-backup.timer
sudo systemctl start media-backup.timer

# Verificar status
sudo systemctl status media-backup.timer
sudo systemctl list-timers --all | grep media-backup
```

## 7. Verificar logs

### Com cron:
```bash
tail -f /var/log/media-backup.log
```

### Com systemd:
```bash
journalctl -u media-backup.service -f
```

## 8. Verificar backups criados

Os backups são salvos em:
- **Local no Mac Mini**: `/var/backups/mac-media/db/`
- **NFS remoto**: Conforme configurado em `nfs_backup_export`

```bash
# Listar backups locais no Mac Mini
ssh mgabriel@192.168.251.66 'ls -lh /var/backups/mac-media/db/'

# Ou usar o Makefile
cd /opt/ansible-emby-jellyfin-apple-silicon
make list-db-backups
```

## Estrutura de arquivos

```
/opt/ansible-emby-jellyfin-apple-silicon/
├── .secrets                    # Senha do sudo (NÃO versionado)
├── inventory.yml              # Configurado com SSH key
├── backup-only.yml            # Playbook de backup
├── group_vars/macmini.yml     # Variáveis (paths, retention, etc)
└── run-backup.sh              # Script de backup (copiado para /usr/local/bin)

/usr/local/bin/
└── backup-media-servers.sh    # Script que executa o backup
```

## Segurança

- ✅ Chave SSH privada protegida (`~/.ssh/id_rsa` com permissão 600)
- ✅ Arquivo `.secrets` protegido (permissão 600)
- ✅ `.secrets` está no `.gitignore` (não será commitado)
- ⚠️  Considere usar Ansible Vault para criptografar senhas em produção

## Troubleshooting

### Erro: "Permission denied (publickey,password)"
- Verifique se a chave SSH foi copiada: `make ssh-key MAC_PASSWORD=senha`
- Teste a conexão SSH manualmente: `ssh mgabriel@192.168.251.66`

### Erro: "BECOME password required"
- Verifique se o arquivo `.secrets` existe e está correto
- Confirme que `MAC_PASSWORD` está exportado corretamente

### Erro: "Variable 'xxx' is undefined"
- Verifique se todas as variáveis estão em `group_vars/macmini.yml`
- Confirme que você está usando o inventory correto: `-i inventory.yml`

### Backup não executou no horário agendado
- **Cron**: Verifique logs com `tail /var/log/media-backup.log`
- **Systemd**: Verifique com `systemctl status media-backup.timer`
- Confirme que o caminho do script está correto
