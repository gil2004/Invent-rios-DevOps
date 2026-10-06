import pytest
from app import create_app


@pytest.fixture
def client():
    return create_app().test_client()


def test_health(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.get_json()["status"] == "ok"


def test_credenciais_corretas(client):
    r = client.post("/api/verificar", json={"utilizador": "admin", "password": "admin123"})
    assert r.status_code == 200
    assert r.get_json()["valido"] is True


@pytest.mark.parametrize("dados", [
    {"utilizador": "admin", "password": "errada"},
    {"utilizador": "outro", "password": "admin123"},
    {},
])
def test_credenciais_erradas(client, dados):
    r = client.post("/api/verificar", json=dados)
    assert r.status_code == 401
    assert r.get_json()["valido"] is False