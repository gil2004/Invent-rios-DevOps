"""itens-service: CRUD dos itens do inventário."""
import os

import requests
from flask import Flask, jsonify, request

AUTH_URL = os.getenv("AUTH_URL", "http://localhost:5001")


def validar_item(dados, parcial=False):
    """Devolve uma mensagem de erro, ou None se os dados forem válidos."""
    if not parcial and not dados.get("nome"):
        return "O campo 'nome' é obrigatório"
    if "nome" in dados and not dados["nome"]:
        return "O campo 'nome' não pode ficar vazio"
    if "quantidade" in dados and (not isinstance(dados["quantidade"], int) or dados["quantidade"] < 0):
        return "A quantidade tem de ser um número inteiro >= 0"
    if "preco" in dados and (not isinstance(dados["preco"], (int, float)) or dados["preco"] < 0):
        return "O preço tem de ser um número >= 0"
    return None


def create_app():
    app = Flask(__name__)
    app.json.ensure_ascii = False
    itens = {}
    proximo_id = [1]

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
        return jsonify(list(itens.values()))

    @app.get("/api/itens/<int:item_id>")
    def obter(item_id):
        item = itens.get(item_id)
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
        item = {
            "id": proximo_id[0],
            "nome": dados["nome"],
            "quantidade": dados.get("quantidade", 0),
            "preco": dados.get("preco", 0),
        }
        itens[item["id"]] = item
        proximo_id[0] += 1
        return jsonify(item), 201

    @app.put("/api/itens/<int:item_id>")
    def atualizar(item_id):
        erro_auth = autenticar()
        if erro_auth:
            return erro_auth
        item = itens.get(item_id)
        if item is None:
            return jsonify(erro="Item não encontrado"), 404
        dados = request.get_json(silent=True) or {}
        erro = validar_item(dados, parcial=True)
        if erro:
            return jsonify(erro=erro), 400
        for campo in ("nome", "quantidade", "preco"):
            if campo in dados:
                item[campo] = dados[campo]
        return jsonify(item)

    @app.delete("/api/itens/<int:item_id>")
    def apagar(item_id):
        erro_auth = autenticar()
        if erro_auth:
            return erro_auth
        if itens.pop(item_id, None) is None:
            return jsonify(erro="Item não encontrado"), 404
        return "", 204

    return app


app = create_app()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5002, debug=True)