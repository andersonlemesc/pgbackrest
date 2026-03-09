# PostgreSQL 15 + pgBackRest

Imagem Docker do PostgreSQL 15 com pgBackRest integrado para backup automático em repositório S3/MinIO.

## Funcionalidades

- Backup full semanal (domingo às 01h)
- Backup incremental diário (segunda a sábado às 01h)
- Check do pipeline a cada 6h
- Archiving contínuo de WAL para PITR (Point-in-Time Recovery)
- Armazenamento comprimido com lz4 em S3/MinIO
- Retenção configurável (padrão: 7 backups full)

## Configuração

### 1. Configure o pgbackrest.conf

Edite o arquivo `pgbackrest.conf` preenchendo suas credenciais:

```ini
repo1-s3-bucket=SEU_BUCKET
repo1-s3-endpoint=SEU_ENDPOINT_MINIO
repo1-s3-key=SUA_ACCESS_KEY
repo1-s3-key-secret=SUA_SECRET_KEY
```

### 2. Build da imagem

```bash
docker build -t SEU_USUARIO/postgres-pgbackrest:15 .
docker push SEU_USUARIO/postgres-pgbackrest:15
```

### 3. Volumes externos necessários

Crie os volumes antes de subir a stack:

```bash
docker volume create postgres_data
docker volume create pg_extensions
docker volume create pg_libs
docker volume create pgbackrest_log
```

### 4. Suba a stack

```bash
docker stack deploy -c docker-compose.yml postgres
```

### 5. Crie a stanza na primeira execução

```bash
docker exec <container_id> su -c 'pgbackrest --stanza=main stanza-create' postgres
```

### 6. Primeiro backup full manual

```bash
nohup docker exec <container_id> su -c 'pgbackrest --stanza=main backup --type=full' postgres > /tmp/pgbackrest-full.log 2>&1 &
tail -f /tmp/pgbackrest-full.log
```

## Comandos úteis

```bash
# Verificar status dos backups
docker exec <container_id> su -c 'pgbackrest --stanza=main info' postgres

# Verificar pipeline de archiving
docker exec <container_id> su -c 'pgbackrest --stanza=main check' postgres

# Ver logs do cron
docker exec <container_id> tail -f /var/log/pgbackrest/cron.log
```

## Restore com PITR

Para restaurar em um ponto específico no tempo sem comprometer o banco em produção,
suba um novo container com volume separado e execute:

```bash
docker exec <novo_container> su -c \
  'pgbackrest --stanza=main restore --target="YYYY-MM-DD HH:MM:SS" --target-action=promote --type=time' \
  postgres
```

## Estrutura do repositório no MinIO

```
/repo/
  backup/main/   ← backups full e incrementais
  archive/main/  ← WALs arquivados continuamente
```
