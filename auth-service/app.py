"""auth-service: verifica o utilizador e a palavra-passe."""
import os

from flask import Flask, jsonify, request

UTILIZADOR = os.getenv("ADMIN_USER", "admin")
PASSWORD = os.getenv("ADMIN_PASSWORD", "admin123")


def create_app():
    app = Flask(__name__)
    app.json.ensure_ascii = False

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