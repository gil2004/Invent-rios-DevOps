import os
import time
from datetime import datetime, timedelta, timezone

import requests

URL = os.getenv("BASE_URL", "http://localhost")
JAEGER_URL = os.getenv("JAEGER_URL", "http://localhost:16686")
CRED = (os.getenv("ADMIN_USER", "admin"), os.getenv("ADMIN_PASSWORD", "admin123"))


def test_health():
    assert requests.get(f"{URL}/health/auth", timeout=5).json()["status"] == "ok"
    assert requests.get(f"{URL}/health/itens", timeout=5).json()["status"] == "ok"


def test_listar_itens():
    assert requests.get(f"{URL}/api/itens", timeout=5).status_code == 200


def test_criar_e_apagar_item():
    r = requests.post(f"{URL}/api/itens", json={"nome": "Smoke"}, auth=CRED, timeout=5)
    assert r.status_code == 201
    assert requests.delete(f"{URL}/api/itens/{r.json()['id']}", auth=CRED, timeout=5).status_code == 204


def test_trace_chega_ao_jaeger():
    r = requests.post(f"{URL}/api/itens", json={"nome": "Trace"}, auth=CRED, timeout=5)
    assert r.status_code == 201

    for _ in range(15):  
        time.sleep(2)
        agora = datetime.now(timezone.utc)
        resposta = requests.get(
            f"{JAEGER_URL}/api/v3/traces",
            params={
                "query.service_name": "itens-service",
                "query.start_time_min": (agora - timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "query.start_time_max": agora.strftime("%Y-%m-%dT%H:%M:%SZ"),
            },
            timeout=5,
        )
        if resposta.status_code != 200:
            continue
        servicos = set()
        for rs in resposta.json()["result"]["resourceSpans"]:
            for attr in rs["resource"]["attributes"]:
                if attr["key"] == "service.name":
                    servicos.add(attr["value"]["stringValue"])
        if {"itens-service", "auth-service"} <= servicos:
            return
    raise AssertionError("Os dois serviços não enviaram traces ao Jaeger")