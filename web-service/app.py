"""web-service: interface web do inventário (o que o cliente vê no browser).

Não guarda dados: lê e altera os itens através da API do itens-service.
A página inicial é pública; a gestão (/gerir) pede login (Basic Auth),
que é verificado no auth-service.
"""
import os
from urllib.parse import urlparse

import requests
from flask import Flask, abort, redirect, render_template, request, url_for

ITENS_URL = os.getenv("ITENS_URL", "http://localhost:5002")
AUTH_URL = os.getenv("AUTH_URL", "http://localhost:5001")

def ler_formulario(form):
    """Converte os campos do formulário para os tipos que a API espera."""
    dados = {}
    if form.get("nome", "").strip():
        dados["nome"] = form["nome"].strip()
    if form.get("quantidade", "").strip():
        dados["quantidade"] = int(form["quantidade"])
    if form.get("preco", "").strip():
        dados["preco"] = float(form["preco"].replace(",", "."))
    return dados


def create_app():
    app = Flask(__name__)

    def pedir_login():
        return ("Login necessário", 401, {"WWW-Authenticate": 'Basic realm="Inventario"'})

    def credenciais_validas(auth):
        if auth is None:
            return False
        try:
            r = requests.post(
                f"{AUTH_URL}/api/verificar",
                json={"utilizador": auth.username, "password": auth.password},
                timeout=3,
            )
        except requests.RequestException:
            abort(503)
        return r.status_code == 200

    def listar_itens():
        r = requests.get(f"{ITENS_URL}/api/itens", timeout=3)
        r.raise_for_status()
        return r.json()

    def mesma_origem():
        """Proteção CSRF: os formulários só são aceites se vierem desta mesma página."""
        origem = request.headers.get("Origin")
        if origem and urlparse(origem).netloc != request.host:
            abort(403)

    def enviar(metodo, caminho, dados, sucesso):
        """Envia uma alteração à API do itens-service com o login do utilizador."""
        mesma_origem()
        auth = request.authorization
        if auth is None:
            return pedir_login()
        try:
            r = requests.request(metodo, f"{ITENS_URL}{caminho}", json=dados,
                                 auth=(auth.username, auth.password), timeout=3)
        except requests.RequestException:
            return redirect(url_for("gerir", msg="Serviço de itens indisponível"))
        if r.status_code == 401:
            return pedir_login()
        if r.status_code >= 400:
            erro = r.json().get("erro", "Erro") if r.content else "Erro"
            return redirect(url_for("gerir", msg=erro))
        return redirect(url_for("gerir", msg=sucesso))

    @app.get("/health")
    def health():
        return {"status": "ok", "servico": "web-service"}

    @app.get("/")
    def inicio():
        try:
            itens = listar_itens()
        except requests.RequestException:
            return render_template("inicio.html", itens=[], erro="Inventário indisponível"), 503
        return render_template("inicio.html", itens=itens, erro=None)

    @app.get("/gerir")
    def gerir():
        if not credenciais_validas(request.authorization):
            return pedir_login()
        try:
            itens = listar_itens()
        except requests.RequestException:
            itens = []
        return render_template("gerir.html", itens=itens, msg=request.args.get("msg"))

    @app.post("/gerir/criar")
    def criar():
        try:
            dados = ler_formulario(request.form)
        except ValueError:
            return redirect(url_for("gerir", msg="Quantidade ou preço inválidos"))
        return enviar("POST", "/api/itens", dados, "Item criado")

    @app.post("/gerir/<int:item_id>/alterar")
    def alterar(item_id):
        try:
            dados = ler_formulario(request.form)
        except ValueError:
            return redirect(url_for("gerir", msg="Quantidade ou preço inválidos"))
        return enviar("PUT", f"/api/itens/{item_id}", dados, "Item alterado")

    @app.post("/gerir/<int:item_id>/apagar")
    def apagar(item_id):
        return enviar("DELETE", f"/api/itens/{item_id}", None, "Item apagado")

    return app


app = create_app()

if __name__ == "__main__":
    app.run(port=5003)