import os

from flask import Flask, jsonify, request

UTILIZADOR = os.getenv("ADMIN_USER", "admin")
PASSWORD = os.getenv("ADMIN_PASSWORD", "admin123")

def configurar_tracing(app):
    if not os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT"):
        return
    from opentelemetry import trace
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
    from opentelemetry.instrumentation.flask import FlaskInstrumentor
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor

    provider = TracerProvider()
    provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    trace.set_tracer_provider(provider)
    FlaskInstrumentor().instrument_app(app)


def create_app():
    app = Flask(__name__)
    app.json.ensure_ascii = False
    configurar_tracing(app)

    @app.get("/health")
    def health():
        return jsonify(status="ok", servico="auth-service")

    @app.post("/api/verificar")
    def verificar():
        dados = request.get_json(silent=True) or {}
        if dados.get("utilizador") == UTILIZADOR and dados.get("password") == PASSWORD:
            return jsonify(valido=True)
        return jsonify(valido=False), 401

    return app


app = create_app()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5001, debug=True)