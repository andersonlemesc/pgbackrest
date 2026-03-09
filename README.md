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

## Restore

> **Importante:** o pgBackRest restaura o cluster inteiro — não banco por banco.
> Sempre restaure em um container separado para não comprometer a produção.

### Restore completo (último backup)

```bash
# 1. Sobe container novo com volume vazio, sem iniciar o postgres
docker run -d \
  --name postgres-restore \
  -v postgres_restore:/var/lib/postgresql/data \
  -v /caminho/local/pgbackrest.conf:/etc/pgbackrest/pgbackrest.conf \
  SEU_USUARIO/postgres-pgbackrest:15 sleep infinity

# 2. Executa o restore (baixa do MinIO)
docker exec postgres-restore su -c \
  'pgbackrest --stanza=main restore' postgres

# 3. Sobe o postgres dentro do container
docker exec -d postgres-restore \
  su -c 'postgres -D /var/lib/postgresql/data' postgres

# 4. Conecta para validar
docker exec -it postgres-restore psql -U postgres
```

### Restore com PITR (ponto específico no tempo)

Útil para recuperar dados antes de um DELETE ou UPDATE acidental:

```bash
# 1. Sobe container novo com volume vazio
docker run -d \
  --name postgres-restore \
  -v postgres_restore:/var/lib/postgresql/data \
  -v /caminho/local/pgbackrest.conf:/etc/pgbackrest/pgbackrest.conf \
  SEU_USUARIO/postgres-pgbackrest:15 sleep infinity

# 2. Restaura no ponto exato desejado
docker exec postgres-restore su -c \
  'pgbackrest --stanza=main restore --type=time --target="YYYY-MM-DD HH:MM:SS" --target-action=promote' \
  postgres

# 3. Sobe o postgres
docker exec -d postgres-restore \
  su -c 'postgres -D /var/lib/postgresql/data' postgres
```

### Recuperar apenas um banco

Após o restore em container separado, extraia apenas o banco desejado:

```bash
# Exporta o banco do container de restore
docker exec postgres-restore pg_dump \
  -U postgres -d NOME_DO_BANCO -F c -f /tmp/banco.dump

# Copia o dump para o host
docker cp postgres-restore:/tmp/banco.dump ./

# Importa no postgres de produção
docker cp banco.dump <container_producao>:/tmp/
docker exec <container_producao> pg_restore \
  -U postgres -d NOME_DO_BANCO /tmp/banco.dump
```

### Limpeza após o restore de teste

```bash
docker rm -f postgres-restore
docker volume rm postgres_restore
```

## Estrutura do repositório no MinIO

```
/repo/
  backup/main/   ← backups full e incrementais
  archive/main/  ← WALs arquivados continuamente
```
