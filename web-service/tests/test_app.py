import pytest
from app import AUTH_URL, ITENS_URL, create_app

VERIFICAR = f"{AUTH_URL}/api/verificar"
ITENS = f"{ITENS_URL}/api/itens"
CRED = ("admin", "admin123")
LISTA = [{"id": 1, "nome": "Portátil", "quantidade": 3, "preco": 899.9}]


@pytest.fixture
def client():
    return create_app().test_client()


@pytest.fixture
def auth_ok(requests_mock):
    requests_mock.post(VERIFICAR, json={"valido": True})


def test_health(client):
    assert client.get("/health").get_json()["status"] == "ok"


def test_pagina_inicial_mostra_itens(client, requests_mock):
    requests_mock.get(ITENS, json=LISTA)
    r = client.get("/")
    assert r.status_code == 200
    assert "Portátil" in r.get_data(as_text=True)


def test_pagina_inicial_sem_itens_service(client, requests_mock):
    requests_mock.get(ITENS, status_code=500)
    assert client.get("/").status_code == 503


def test_gerir_pede_login(client):
    r = client.get("/gerir")
    assert r.status_code == 401
    assert "Basic" in r.headers["WWW-Authenticate"]


def test_gerir_login_errado(client, requests_mock):
    requests_mock.post(VERIFICAR, status_code=401, json={"valido": False})
    assert client.get("/gerir", auth=("admin", "errada")).status_code == 401


def test_gerir_com_login(client, requests_mock, auth_ok):
    requests_mock.get(ITENS, json=LISTA)
    r = client.get("/gerir", auth=CRED)
    assert r.status_code == 200
    assert "Novo item" in r.get_data(as_text=True)


def test_criar_envia_para_a_api(client, requests_mock):
    api = requests_mock.post(ITENS, status_code=201, json=LISTA[0])
    r = client.post("/gerir/criar", data={"nome": "Portátil", "quantidade": "3", "preco": "899,9"}, auth=CRED)
    assert r.status_code == 302
    assert api.last_request.json() == {"nome": "Portátil", "quantidade": 3, "preco": 899.9}


def test_criar_valores_invalidos(client):
    r = client.post("/gerir/criar", data={"nome": "X", "quantidade": "abc"}, auth=CRED)
    assert "inv%C3%A1lidos" in r.headers["Location"]


def test_alterar_e_apagar(client, requests_mock):
    put = requests_mock.put(f"{ITENS}/1", json=LISTA[0])
    delete = requests_mock.delete(f"{ITENS}/1", status_code=204)
    assert client.post("/gerir/1/alterar", data={"quantidade": "5"}, auth=CRED).status_code == 302
    assert put.last_request.json() == {"quantidade": 5}
    assert client.post("/gerir/1/apagar", auth=CRED).status_code == 302
    assert delete.called


def test_formulario_de_outro_site_recusado(client):
    r = client.post("/gerir/1/apagar", auth=CRED, headers={"Origin": "https://site-malicioso.com"})
    assert r.status_code == 403