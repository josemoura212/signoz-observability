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

## 2. Subir o agent

```bash
docker compose up -d
```

## 3. Verificar no SigNoz

- **Infrastructure > Host Metrics** — metricas do servidor Kafka
- **Dashboards** — importar dashboard de Kafka metrics (ver `dashboards/kafka-overview.json`)
- **Messaging Queues** — visualizar filas (requer consumers instrumentados com OTel, ver secao abaixo)

## 4. Dashboard Kafka

Importar o arquivo `dashboards/kafka-overview.json` no SigNoz:

1. Ir em **Dashboards > New Dashboard > Import JSON**
2. Colar o conteudo do arquivo `dashboards/kafka-overview.json`
3. Os paineis ja vem configurados com variaveis de filtro: `host.name`, `topic`, `group`

Paineis disponiveis:
- Brokers no cluster, Topics count
- Partitions por topic, Replicas por topic
- In-Sync Replicas, Min In-Sync Replicas
- Consumer Group Lag, Lag Sum, Offset, Members
- Partition Current/Oldest Offset
- CPU Load, Memoria, Disk I/O, Network Traffic

---

## 5. Instrumentar aplicacoes Node.js / kafkajs

Para que a aba **Messaging Queues** do SigNoz mostre dados de produce/consume, as aplicacoes Node.js que usam kafkajs precisam de instrumentacao OpenTelemetry.

### 5.1 Instalar pacotes OTel no app

No diretorio do projeto Node.js:

```bash
npm install @opentelemetry/api @opentelemetry/auto-instrumentations-node
```

O pacote `@opentelemetry/auto-instrumentations-node` inclui instrumentacao automatica para kafkajs, HTTP, Express e dezenas de outras bibliotecas.

### 5.2 Variaveis de ambiente

Adicionar as seguintes variaveis de ambiente no app (CapRover, docker-compose, ou .env):

```env
OTEL_TRACES_EXPORTER=otlp
OTEL_METRICS_EXPORTER=otlp
OTEL_LOGS_EXPORTER=otlp
OTEL_EXPORTER_OTLP_ENDPOINT=http://10.0.0.83:4318
OTEL_SERVICE_NAME=meu-consumer-app
OTEL_NODE_RESOURCE_DETECTORS=env,host,os
NODE_OPTIONS=--require @opentelemetry/auto-instrumentations-node/register
```

**Importante sobre `OTEL_SERVICE_NAME`**: cada app deve ter um nome unico (ex: `unnichat-consumer`, `notifications-worker`). Esse nome aparece na lista de Services do SigNoz.

### 5.3 Nota sobre rede (CapRover / Docker Swarm)

As aplicacoes consumer rodam no CapRover (Docker Swarm), mas o agent-kafka roda no servidor do Kafka (10.0.0.83). Por isso:

- O endpoint OTLP deve apontar para o **IP do servidor Kafka**, nao `localhost`
- O agent-kafka ja expoe as portas 4317 (gRPC) e 4318 (HTTP) para receber dados das apps
- Usar `http://10.0.0.83:4318` para HTTP (recomendado) ou `http://10.0.0.83:4317` para gRPC
- Garantir que as portas 4317/4318 estejam acessiveis na rede entre o CapRover e o servidor Kafka

### 5.4 Exemplo docker-compose (app consumer)

```yaml
services:
  meu-consumer:
    image: meu-consumer:latest
    environment:
      OTEL_TRACES_EXPORTER: "otlp"
      OTEL_METRICS_EXPORTER: "otlp"
      OTEL_LOGS_EXPORTER: "otlp"
      OTEL_EXPORTER_OTLP_ENDPOINT: "http://10.0.0.83:4318"
      OTEL_SERVICE_NAME: "meu-consumer-app"
      OTEL_NODE_RESOURCE_DETECTORS: "env,host,os"
      NODE_OPTIONS: "--require @opentelemetry/auto-instrumentations-node/register"
```

### 5.5 O que aparece no SigNoz apos instrumentar

Apos configurar e reiniciar o app:

- **Services** — o app aparece como servico com metricas RED (Rate, Error, Duration)
- **Messaging Queues** — spans de produce/consume do kafkajs com detalhes de topico, partition e consumer group
- **Traces** — traces completos das operacoes, incluindo spans `messaging.system = kafka` com atributos `messaging.destination`, `messaging.kafka.consumer.group`, etc.
- **Logs** — logs do app (se o app usa console.log ou um logger, eles sao capturados automaticamente)
