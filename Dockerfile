FROM postgres:15

# Instala pgBackRest e dependencias
RUN apt-get update && apt-get install -y \
    pgbackrest \
    wget \
    cron \
    && rm -rf /var/lib/apt/lists/*

# Cria diretorios necessarios
RUN mkdir -p /var/log/pgbackrest \
    && mkdir -p /var/lib/pgbackrest \
    && mkdir -p /etc/pgbackrest/conf.d

# Copia configuracao base
COPY pgbackrest.conf /etc/pgbackrest/pgbackrest.conf

# Permissoes corretas para o usuario postgres
RUN chown -R postgres:postgres /var/log/pgbackrest \
    && chown -R postgres:postgres /var/lib/pgbackrest \
    && chown -R postgres:postgres /etc/pgbackrest \
    && chmod 750 /var/lib/pgbackrest

# Copia e configura o entrypoint customizado
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
