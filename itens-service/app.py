"""itens-service: CRUD dos itens do inventário, guardados em SQLite."""
import os
import sqlite3

import requests
from flask import Flask, jsonify, request

AUTH_URL = os.getenv("AUTH_URL", "http://localhost:5001")

def configurar_tracing(app):
    if not os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT"):
        return
    from opentelemetry import trace
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
    from opentelemetry.instrumentation.flask import FlaskInstrumentor
    from opentelemetry.instrumentation.requests import RequestsInstrumentor
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor

    provider = TracerProvider()
    provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    trace.set_tracer_provider(provider)
    FlaskInstrumentor().instrument_app(app)
    RequestsInstrumentor().instrument()


def validar_item(dados, parcial=False):
    if not parcial and not dados.get("nome"):
        return "O campo 'nome' é obrigatório"
    if "nome" in dados and not dados["nome"]:
        return "O campo 'nome' não pode ficar vazio"
    if "quantidade" in dados and (not isinstance(dados["quantidade"], int) or dados["quantidade"] < 0):
        return "A quantidade tem de ser um número inteiro >= 0"
    if "preco" in dados and (not isinstance(dados["preco"], (int, float)) or dados["preco"] < 0):
        return "O preço tem de ser um número >= 0"
    return None


def create_app(db_path=None):
    app = Flask(__name__)
    app.json.ensure_ascii = False
    configurar_tracing(app)
    db = db_path or os.getenv("DB_PATH", "itens.db")

    def ligar():
        """Abre uma ligação à base de dados; cada linha é devolvida como dicionário."""
        con = sqlite3.connect(db, timeout=5)
        con.row_factory = sqlite3.Row
        return con

    with ligar() as con:
        con.execute(
            "CREATE TABLE IF NOT EXISTS itens ("
            "id INTEGER PRIMARY KEY AUTOINCREMENT, nome TEXT NOT NULL, "
            "quantidade INTEGER NOT NULL DEFAULT 0, preco REAL NOT NULL DEFAULT 0)"
        )

    def ler(item_id):
        with ligar() as con:
            linha = con.execute("SELECT * FROM itens WHERE id = ?", (item_id,)).fetchone()
        return dict(linha) if linha else None

    def autenticar():
        """Pergunta ao auth-service se as credenciais do pedido são válidas."""
        auth = request.authorization
        if auth is None:
            return jsonify(erro="Autenticação necessária"), 401
        try:
            r = requests.post(
                f"{AUTH_URL}/api/verificar",
                json={"utilizador": auth.username, "password": auth.password},
                timeout=3,
            )
        except requests.RequestException:
            return jsonify(erro="auth-service indisponível"), 503
        if r.status_code != 200:
            return jsonify(erro="Credenciais inválidas"), 401
        return None

    @app.get("/health")
    def health():
        return jsonify(status="ok", servico="itens-service")

    @app.get("/api/itens")
    def listar():
        with ligar() as con:
            linhas = con.execute("SELECT * FROM itens ORDER BY id").fetchall()
        return jsonify([dict(linha) for linha in linhas])

    @app.get("/api/itens/<int:item_id>")
    def obter(item_id):
        item = ler(item_id)
        if item is None:
            return jsonify(erro="Item não encontrado"), 404
        return jsonify(item)

    @app.post("/api/itens")
    def criar():
        erro_auth = autenticar()
        if erro_auth:
            return erro_auth
        dados = request.get_json(silent=True) or {}
        erro = validar_item(dados)
        if erro:
            return jsonify(erro=erro), 400
        with ligar() as con:
            cur = con.execute(
                "INSERT INTO itens (nome, quantidade, preco) VALUES (?, ?, ?)",
                (dados["nome"], dados.get("quantidade", 0), dados.get("preco", 0)),
            )
        return jsonify(ler(cur.lastrowid)), 201

    @app.put("/api/itens/<int:item_id>")
    def atualizar(item_id):
        erro_auth = autenticar()
        if erro_auth:
            return erro_auth
        item = ler(item_id)
        if item is None:
            return jsonify(erro="Item não encontrado"), 404
        dados = request.get_json(silent=True) or {}
        erro = validar_item(dados, parcial=True)
        if erro:
            return jsonify(erro=erro), 400
        for campo in ("nome", "quantidade", "preco"):
            if campo in dados:
                item[campo] = dados[campo]
        with ligar() as con:
            con.execute(
                "UPDATE itens SET nome = ?, quantidade = ?, preco = ? WHERE id = ?",
                (item["nome"], item["quantidade"], item["preco"], item_id),
            )
        return jsonify(item)

    @app.delete("/api/itens/<int:item_id>")
    def apagar(item_id):
        erro_auth = autenticar()
        if erro_auth:
            return erro_auth
        with ligar() as con:
            cur = con.execute("DELETE FROM itens WHERE id = ?", (item_id,))
        if cur.rowcount == 0:
            return jsonify(erro="Item não encontrado"), 404
        return "", 204

    return app


app = create_app()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5002, debug=True)