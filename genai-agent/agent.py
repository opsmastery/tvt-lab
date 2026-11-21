"""Synthetic coding-agent telemetry for tvt-lab (tvt S7).

Emits what an AI coding agent instrumented with the OpenTelemetry GenAI
conventions sends, with every content flag on, over OTLP/HTTP to the lab's
OTel Collector (otelcol/config.yaml). Everything is made up: there is no
real agent, model or prompt, and all text is generated filler.

Per interaction (one every INTERACTION_SECONDS, sessions of ~20):
  spans:   interaction > llm_request (1-3) and tool (1-4) spans; tool spans
           carry gen_ai.operation.name=execute_tool, gen_ai.tool.name,
           gen_ai.tool.call.id, success and tool_parameters (content).
           About one interaction in 40 runs rollback_deploy, which succeeds:
           a consequential action, so a record.
  logs:    tool_decision and tool_result per tool (tool_result repeats the
           tool_parameters value: one value carried twice), api_request per
           llm_request.
  metrics: coding_agent.token.usage and coding_agent.cost.usage, delta
           counters with session.id and user.email.

Ground truth (ground-truth.yaml genai_agent:): content attributes are unread
(cap them), session.id on the delta counters is unread (aggregate it in an
ordered pipeline), successful tool spans are records (keep the span), and
api_request logs are unread (drop them).
"""

import os
import random
import string
import time
import uuid

from opentelemetry import metrics, trace
from opentelemetry._logs import SeverityNumber, set_logger_provider
from opentelemetry.exporter.otlp.proto.http._log_exporter import OTLPLogExporter
from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk._logs import LoggerProvider, LogRecord
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.sdk.metrics import Counter, MeterProvider
from opentelemetry.sdk.metrics.export import AggregationTemporality, PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace import SpanKind

ENDPOINT = os.environ.get("OTLP_ENDPOINT", "http://otelcol:4318").rstrip("/")
INTERACTION_SECONDS = float(os.environ.get("INTERACTION_SECONDS", "30"))
SESSION_LENGTH = int(os.environ.get("SESSION_LENGTH", "20"))
USERS = [f"dev{n:02d}@example.com" for n in range(1, 7)]
MODELS = ["lab-model-large", "lab-model-small"]
TOOLS = ["read_file", "edit_file", "run_tests", "search_code", "list_dir"]

resource = Resource.create({"service.name": "coding-agent", "service.version": "0.0.0-lab"})

tracer_provider = TracerProvider(resource=resource)
tracer_provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint=f"{ENDPOINT}/v1/traces")))
trace.set_tracer_provider(tracer_provider)
tracer = trace.get_tracer("tvt-lab-genai-agent")

logger_provider = LoggerProvider(resource=resource)
logger_provider.add_log_record_processor(BatchLogRecordProcessor(OTLPLogExporter(endpoint=f"{ENDPOINT}/v1/logs")))
set_logger_provider(logger_provider)
otel_logger = logger_provider.get_logger("tvt-lab-genai-agent")

reader = PeriodicExportingMetricReader(
    OTLPMetricExporter(endpoint=f"{ENDPOINT}/v1/metrics",
                       preferred_temporality={Counter: AggregationTemporality.DELTA}),
    export_interval_millis=15000)
metrics.set_meter_provider(MeterProvider(resource=resource, metric_readers=[reader]))
meter = metrics.get_meter("tvt-lab-genai-agent")
tokens = meter.create_counter("coding_agent.token.usage", unit="{token}", description="Tokens used, by type and model.")
cost = meter.create_counter("coding_agent.cost.usage", unit="USD", description="Estimated cost of model calls.")
# S10 item 1 seed: model API calls by status code (an int, as semantic
# conventions have it). The CodingAgentAPIErrors alert reads the code only
# by class (=~"5.."), so tvt should bucket it in the collector.
api_requests = meter.create_counter("coding_agent.api.requests", unit="{request}", description="Model API calls, by HTTP status code.")
STATUS_CODES = [200] * 90 + [400, 401, 429, 429, 500, 502, 503, 503, 529, 529]


def filler(min_kb, max_kb):
    """Generated text standing in for prompts, file contents and tool output."""
    n = random.randint(min_kb * 1024, max_kb * 1024)
    words = ("".join(random.choices(string.ascii_lowercase, k=random.randint(2, 9))) for _ in range(n // 6))
    return " ".join(words)[:n]


SEVERITIES = {"DEBUG": SeverityNumber.DEBUG, "INFO": SeverityNumber.INFO, "WARN": SeverityNumber.WARN}


def emit_log(event, attrs, body="", severity="INFO"):
    otel_logger.emit(LogRecord(
        timestamp=time.time_ns(), severity_number=SEVERITIES[severity], severity_text=severity, resource=resource,
        body=body or event, attributes={"event.name": event, **attrs}))


def interaction(session_id, user, seq):
    common = {"session.id": session_id, "user.email": user}
    with tracer.start_as_current_span("interaction", kind=SpanKind.INTERNAL, attributes={
            **common, "interaction.sequence": seq, "user_prompt": filler(1, 3)}):
        for _ in range(random.randint(1, 3)):
            model = random.choice(MODELS)
            tin, tout = random.randint(800, 12000), random.randint(100, 2500)
            dollars = (tin * 3 + tout * 15) / 1_000_000 * (1 if model.endswith("large") else 0.2)
            with tracer.start_as_current_span("llm_request", kind=SpanKind.CLIENT, attributes={
                    **common, "gen_ai.operation.name": "chat", "gen_ai.request.model": model,
                    "gen_ai.usage.input_tokens": tin, "gen_ai.usage.output_tokens": tout,
                    "gen_ai.input.messages": filler(2, 6), "gen_ai.output.messages": filler(1, 2)}):
                time.sleep(random.uniform(0.05, 0.3))
            # S10 item 3 seed: streamed chunks at DEBUG, in-line levels in one
            # stream (severity is structured metadata, not a label). Nothing
            # reads them; about one in 50 mentions an exception, which the
            # error-pattern guard keeps hot.
            for chunk in range(random.randint(2, 5)):
                body = filler(0, 1) or "chunk"
                if random.random() < 1 / 50:
                    body = "stream reset by peer, retrying after exception: ConnectionResetError"
                emit_log("model_stream", {**common, "model": model, "chunk": chunk}, body=body, severity="DEBUG")
            status = random.choice(STATUS_CODES)
            api_requests.add(1, {"http.response.status_code": status})
            if status in (429, 529):
                emit_log("rate_limited", {**common, "model": model, "status": status},
                         body=f"model call rate limited ({status}), backing off", severity="WARN")
            tokens.add(tin, {**common, "type": "input", "model": model})
            tokens.add(tout, {**common, "type": "output", "model": model})
            cost.add(dollars, {**common, "model": model})
            emit_log("api_request", {**common, "model": model, "input_tokens": tin, "output_tokens": tout,
                                     "cost_usd": round(dollars, 6), "duration_ms": random.randint(400, 9000)})
        tools = random.sample(TOOLS, random.randint(1, 4))
        if random.random() < 1 / 40:
            tools.append("rollback_deploy")
        for tool in tools:
            call_id = uuid.uuid4().hex[:12]
            params = filler(1, 6)
            ok = tool == "rollback_deploy" or random.random() > 0.05
            emit_log("tool_decision", {**common, "tool_name": tool, "decision": "accept", "source": "config"})
            with tracer.start_as_current_span(f"execute_tool {tool}", kind=SpanKind.INTERNAL, attributes={
                    **common, "gen_ai.operation.name": "execute_tool", "gen_ai.tool.name": tool,
                    "gen_ai.tool.call.id": call_id, "success": ok, "tool_parameters": params}) as span:
                time.sleep(random.uniform(0.01, 0.2))
                if not ok:
                    span.set_status(trace.Status(trace.StatusCode.ERROR))
            emit_log("tool_result", {**common, "tool_name": tool, "gen_ai.tool.call.id": call_id,
                                     "success": ok, "duration_ms": random.randint(5, 900),
                                     "tool_parameters": params})


def main():
    print(f"genai-agent: synthetic telemetry to {ENDPOINT} every {INTERACTION_SECONDS}s", flush=True)
    while True:
        session_id, user = str(uuid.uuid4()), random.choice(USERS)
        for seq in range(SESSION_LENGTH):
            try:
                interaction(session_id, user, seq)
            except Exception as exc:  # the Collector may not be up yet
                print(f"genai-agent: {exc}", flush=True)
            time.sleep(INTERACTION_SECONDS)


if __name__ == "__main__":
    main()
