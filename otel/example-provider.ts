/**
 * otel-provider.ts — Unnichat OpenTelemetry (v3 — anti-ruido + OTLP logs)
 *
 * O QUE MUDOU vs original:
 *
 * [STORAGE] Socket.IO polling filtrado — isso sozinho deve cortar ~80% dos 40GB/dia
 * [ROTAS]   Express ignoreLayersType elimina middleware da lista de endpoints
 * [ERROS]   HTTP responseHook marca 5xx como ERROR + helper traced() pra business logic
 * [TRACES]  Kafka hooks + eachBatch helper (otel-helpers.ts)
 * [LOGS]    Caminho B: SDK exporta via OTLP (desligar filelog/docker no agent)
 *           Pino habilitado pra injetar trace_id nos log records
 *
 * IMPORTANTE: Importar ANTES de qualquer outro modulo.
 *   import './otel-provider';
 */
import { NodeSDK } from '@opentelemetry/sdk-node';
import { getNodeAutoInstrumentations } from '@opentelemetry/auto-instrumentations-node';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-grpc';
import { OTLPMetricExporter } from '@opentelemetry/exporter-metrics-otlp-grpc';
import { OTLPLogExporter } from '@opentelemetry/exporter-logs-otlp-grpc';
import { PeriodicExportingMetricReader } from '@opentelemetry/sdk-metrics';
import { BatchLogRecordProcessor } from '@opentelemetry/sdk-logs';
import { RuntimeNodeInstrumentation } from '@opentelemetry/instrumentation-runtime-node';
import { resourceFromAttributes } from '@opentelemetry/resources';
import { ATTR_SERVICE_NAME } from '@opentelemetry/semantic-conventions';
import { diag, DiagConsoleLogger, DiagLogLevel } from '@opentelemetry/api';

if (process.env.OTEL_DEBUG === 'true') {
	diag.setLogger(new DiagConsoleLogger(), DiagLogLevel.DEBUG);
}

const endpoint = process.env.OTEL_EXPORTER_OTLP_ENDPOINT;
const kafkaClientId = process.env.KAFKA_CLIENT_ID || 'unnichat';

const sdk = new NodeSDK({
	resource: resourceFromAttributes({
		[ATTR_SERVICE_NAME]: process.env.OTEL_SERVICE_NAME || 'unnichat-server',
		'deployment.environment': process.env.OTEL_DEPLOYMENT_ENV || 'unknown',
		'service.version': process.env.APP_VERSION || 'unknown',
		'service.instance.id': process.env.HOSTNAME || 'unknown',
	}),

	traceExporter: new OTLPTraceExporter({ url: endpoint }),

	metricReader: new PeriodicExportingMetricReader({
		exporter: new OTLPMetricExporter({ url: endpoint }),
		exportIntervalMillis: 60_000,
	}),

	// ── CAMINHO B: Logs via OTLP direto ──────────────────────
	// O Pino instrumentado injeta trace_id/span_id no log record.
	// O SDK exporta via gRPC pro agent/collector.
	// Dozzle continua lendo do Docker API (nao e afetado).
	// DESLIGAR filelog/docker no agent-app pra evitar duplicacao.
	logRecordProcessors: [
		new BatchLogRecordProcessor(
			new OTLPLogExporter({ url: endpoint }),
			{
				maxQueueSize: 2048,
				maxExportBatchSize: 512,
				scheduledDelayMillis: 5000,
			}
		),
	],

	instrumentations: [
		getNodeAutoInstrumentations({
			// ══════════════════════════════════════════════════════
			//  DESABILITAR — gera ruido puro, zero valor
			// ══════════════════════════════════════════════════════
			'@opentelemetry/instrumentation-fs': { enabled: false },
			'@opentelemetry/instrumentation-dns': { enabled: false },
			'@opentelemetry/instrumentation-net': { enabled: false },
			'@opentelemetry/instrumentation-generic-pool': { enabled: false },
			'@opentelemetry/instrumentation-connect': { enabled: false },
			'@opentelemetry/instrumentation-winston': { enabled: false },
			'@opentelemetry/instrumentation-bunyan': { enabled: false },

			// ══════════════════════════════════════════════════════
			//  PINO — correlacao log <-> trace
			// ══════════════════════════════════════════════════════
			// A instrumentacao injeta trace_id e span_id nos log records
			// que o BatchLogRecordProcessor exporta via OTLP.
			// Dozzle NAO e afetado — ele le do Docker log driver.
			'@opentelemetry/instrumentation-pino': { enabled: true },

			// ══════════════════════════════════════════════════════
			//  EXPRESS — elimina middleware da lista de endpoints
			// ══════════════════════════════════════════════════════
			//
			// ANTES: SigNoz mostrava "middleware - query",
			//   "middleware - cors", "router - /api" como endpoints.
			// DEPOIS: So mostra rotas reais "GET /api/contacts/:id"
			'@opentelemetry/instrumentation-express': {
				ignoreLayersType: ['middleware', 'router'],
				ignoreLayers: [
					'query', 'expressInit', 'corsMiddleware',
					'jsonParser', 'urlencodedParser', 'serveStatic',
					'cookieParser', 'session', 'compression',
				],
				requestHook: (span, info) => {
					if (info.request.route?.path) {
						const method = info.request.method;
						const route = info.request.baseUrl + info.request.route.path;
						span.updateName(`${method} ${route}`);
						span.setAttribute('http.route', route);
					}
				},
			},

			// ══════════════════════════════════════════════════════
			//  HTTP — AQUI MATA OS 40GB/DIA
			// ══════════════════════════════════════════════════════
			//
			// Socket.IO polling com ~500 conexoes = ~1.8M traces/dia
			// Cada trace gera varios spans -> 30-40GB no ClickHouse.
			//
			// ignoreIncomingRequestHook impede a CRIACAO do trace
			// inteiro (nao e sampling, e filtro total).
			'@opentelemetry/instrumentation-http': {
				ignoreIncomingRequestHook: (req) => {
					const url = req.url || '';
					return (
						// ★ SOCKET.IO POLLING — o vilao dos 40GB/dia ★
						// Cada client faz GET /socket.io/?transport=polling
						// a cada ~25s. Com 500 conexoes = ~20 req/s de lixo.
						url.startsWith('/socket.io') ||

						// Health checks
						url === '/health' ||
						url === '/healthz' ||
						url === '/ready' ||
						url === '/ping' ||
						url.startsWith('/favicon')
					);
				},
				ignoreOutgoingRequestHook: (req) => {
					const path = req.path || '';
					return path === '/ping' || path === '/healthz';
				},
				// Marca 5xx como ERROR
				responseHook: (span, response) => {
					const statusCode =
						'statusCode' in response ? response.statusCode : undefined;
					if (statusCode && statusCode >= 500) {
						span.setStatus({
							code: 2, // SpanStatusCode.ERROR
							message: `HTTP ${statusCode}`,
						});
					}
				},
			},

			// ══════════════════════════════════════════════════════
			//  KAFKA
			// ══════════════════════════════════════════════════════
			'@opentelemetry/instrumentation-kafkajs': {
				producerHook: (span, info) => {
					span.setAttribute('messaging.client_id', kafkaClientId);
					span.setAttribute('messaging.system', 'kafka');
					if (info.message.key) {
						span.setAttribute('messaging.kafka.message.key', info.message.key.toString());
					}
					if (info.message.value) {
						span.setAttribute('messaging.message.body.size', info.message.value.length);
					}
				},
				consumerHook: (span, info) => {
					span.setAttribute('messaging.client_id', kafkaClientId);
					span.setAttribute('messaging.system', 'kafka');
					span.setAttribute('messaging.kafka.consumer.group', info.groupId || 'unknown');
					if (info.message.key) {
						span.setAttribute('messaging.kafka.message.key', info.message.key.toString());
					}
					if (info.message.value) {
						span.setAttribute('messaging.message.body.size', info.message.value.length);
					}
				},
			},

			// ══════════════════════════════════════════════════════
			//  MONGODB — filtrar internals do driver
			// ══════════════════════════════════════════════════════
			'@opentelemetry/instrumentation-mongodb': {
				enhancedDatabaseReporting: true,
				dbStatementSerializer: (operation, payload) => {
					const internalOps = [
						'hello', 'ismaster', 'buildinfo', 'getlasterror',
						'saslstart', 'saslcontinue', 'ping', 'endsessions',
					];
					if (internalOps.includes((operation || '').toLowerCase())) {
						return '';
					}
					try {
						return JSON.stringify(payload).slice(0, 1000);
					} catch {
						return operation;
					}
				},
			},

			// ══════════════════════════════════════════════════════
			//  POSTGRESQL
			// ══════════════════════════════════════════════════════
			'@opentelemetry/instrumentation-pg': {
				enhancedDatabaseReporting: true,
				responseHook: (span, response) => {
					if (response?.rowCount !== undefined) {
						span.setAttribute('db.response.rows', response.rowCount);
					}
				},
			},

			// ══════════════════════════════════════════════════════
			//  REDIS — filtrar ping/info/auth
			// ══════════════════════════════════════════════════════
			'@opentelemetry/instrumentation-ioredis': {
				dbStatementSerializer: (cmdName, cmdArgs) => {
					const noise = ['ping', 'info', 'select', 'auth', 'client'];
					if (noise.includes(cmdName.toLowerCase())) {
						return cmdName;
					}
					return `${cmdName} ${cmdArgs[0] || ''}`;
				},
			},
		}),

		new RuntimeNodeInstrumentation(),
	],
});

sdk.start();

const shutdown = () => {
	sdk.shutdown()
		.catch((err) => console.error('OTel SDK shutdown error', err))
		.finally(() => process.exit(0));
};

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
