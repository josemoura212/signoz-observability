# Setup do Monitoramento Kafka

## Arquitetura

Este agent roda no servidor do Kafka e cumpre duas funcoes:

1. **Monitoramento do Kafka** — coleta metricas dos brokers, topics e consumer groups via `kafkametrics` receiver
2. **OTel relay** — recebe traces/metricas/logs das aplicacoes consumer via OTLP (portas 4317/4318)

## 1. Configurar .env do agent

Copiar `.env.example` para `.env` e preencher:

```env
SIGNOZ_ENDPOINT=<IP_DO_SERVIDOR_SIGNOZ>
KAFKA_BROKERS=localhost:9092
```

Se o Kafka roda em Docker no mesmo host, usar `localhost:9092` ou o mapeamento de porta correspondente.

## 2. Configurar as aplicacoes consumer

Nas aplicacoes Node.js que rodam como consumer no mesmo servidor:

```yaml
environment:
  OTEL_TRACES_EXPORTER: "otlp"
  OTEL_EXPORTER_OTLP_ENDPOINT: "http://localhost:4318"
  OTEL_NODE_RESOURCE_DETECTORS: "env,host,os"
  OTEL_SERVICE_NAME: "meu-consumer"
  NODE_OPTIONS: "--require @opentelemetry/auto-instrumentations-node/register"
```

Instalar no projeto:

```bash
npm install @opentelemetry/api @opentelemetry/auto-instrumentations-node
```

O auto-instrumentation do kafkajs gera spans de produce/consume automaticamente, alimentando a aba Messaging Queues do SigNoz.

## 3. Subir o agent

```bash
docker compose up -d
```

## 4. Verificar no SigNoz

- **Infrastructure > Host Metrics** — metricas do servidor Kafka
- **Dashboards** — importar dashboard de Kafka metrics
- **Messaging Queues** — visualizar filas (requer consumers instrumentados com OTel)
