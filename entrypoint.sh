#!/bin/bash
# Sem set -e: erros do pgbackrest/cron nao derrubam o postgres

# Chama como subprocesso (sem source), aí o & funciona corretamente
/usr/local/bin/docker-entrypoint.sh "$@" &
POSTGRES_PID=$!

# Aponta explicitamente para o socket Unix
until pg_isready -U "${POSTGRES_USER:-postgres}" -h /var/run/postgresql; do
  echo "Aguardando Postgres iniciar..."
  sleep 2
done

echo "Postgres pronto!"

# Cria stanza com retry (ate 5 tentativas com 10s de espera entre elas)
STANZA_OK=false
for i in $(seq 1 5); do
  if su -c 'pgbackrest --stanza=main info' postgres > /dev/null 2>&1; then
    echo "Stanza 'main' já existe. Pulando criação."
    STANZA_OK=true
    break
  fi
  echo "Tentativa $i: criando stanza 'main'..."
  if su -c 'pgbackrest --stanza=main stanza-create' postgres; then
    echo "Stanza criada com sucesso."
    STANZA_OK=true
    break
  fi
  echo "Falha na tentativa $i. Aguardando 10s..."
  sleep 10
done

if [ "$STANZA_OK" = false ]; then
  echo "AVISO: stanza-create falhou após 5 tentativas. Verifique o MinIO. O Postgres continuará rodando."
fi

# Configura cron de backups do pgbackrest
echo "Configurando cron de backups..."
echo '0 1 * * 0 postgres pgbackrest --stanza=main backup --type=full >> /var/log/pgbackrest/cron.log 2>&1' > /etc/cron.d/pgbackrest
echo '0 1 * * 1-6 postgres pgbackrest --stanza=main backup --type=incr >> /var/log/pgbackrest/cron.log 2>&1' >> /etc/cron.d/pgbackrest
echo '0 */6 * * * postgres pgbackrest --stanza=main check >> /var/log/pgbackrest/cron.log 2>&1' >> /etc/cron.d/pgbackrest
chmod 0644 /etc/cron.d/pgbackrest

if cron; then
  echo "Cron iniciado."
else
  echo "AVISO: falha ao iniciar o cron. Backups automaticos nao funcionarao."
fi

# Mantém o container vivo aguardando o processo do Postgres
wait $POSTGRES_PID
