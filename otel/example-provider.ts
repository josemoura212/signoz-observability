/**
 * OPCIONAL - Code-Based Setup
 *
 * Para auto-instrumentacao zero-code, basta:
 * 1. npm install @opentelemetry/api @opentelemetry/auto-instrumentations-node
 * 2. Definir as env vars no docker-compose do app:
 *    - NODE_OPTIONS="--require @opentelemetry/auto-instrumentations-node/register"
 *    - OTEL_EXPORTER_OTLP_ENDPOINT="http://<agent-ip>:4318"
 *    - OTEL_SERVICE_NAME="meu-servico"
 *    - OTEL_TRACES_EXPORTER="otlp"
 *    - OTEL_NODE_RESOURCE_DETECTORS="env,host,os"
 *
 * Este arquivo e para setup avancado com controle manual do SDK.
 * Ref: https://signoz.io/docs/instrumentation/javascript/opentelemetry-nodejs/
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

const sdk = new NodeSDK({
	resource: resourceFromAttributes({
		[ATTR_SERVICE_NAME]: process.env.OTEL_SERVICE_NAME || 'unknown-service',
	}),
	traceExporter: new OTLPTraceExporter(),
	metricReader: new PeriodicExportingMetricReader({
		exporter: new OTLPMetricExporter(),
		exportIntervalMillis: 60000,
	}),
	logRecordProcessors: [new BatchLogRecordProcessor(new OTLPLogExporter())],
	instrumentations: [
		getNodeAutoInstrumentations({
			'@opentelemetry/instrumentation-fs': { enabled: false },
			'@opentelemetry/instrumentation-dns': { enabled: false },
			'@opentelemetry/instrumentation-net': { enabled: false },
			'@opentelemetry/instrumentation-winston': { enabled: false },
			'@opentelemetry/instrumentation-bunyan': { enabled: false },
			'@opentelemetry/instrumentation-pino': { enabled: true },
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
