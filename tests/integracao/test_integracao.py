import os

import requests

URL = os.getenv("BASE_URL", "http://localhost")
CRED = (os.getenv("ADMIN_USER", "admin"), os.getenv("ADMIN_PASSWORD", "admin123"))


def test_servicos_ativos():
    assert requests.get(f"{URL}/health/auth", timeout=5).status_code == 200
    assert requests.get(f"{URL}/health/itens", timeout=5).status_code == 200


def test_crud_completo():
    # criar
    r = requests.post(f"{URL}/api/itens", json={"nome": "Router", "quantidade": 2, "preco": 59.9},
                      auth=CRED, timeout=5)
    assert r.status_code == 201
    item_id = r.json()["id"]
    # consultar
    assert requests.get(f"{URL}/api/itens/{item_id}", timeout=5).json()["nome"] == "Router"
    # alterar
    r = requests.put(f"{URL}/api/itens/{item_id}", json={"quantidade": 10}, auth=CRED, timeout=5)
    assert r.json()["quantidade"] == 10
    # apagar
    assert requests.delete(f"{URL}/api/itens/{item_id}", auth=CRED, timeout=5).status_code == 204
    assert requests.get(f"{URL}/api/itens/{item_id}", timeout=5).status_code == 404


def test_credenciais_erradas_rejeitadas():
    r = requests.post(f"{URL}/api/itens", json={"nome": "X"}, auth=("admin", "errada"), timeout=5)
    assert r.status_code == 401


def test_auth_service_nao_exposto():
    r = requests.post(f"{URL}/api/verificar", json={}, timeout=5)
    assert r.status_code == 404