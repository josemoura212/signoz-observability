# Setup do Monitoramento PostgreSQL

## 1. Criar usuário de monitoramento

```sql
CREATE USER otel_monitor WITH PASSWORD 'senha_segura';
GRANT pg_monitor TO otel_monitor;
GRANT SELECT ON pg_stat_statements TO otel_monitor;
```

## 2. Habilitar pg_stat_statements

Editar `postgresql.conf`:

```ini
shared_preload_libraries = 'pg_stat_statements'
pg_stat_statements.track = all
pg_stat_statements.max = 10000
```

Reiniciar o PostgreSQL e criar a extensão:

```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
```

## 3. Configurar logging para o OTel Agent

Editar `postgresql.conf`:

```ini
logging_collector = on
log_directory = 'pg_log'
log_filename = 'postgresql-%Y-%m-%d.log'
log_rotation_age = 1d
log_rotation_size = 100MB
log_line_prefix = '%t [%p] %u@%d '
log_min_duration_statement = 500
log_checkpoints = on
log_connections = on
log_disconnections = on
log_lock_waits = on
log_temp_files = 0
```

## 4. Configurar .env do agent

Copiar `.env.example` para `.env` e preencher:

```env
SIGNOZ_ENDPOINT=<IP_DO_SERVIDOR_SIGNOZ>
PG_HOST=host.docker.internal
PG_PORT=5432
PG_MONITOR_USER=otel_monitor
PG_MONITOR_PASSWORD=senha_segura
PG_DATABASE=unnichat
PG_LOG_PATH=/var/lib/postgresql/17/main/pg_log
```

## 5. Subir o agent

```bash
docker compose up -d
```
