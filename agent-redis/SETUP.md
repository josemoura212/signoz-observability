# Setup do Monitoramento Redis

## 1. Configurar .env do agent

Copiar `.env.example` para `.env` e preencher:

```env
SIGNOZ_ENDPOINT=<IP_DO_SERVIDOR_SIGNOZ>
REDIS_ENDPOINT=host.docker.internal:6379
REDIS_LOG_PATH=/var/log/redis
```

Se o Redis usa senha, adicionar `REDIS_PASSWORD` no `.env` e no `otel-agent-config.yaml`:

```yaml
receivers:
  redis:
    endpoint: ${env:REDIS_ENDPOINT}
    password: ${env:REDIS_PASSWORD}
```

## 2. Habilitar logging no Redis

Editar `redis.conf`:

```ini
logfile /var/log/redis/redis-server.log
loglevel notice
```

## 3. Subir o agent

```bash
docker compose up -d
```

## 4. Verificar no SigNoz

- **Infrastructure > Host Metrics** — metricas do servidor Redis
- **Dashboards** — importar dashboard de Redis metrics (connected_clients, memory, hit rate, etc.)
- **Logs** — logs do Redis com severity parsing
