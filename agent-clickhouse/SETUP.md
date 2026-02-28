# Setup do Monitoramento ClickHouse

## 1. Habilitar endpoint Prometheus no ClickHouse

Editar `config.xml` do ClickHouse:

```xml
<prometheus>
    <endpoint>/metrics</endpoint>
    <port>9363</port>
    <metrics>true</metrics>
    <events>true</events>
    <asynchronous_metrics>true</asynchronous_metrics>
</prometheus>
```

Reiniciar o ClickHouse e verificar:

```bash
curl http://localhost:9363/metrics | head
```

## 2. Configurar .env do agent

Copiar `.env.example` para `.env` e preencher:

```env
SIGNOZ_ENDPOINT=<IP_DO_SERVIDOR_SIGNOZ>
CLICKHOUSE_ENDPOINT=host.docker.internal:9363
CLICKHOUSE_LOG_PATH=/var/log/clickhouse-server
```

Se o ClickHouse roda em Docker, montar o volume de logs:

```env
CLICKHOUSE_LOG_PATH=/var/lib/docker/volumes/signoz-observability_clickhouse_logs/_data
```

## 3. Subir o agent

```bash
docker compose up -d
```

## 4. Verificar no SigNoz

- **Infrastructure > Host Metrics** — metricas do servidor
- **Dashboards** — importar dashboard de ClickHouse (queries, merges, memory, parts, replication lag)
- **Logs** — logs do ClickHouse com severity e query_id parsed
