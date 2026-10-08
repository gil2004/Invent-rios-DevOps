# Makefile - Projeto Final DevOps (inventario-devops)
# Do zero ate PRD: make all   |   Limpeza total: make clean

VENV := venv
PY   := "$(CURDIR)/$(VENV)/bin/python"
URL  := http://localhost
CRED := admin:admin123

.PHONY: all setup test stg prd demo clean

all: setup test stg prd demo

setup:
	python3 -m venv $(VENV)
	$(PY) -m pip install -r requirements.txt

test:
	$(PY) -m ruff check .
	cd auth-service && $(PY) -m pytest -v --cov=app
	cd itens-service && $(PY) -m pytest -v --cov=app

stg:
	docker compose build
	docker compose up -d
	sleep 10
	$(PY) -m pytest -v tests/integracao

prd:
	docker compose pull
	docker compose up -d --no-build
	sleep 10
	docker compose ps
	$(PY) -m pytest -v tests/smoke

demo:
	@echo "--- Criar item (com login)"
	@ID=$$(curl -s -u $(CRED) -X POST $(URL)/api/itens -H "Content-Type: application/json" -d '{"nome":"Portatil","quantidade":3,"preco":899.9}' | tee /dev/stderr | python3 -c 'import sys, json; print(json.load(sys.stdin)["id"])'); \
	echo; echo "--- Listar itens (sem login)"; curl -s $(URL)/api/itens; echo; \
	echo "--- Alterar a quantidade do item $$ID"; curl -s -u $(CRED) -X PUT $(URL)/api/itens/$$ID -H "Content-Type: application/json" -d '{"quantidade":5}'; echo; \
	echo "--- Apagar o item $$ID"; curl -s -o /dev/null -w "HTTP %{http_code}\n" -u $(CRED) -X DELETE $(URL)/api/itens/$$ID
	@echo "--- Tentativa com password errada"
	@curl -s -u admin:errada -X POST $(URL)/api/itens -H "Content-Type: application/json" -d '{"nome":"X"}'; echo

clean:
	docker compose down --rmi all --volumes --remove-orphans
	docker builder prune -af
	rm -rf $(VENV) .pytest_cache .ruff_cache .coverage
	find . -name "__pycache__" -type d -prune -exec rm -rf {} +
	find . -name ".pytest_cache" -type d -prune -exec rm -rf {} +
	find . -name ".coverage" -delete
	find . -name "*.db" -delete
	@echo "--- Verificacao: nada do projeto deve aparecer abaixo"
	-docker ps -a --filter "name=inventario-devops"
	-docker images | grep -E "inventario|nginx|jaeger" || echo "sem imagens do projeto"
	-docker volume ls | grep inventario || echo "sem volumes do projeto"
	-docker network ls | grep inventario || echo "sem redes do projeto"