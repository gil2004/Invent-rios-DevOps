import pytest
import requests
from app import AUTH_URL, create_app, validar_item

VERIFICAR = f"{AUTH_URL}/api/verificar"
CRED = ("admin", "admin123")


@pytest.fixture
def client():
    return create_app().test_client()


@pytest.fixture
def auth_ok(requests_mock):
    requests_mock.post(VERIFICAR, json={"valido": True})


def criar(client, **dados):
    return client.post("/api/itens", json=dados, auth=CRED)


@pytest.mark.parametrize("dados, valido", [
    ({"nome": "Portátil", "quantidade": 3, "preco": 899.9}, True),
    ({"quantidade": 3}, False),
    ({"nome": "X", "quantidade": -1}, False),
    ({"nome": "X", "quantidade": 1.5}, False),
    ({"nome": "X", "preco": -2}, False),
])
def test_validar_item(dados, valido):
    assert (validar_item(dados) is None) == valido


def test_health(client):
    assert client.get("/health").get_json()["status"] == "ok"


def test_listar_vazio(client):
    assert client.get("/api/itens").get_json() == []


def test_item_inexistente(client):
    assert client.get("/api/itens/99").status_code == 404


def test_criar_e_obter(client, auth_ok):
    r = criar(client, nome="Portátil", quantidade=3, preco=899.9)
    assert r.status_code == 201
    assert client.get("/api/itens/1").get_json()["nome"] == "Portátil"


def test_criar_dados_invalidos(client, auth_ok):
    assert criar(client, quantidade=3).status_code == 400


def test_atualizar(client, auth_ok):
    criar(client, nome="Monitor", quantidade=2)
    r = client.put("/api/itens/1", json={"quantidade": 5}, auth=CRED)
    assert r.status_code == 200
    assert r.get_json()["quantidade"] == 5


def test_atualizar_inexistente(client, auth_ok):
    assert client.put("/api/itens/9", json={"nome": "X"}, auth=CRED).status_code == 404


def test_apagar(client, auth_ok):
    criar(client, nome="Teclado")
    assert client.delete("/api/itens/1", auth=CRED).status_code == 204
    assert client.get("/api/itens/1").status_code == 404


def test_apagar_inexistente(client, auth_ok):
    assert client.delete("/api/itens/9", auth=CRED).status_code == 404


def test_sem_credenciais(client):
    assert client.post("/api/itens", json={"nome": "X"}).status_code == 401


def test_credenciais_erradas(client, requests_mock):
    requests_mock.post(VERIFICAR, status_code=401, json={"valido": False})
    assert criar(client, nome="X").status_code == 401


def test_auth_service_indisponivel(client, requests_mock):
    requests_mock.post(VERIFICAR, exc=requests.ConnectionError)
    assert criar(client, nome="X").status_code == 503