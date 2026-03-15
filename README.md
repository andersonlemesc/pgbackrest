# PostgreSQL 15 + pgBackRest + MinIO

**Backup Robusto para PostgreSQL 15 em Docker Swarm**

`Docker Swarm` · `Arquitetura Container Único` · `Backup Incremental` · `PITR` · `Retenção Automática`

---

## 1. Visão Geral

Este repositório contém uma imagem Docker do PostgreSQL 15 com pgBackRest integrado para backup automático em repositório S3/MinIO, rodando em Docker Swarm.

### O que é o pgBackRest

O pgBackRest é uma solução open-source de backup para PostgreSQL desenvolvida para ambientes de missão crítica. Diferente do `pg_dump`, integra-se diretamente com o mecanismo WAL do Postgres, permitindo:

- Backup incremental e diferencial (copia apenas o que mudou)
- PITR — restaurar o banco para qualquer momento no tempo
- Compressão e criptografia nativas
- Suporte nativo a S3, MinIO e outros object stores
- Verificação de integridade automática dos backups

### Tipos de Backup

| Tipo | O que copia | Velocidade | Uso de espaço |
|---|---|---|---|
| Full | Tudo (100% dos dados) | Mais lento | Maior |
| Differential | Mudanças desde o último Full | Médio | Médio |
| Incremental | Mudanças desde o último backup de qualquer tipo | Mais rápido | Menor |

### Funcionalidades

- Backup full semanal (domingo às 01h BRT)
- Backup incremental diário (segunda a sábado às 01h BRT)
- Check do pipeline a cada 12h
- Archiving contínuo de WAL para PITR (Point-in-Time Recovery)
- Armazenamento comprimido com lz4 em S3/MinIO
- Retenção configurável (padrão: 7 backups full)
- Horários de cron configuráveis via variáveis de ambiente na stack

---

## 2. Decisão Arquitetural: Cron dentro do Container

Um container separado para o cron de backups não funciona corretamente com o pgBackRest:

| Requisito do pgBackRest | Container separado | Dentro do Postgres |
|---|---|---|
| Acesso ao socket `/var/run/postgresql` | Não — sockets não cruzam containers | Sim — acesso direto |
| Acesso direto aos arquivos de dados | Parcial (volume `:ro` insuficiente) | Sim — acesso completo |
| `pgbackrest backup` funciona sem SSH | Não — exigiria configuração SSH | Sim |
| Complexidade operacional | Alta | Baixa |

O pgBackRest precisa rodar no mesmo processo que o Postgres para ter acesso ao socket Unix e ao data directory. Por isso o cron de backups foi incorporado ao `entrypoint.sh` do próprio container do Postgres.

---

## 3. Arquitetura da Solução

```
┌─────────────────────────────────────────────────────────────────┐
│                      DOCKER SWARM NODE                          │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │       Container: SEU_USUARIO/postgres-pgbackrest:15      │   │
│  │                                                          │   │
│  │  ┌─────────────────┐    ┌────────────────────────────┐   │   │
│  │  │  PostgreSQL 15  │    │  cron (background)         │   │   │
│  │  │  porta 5432     │    │  01h domingo  → full       │   │   │
│  │  │  archive_mode   │    │  01h seg-sáb  → incr       │   │   │
│  │  │  = on           │    │  a cada 12h  → check       │   │   │
│  │  └────────┬────────┘    └────────────────────────────┘   │   │
│  │           │ WAL logs                                      │   │
│  │           ▼                                               │   │
│  │     pgBackRest (archive-push contínuo)                    │   │
│  └──────────────────────────┬───────────────────────────────┘   │
│                             │                                   │
└─────────────────────────────┼───────────────────────────────────┘
                              ▼
               ┌──────────────────────────┐
               │         MinIO            │
               │  bucket: pgbackrest      │
               │  /repo/backup/main/      │
               │  /repo/archive/main/     │
               └──────────────────────────┘
```

### Estrutura do repositório no MinIO

```
/repo/
  backup/main/   ← backups full e incrementais
  archive/main/  ← WALs arquivados continuamente
```

---

## 4. Pré-requisitos

- Docker Swarm configurado e operacional
- MinIO rodando e acessível na rede `app_network`
- Bucket `pgbackrest` criado no MinIO
- Access Key dedicada criada no MinIO com permissão no bucket

### Informações necessárias do MinIO

| Parâmetro | Exemplo | Descrição |
|---|---|---|
| `MINIO_ENDPOINT` | `minio:9000` | Host:porta do MinIO na rede interna |
| `MINIO_BUCKET` | `pgbackrest` | Nome do bucket dedicado |
| `MINIO_ACCESS_KEY` | `backup-user` | Access key com permissão no bucket |
| `MINIO_SECRET_KEY` | `senha-forte` | Secret key correspondente |
| `MINIO_REGION` | `us-east-1` | Região (padrão funciona no MinIO) |

---

## 5. Configuração do MinIO

### Criar bucket dedicado

1. Acesse o MinIO Console (porta 9001)
2. Vá em **Buckets > Create Bucket**
3. Nome: `pgbackrest`
4. Mantenha as configurações padrão e clique em Create Bucket

### Criar Access Key dedicada

1. Vá em **Access Keys > Create Access Key**
2. Anote o Access Key e Secret Key gerados
3. Aplique a policy abaixo, restrita ao bucket `pgbackrest`:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:*"],
    "Resource": [
      "arn:aws:s3:::pgbackrest",
      "arn:aws:s3:::pgbackrest/*"
    ]
  }]
}
```

> Não utilize credenciais de administrador. Crie uma access key exclusiva para backups.

---

## 6. Configuração

### 6.1. Configure o pgbackrest.conf

Edite o arquivo `pgbackrest.conf` preenchendo suas credenciais:

```ini
[global]
repo1-type=s3
repo1-path=/repo
repo1-s3-bucket=SEU_BUCKET
repo1-s3-endpoint=SEU_ENDPOINT_MINIO:9000
repo1-s3-region=us-east-1
repo1-s3-key=SUA_ACCESS_KEY
repo1-s3-key-secret=SUA_SECRET_KEY

# Para MinIO sem SSL em rede interna
repo1-s3-uri-style=path
repo1-storage-verify-tls=n

compress-type=lz4
compress-level=6
process-max=2

# Mantém os últimos 7 backups full
repo1-retention-full=7

log-level-console=info
log-level-file=detail
log-path=/var/log/pgbackrest

[global:archive-push]
compress-level=3

[main]
pg1-path=/var/lib/postgresql/data
pg1-user=postgres
pg1-port=5432
```

> O parâmetro `repo1-s3-endpoint` deve conter apenas `host:porta`, sem `http://` ou `https://`.

### 6.2. Build da imagem

```bash
docker build -t SEU_USUARIO/postgres-pgbackrest:15 .
docker push SEU_USUARIO/postgres-pgbackrest:15
```

### 6.3. Volumes externos necessários

Crie os volumes antes de subir a stack:

```bash
docker volume create postgres_data
docker volume create pg_extensions
docker volume create pg_libs
docker volume create pgbackrest_log
```

### 6.4. Suba a stack

```bash
docker stack deploy -c docker-compose.yml postgres
```

### 6.5. Crie a stanza na primeira execução

O entrypoint tenta criar a stanza automaticamente (5 tentativas com 10s de intervalo). Se o MinIO ainda não estiver disponível no primeiro boot, force manualmente:

```bash
# Verificar se a stanza existe
docker exec <container_id> su -c 'pgbackrest --stanza=main info' postgres

# Se retornar erro, forçar a criação
docker exec <container_id> su -c 'pgbackrest --stanza=main stanza-create' postgres

# Confirmar que ficou OK
docker exec <container_id> su -c 'pgbackrest --stanza=main info' postgres
```

> Em Swarm, obtenha o `container_id` com `docker ps | grep postgres`.

### 6.6. Primeiro backup full manual

```bash
nohup docker exec <container_id> su -c \
  'pgbackrest --stanza=main backup --type=full' postgres \
  > /tmp/pgbackrest-full.log 2>&1 &

tail -f /tmp/pgbackrest-full.log
```

---

## 7. Configuração dos Crons

Os horários de backup são configuráveis via variáveis de ambiente na stack. Os valores são sempre interpretados em **UTC**.

| Variável | Padrão (UTC) | Equivalente BRT (UTC-3) | Descrição |
|---|---|---|---|
| `PG_FULL_CRON` | `0 4 * * 0` | domingo 01h | Backup full semanal |
| `PG_INCR_CRON` | `0 4 * * 1-6` | seg–sáb 01h | Backup incremental |
| `PG_CHECK_CRON` | `0 */12 * * *` | a cada 12h | Check do pipeline WAL |

> **Atenção ao fuso horário:** o container roda em UTC. Para executar às **01h no horário de Brasília (BRT = UTC-3)**, use `04h UTC`. O horário `0 1 * * *` executaria às **22h BRT** do dia anterior.

Para alterar, edite as variáveis no `docker-compose.yml` e faça o redeploy:

```bash
docker stack deploy -c docker-compose.yml postgres
```

Para verificar o schedule ativo dentro do container:

```bash
docker exec <container_id> cat /etc/cron.d/pgbackrest
```

---

## 8. Múltiplos Databases

Uma instância PostgreSQL pode conter vários databases (ex: `app`, `financeiro`, `logs`). O pgBackRest faz backup do **cluster inteiro** em uma única operação — todos os databases são contemplados automaticamente, sem configuração adicional.

O conceito de **stanza** representa o cluster Postgres inteiro, não um database específico. Uma única stanza `main` cobre todos os seus databases.

### Restaurar apenas um database

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

---

## 9. Comandos Úteis

### Status e informação

```bash
# Listar todos os backups disponíveis (com tamanho, data, tipo)
docker exec <container_id> su -c 'pgbackrest --stanza=main info' postgres

# Saída em JSON (útil para scripts)
docker exec <container_id> su -c 'pgbackrest --stanza=main --output=json info' postgres

# Verificar versão instalada
docker exec <container_id> pgbackrest version
```

### Backups manuais

```bash
# Backup full
docker exec <container_id> su -c \
  'pgbackrest --stanza=main backup --type=full' postgres

# Backup incremental
docker exec <container_id> su -c \
  'pgbackrest --stanza=main backup --type=incr' postgres

# Backup diferencial
docker exec <container_id> su -c \
  'pgbackrest --stanza=main backup --type=diff' postgres
```

### Verificação e integridade

```bash
# Verificar pipeline de archiving (WAL chegando ao MinIO)
docker exec <container_id> su -c 'pgbackrest --stanza=main check' postgres

# Verificar integridade completa dos arquivos no MinIO
docker exec <container_id> su -c 'pgbackrest --stanza=main verify' postgres

# Status do archive diretamente no Postgres
docker exec <container_id> psql -U postgres -c \
  "SELECT archived_count, last_archived_wal, last_failed_wal, last_failed_msg FROM pg_stat_archiver;"
```

### Retenção e expiração

```bash
# Expirar backups que excedem a retenção configurada
docker exec <container_id> su -c 'pgbackrest --stanza=main expire' postgres

# Simular expiração sem remover (dry-run)
docker exec <container_id> su -c \
  'pgbackrest --stanza=main expire --dry-run' postgres

# Expirar um set de backup específico
docker exec <container_id> su -c \
  'pgbackrest --stanza=main --set=20240101-120000F expire' postgres
```

### Logs

```bash
# Ver log do cron de backups (últimas 50 linhas)
docker exec <container_id> tail -50 /var/log/pgbackrest/cron.log

# Acompanhar log em tempo real
docker exec <container_id> tail -f /var/log/pgbackrest/cron.log

# Filtrar apenas erros
docker exec <container_id> grep -i error /var/log/pgbackrest/cron.log

# Ver logs do serviço (entrypoint + inicialização)
docker service logs -f postgres_postgres
```

### Stanza

```bash
# Criar stanza (primeira execução ou após falha)
docker exec <container_id> su -c \
  'pgbackrest --stanza=main stanza-create' postgres

# Upgrade da stanza após major version upgrade do Postgres
docker exec <container_id> su -c \
  'pgbackrest --stanza=main stanza-upgrade' postgres

# Deletar stanza (CUIDADO: remove todos os backups do repositório)
docker exec <container_id> su -c \
  'pgbackrest --stanza=main --repo=1 stanza-delete' postgres
```

### Parar/retomar backups

```bash
# Parar todos os processos do pgBackRest
docker exec <container_id> su -c 'pgbackrest stop' postgres

# Retomar
docker exec <container_id> su -c 'pgbackrest start' postgres
```

---

## 10. Restore

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

### Restore de um set específico

```bash
# Listar backups disponíveis para obter o set ID
docker exec <container_id> su -c 'pgbackrest --stanza=main info' postgres

# Restaurar um set específico
docker exec postgres-restore su -c \
  'pgbackrest --stanza=main --set=20240101-120000F restore' postgres
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
  'pgbackrest --stanza=main restore --type=time --target="YYYY-MM-DD HH:MM:SS+00" --target-action=promote' \
  postgres

# 3. Sobe o postgres
docker exec -d postgres-restore \
  su -c 'postgres -D /var/lib/postgresql/data' postgres
```

> O erro mais comum no PITR é esquecer de usar um backup anterior ao `--target`. Se nenhum backup for encontrado antes do target, o pgBackRest usa o mais recente disponível.

### Limpeza após o restore de teste

```bash
docker rm -f postgres-restore
docker volume rm postgres_restore
```

---

## 11. Troubleshooting

### Stanza não criada / erro no boot

O entrypoint tenta criar a stanza automaticamente. Se falhar (ex.: MinIO indisponível no boot):

```bash
# Ver logs do entrypoint
docker service logs postgres_postgres 2>&1 | grep -i stanza

# Testar conectividade com o MinIO
docker exec <container_id> su -c \
  'pgbackrest --stanza=main --log-level-console=detail info' postgres

# Forçar criação da stanza
docker exec <container_id> su -c \
  'pgbackrest --stanza=main stanza-create' postgres
```

Causas comuns:
- MinIO/S3 ainda não estava disponível no momento do boot
- Credenciais incorretas no `pgbackrest.conf`
- Bucket não existe ou sem permissão de escrita
- `repo1-s3-endpoint` com `http://` no início (deve ser apenas `host:porta`)

### Cron não executando

```bash
# Verificar se o processo cron está rodando
docker exec <container_id> pgrep cron

# Ver schedule configurado
docker exec <container_id> cat /etc/cron.d/pgbackrest

# Ver últimas entradas do log
docker exec <container_id> tail -50 /var/log/pgbackrest/cron.log
```

### Archive-push falhando

```bash
# Verificar status do archive no Postgres
docker exec <container_id> psql -U postgres -c \
  "SELECT last_failed_wal, last_failed_msg FROM pg_stat_archiver;"

# Checar pipeline completo
docker exec <container_id> su -c \
  'pgbackrest --stanza=main check' postgres

# Ver erros recentes
docker exec <container_id> grep -i error /var/log/pgbackrest/cron.log
```

### Postgres não inicia após restore

```bash
# Verificar logs
docker service logs postgres_postgres

# Corrigir permissões do data directory
docker exec postgres-restore \
  chown -R postgres:postgres /var/lib/postgresql/data
docker exec postgres-restore \
  chmod 700 /var/lib/postgresql/data
```

### Atualizar a imagem após mudanças

```bash
docker build -t SEU_USUARIO/postgres-pgbackrest:15 .
docker push SEU_USUARIO/postgres-pgbackrest:15

# Forçar o Swarm a recriar o container com a nova imagem
docker service update --force postgres_postgres
```

---

## 12. Monitoramento

### Política de retenção

| Parâmetro no pgbackrest.conf | Valor sugerido | Efeito |
|---|---|---|
| `repo1-retention-full` | `7` | Mantém os últimos 7 backups full (≈ 7 semanas) |
| `repo1-retention-diff` | `14` | Mantém os últimos 14 diferenciais |
| `repo1-retention-archive` | `7` | Mantém WALs relativos aos últimos 7 fulls |

### Checklist de verificação semanal

```bash
# 1. Status geral dos backups
docker exec <container_id> su -c 'pgbackrest --stanza=main info' postgres

# 2. Integridade do pipeline WAL
docker exec <container_id> su -c 'pgbackrest --stanza=main check' postgres

# 3. Verificar se há erros no log de cron
docker exec <container_id> grep -i error /var/log/pgbackrest/cron.log | tail -20
```

---

## 13. Checklist de Implementação

- [ ] Bucket `pgbackrest` criado no MinIO
- [ ] Access Key dedicada criada com policy correta no MinIO
- [ ] `pgbackrest.conf` configurado com credenciais e endpoint do MinIO
- [ ] Imagem construída: `docker build -t SEU_USUARIO/postgres-pgbackrest:15 .`
- [ ] Imagem publicada: `docker push SEU_USUARIO/postgres-pgbackrest:15`
- [ ] Volumes externos criados (`postgres_data`, `pgbackrest_log`, etc.)
- [ ] Stack deployada no Swarm com `archive_mode=on` e `archive_command`
- [ ] Logs confirmam: `Postgres pronto!` e `Cron iniciado.`
- [ ] Stanza criada com sucesso (automática ou manual)
- [ ] `pgbackrest check` executado sem erros
- [ ] Primeiro backup Full executado com sucesso
- [ ] `pgbackrest info` mostra o backup disponível no MinIO
- [ ] Backup incremental automático funcionando no dia seguinte
- [ ] Teste de restore realizado em ambiente de homologação

> Teste o restore em ambiente separado com dados reais pelo menos uma vez por mês. Um backup nunca testado para restore não é um backup confiável.

---

## Referências

- [pgBackRest — Command Reference](https://pgbackrest.org/command.html)
- [pgBackRest — Configuration Reference](https://pgbackrest.org/configuration.html)
- [pgBackRest — User Guide (Debian/Ubuntu)](https://pgbackrest.org/user-guide.html)
- [pgBackRest — FAQ](https://pgbackrest.org/faq.html)
