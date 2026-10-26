import os
from pathlib import Path

import requests

URL = os.getenv("BASE_URL", "https://localhost")
CRED = (os.getenv("ADMIN_USER", "admin"), os.getenv("ADMIN_PASSWORD", "admin123"))

# Confiar no certificado self-signed do nginx (equivalente ao curl --cacert)
CERT = Path(__file__).resolve().parents[2] / "nginx" / "certs" / "nginx.crt"
os.environ.setdefault("REQUESTS_CA_BUNDLE", str(CERT))


def test_health():
    assert requests.get(f"{URL}/health/auth", timeout=5).json()["status"] == "ok"
    assert requests.get(f"{URL}/health/itens", timeout=5).json()["status"] == "ok"


def test_listar_itens():
    assert requests.get(f"{URL}/api/itens", timeout=5).status_code == 200


def test_criar_e_apagar_item():
    r = requests.post(f"{URL}/api/itens", json={"nome": "Smoke"}, auth=CRED, timeout=5)
    assert r.status_code == 201
    assert requests.delete(f"{URL}/api/itens/{r.json()['id']}", auth=CRED, timeout=5).status_code == 204