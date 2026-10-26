# Projeto Final DevOps — inventario-devops
# Ciclo DevOps por ambiente: build_ / start_ / stop_ / clean_ para DEV, STG e PRD.
#   DEV: desenvolver e testar o código (com OpenTelemetry + Jaeger)
#   STG: build das imagens de PRD e testes de integração para as validar
#   PRD: pull das imagens já validadas (sem build) e subir no Kubernetes
# A limpeza só toca no que é deste projeto (não mexe noutros containers do PC).

SHELL       := /bin/bash
.SHELLFLAGS := -o pipefail -c

VENV       := venv
PY         := "$(CURDIR)/$(VENV)/bin/python"
DEV        := docker compose -f docker-compose.dev.yml
K          := microk8s kubectl
TAG        ?= latest
export TAG
IMAGENS    := ghcr.io/gil2004/inventario-auth ghcr.io/gil2004/inventario-itens
CERT       := nginx/certs/nginx.crt
REPORTS    := reports
DEV_URL    := http://localhost:5002
JAEGER_URL := http://localhost:16686
STG_URL    := https://localhost
PRD_URL    := https://localhost:30443
CRED       := admin:admin123
JSON       := -H "Content-Type: application/json"

.PHONY: all build_dev test_dev start_dev dev_status stop_dev clean_dev jaeger_dashboard jaeger_erro \
        cert build_stg start_stg stg_status stop_stg clean_stg \
        k8s_start k8s_stop build_prd start_prd prd_status stop_prd clean_prd prd_demo prd_ha prd_scale clean

# Ciclo completo: DEV -> STG -> PRD (cada ambiente é parado antes do seguinte para poupar recursos)
all: build_dev test_dev start_dev stop_dev build_stg start_stg stop_stg build_prd start_prd prd_demo

## DEV ##

# DEV build: venv com requirements-dev e imagens de DEV (com OpenTelemetry)
build_dev:
	python3 -m venv $(VENV)
	$(PY) -m pip install -r requirements-dev.txt
	$(DEV) build

# DEV testes de código e segurança (sem ambiente a correr): lint, unitários, bandit, pip-audit
test_dev:
	@mkdir -p $(REPORTS)
	$(PY) -m ruff check . | tee $(REPORTS)/dev-lint.txt
	cd auth-service && $(PY) -m pytest -v --cov=app tests | tee ../$(REPORTS)/dev-unitarios-auth.txt
	cd itens-service && $(PY) -m pytest -v --cov=app tests | tee ../$(REPORTS)/dev-unitarios-itens.txt
	$(VENV)/bin/bandit -r auth-service itens-service -x auth-service/tests,itens-service/tests | tee $(REPORTS)/seguranca-bandit.txt
	$(VENV)/bin/pip-audit -r requirements-prd.txt | tee $(REPORTS)/seguranca-pip-audit.txt

# DEV start: serviços + Jaeger, e teste de que os traces chegam ao Jaeger
start_dev:
	$(DEV) up -d
	sleep 10
	@mkdir -p $(REPORTS)
	$(PY) -m pytest -v tests/dev | tee $(REPORTS)/dev-tracing.txt
	@echo ""
	@$(DEV) ps
	@echo abrir API: $(DEV_URL)/api/itens
	@echo abrir Jaeger: $(JAEGER_URL)

# Estado do DEV
dev_status:
	$(DEV) ps

# DEV stop
stop_dev:
	$(DEV) down

# DEV clean: containers, imagens e volume de DEV, venv e caches
clean_dev:
	$(DEV) down --rmi all --volumes --remove-orphans
	rm -rf $(VENV) .pytest_cache .ruff_cache .coverage
	find . -name "__pycache__" -type d -prune -exec rm -rf {} +
	find . -name ".pytest_cache" -type d -prune -exec rm -rf {} +
	find . -name ".coverage" -delete
	find . -name "*.db" -delete

# Abrir a UI do Jaeger (DEV) no browser
jaeger_dashboard:
	@x-www-browser $(JAEGER_URL) > /dev/null 2>&1 &

# Provocar um erro (auth-service em baixo) para encontrar a causa raiz no Jaeger
jaeger_erro:
	$(DEV) stop auth-service
	@echo "--- Criar item com o auth-service em baixo (esperado: 503)"
	-@curl -s -w "\nHTTP %{http_code}\n" -u $(CRED) $(JSON) -d '{"nome":"Erro"}' $(DEV_URL)/api/itens
	$(DEV) start auth-service
	@echo "--- Abrir $(JAEGER_URL), service itens-service: o trace com 503 mostra a causa raiz"

## STG (Docker Compose) ##

# Certificado self-signed para o HTTPS (só é gerado se ainda não existir)
cert:
	@test -f $(CERT) || ( mkdir -p nginx/certs && openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
		-keyout nginx/certs/nginx.key -out $(CERT) \
		-subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" )

# STG build: imagens de PRD (só requirements-prd) com a tag $(TAG)
build_stg: cert
	docker compose build

# STG start: sobe o ambiente de PRD em Compose e valida com os testes de integração
start_stg: cert
	docker compose up -d
	sleep 10
	@mkdir -p $(REPORTS)
	$(PY) -m pytest -v tests/integracao | tee $(REPORTS)/stg-integracao.txt
	@echo ""
	@docker compose ps
	@echo abrir API: $(STG_URL)/api/itens

# Estado do STG: containers e health dos serviços
stg_status:
	docker compose ps
	@curl -s --cacert $(CERT) $(STG_URL)/health/itens; echo
	@curl -s --cacert $(CERT) $(STG_URL)/health/auth; echo

# STG stop
stop_stg:
	docker compose down

# STG clean: containers, imagens, volume e rede de STG
clean_stg:
	docker compose down --rmi all --volumes --remove-orphans

## PRD (Kubernetes / MicroK8s) ##

# Ligar o Kubernetes com os addons de que o PRD precisa (DNS e disco)
k8s_start:
	microk8s start
	microk8s status --wait-ready
	microk8s enable dns
	microk8s enable hostpath-storage
	$(K) wait --for=condition=available deployment --all -n kube-system --timeout=180s

# Desligar o Kubernetes (liberta memória)
k8s_stop:
	microk8s stop || (sleep 15 && microk8s stop)

# PRD build: não há build da app; prepara o cluster e faz pull das imagens validadas em STG
build_prd: cert k8s_start
	for img in $(IMAGENS); do microk8s ctr image pull $$img:$(TAG); done

# PRD start: configuração + certificado no cluster, deploy da tag $(TAG) e smoke tests
start_prd: cert k8s_start
	$(K) create configmap nginx-conf --from-file=default.conf=nginx/nginx.conf --dry-run=client -o yaml | $(K) apply -f -
	$(K) create secret tls nginx-tls --cert=$(CERT) --key=nginx/certs/nginx.key --dry-run=client -o yaml | $(K) apply -f -
	sed "s/:latest/:$(TAG)/" k8s/prd.yml | $(K) apply -f -
	$(K) rollout restart deployment nginx
	$(K) wait --for=condition=available deployment --all --timeout=300s || ($(K) get pods; $(K) describe pods | grep -A5 "Events:"; exit 1)
	@mkdir -p $(REPORTS)
	BASE_URL=$(PRD_URL) $(PY) -m pytest -v tests/smoke | tee $(REPORTS)/prd-smoke.txt
	@echo ""
	@$(K) get pods
	@echo abrir API: $(PRD_URL)/api/itens

# Estado do PRD: pods, services e deployments
prd_status:
	$(K) get all

# PRD stop: apagar o que o prd.yml criou, o ConfigMap e o Secret
stop_prd:
	-$(K) delete -f k8s/prd.yml --ignore-not-found
	-$(K) delete configmap nginx-conf --ignore-not-found
	-$(K) delete secret nginx-tls --ignore-not-found

# PRD clean: stop, apagar as imagens puxadas, confirmar e desligar o Kubernetes
clean_prd: stop_prd
	-for img in $(IMAGENS); do microk8s ctr image rm $$img:$(TAG); done
	@echo "--- Só deve aparecer o service/kubernetes"
	-$(K) get all
	-$(MAKE) k8s_stop

# Uso da aplicação em PRD: CRUD com login
prd_demo:
	@echo "--- Criar item (com login)"
	@ID=$$(curl -s --cacert $(CERT) -u $(CRED) $(JSON) -d '{"nome":"Portatil","quantidade":3,"preco":899.9}' $(PRD_URL)/api/itens \
		| tee /dev/stderr | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])'); \
	echo; echo "--- Listar itens (sem login)"; \
	curl -s --cacert $(CERT) $(PRD_URL)/api/itens; echo; \
	echo "--- Alterar a quantidade do item $$ID"; \
	curl -s --cacert $(CERT) -u $(CRED) $(JSON) -X PUT -d '{"quantidade":5}' $(PRD_URL)/api/itens/$$ID; echo; \
	echo "--- Apagar o item $$ID"; \
	curl -s -o /dev/null -w "HTTP %{http_code}\n" --cacert $(CERT) -u $(CRED) -X DELETE $(PRD_URL)/api/itens/$$ID; \
	echo "--- Tentativa com password errada"; \
	curl -s -w "\nHTTP %{http_code}\n" --cacert $(CERT) -u admin:errada $(JSON) -d '{"nome":"X"}' $(PRD_URL)/api/itens

# Alta disponibilidade: apagar um pod; a API continua e o Kubernetes cria outro
prd_ha:
	@echo "--- Pods do itens-service antes"
	$(K) get pods -l app=itens-service
	$(K) delete $$($(K) get pods -l app=itens-service -o name | head -1) --wait=false
	@echo "--- A API continua a responder (a outra réplica atende)"
	@curl -s --cacert $(CERT) $(PRD_URL)/api/itens; echo
	$(K) rollout status deployment itens-service
	@echo "--- O Kubernetes já criou um pod novo"
	$(K) get pods -l app=itens-service

# Escala: itens-service de 2 para 4 réplicas e de volta a 2
prd_scale:
	$(K) scale deployment itens-service --replicas=4
	$(K) rollout status deployment itens-service
	$(K) get pods -l app=itens-service
	$(K) scale deployment itens-service --replicas=2
	sleep 5
	$(K) get pods -l app=itens-service

## Limpeza total ##

# Limpar os 3 ambientes (só o que é do projeto) e verificar que ficou limpo
clean: clean_dev clean_stg clean_prd
	docker builder prune -af
	rm -rf nginx/certs
	@echo "--- Verificacao: nada do projeto deve aparecer"
	@docker ps -a --filter "name=inventario" --format "{{.Names}}" | grep . || echo "sem containers do projeto"
	@docker images | grep -E "inventario|jaeger|nginx" || echo "sem imagens do projeto"
	@docker volume ls | grep inventario || echo "sem volumes do projeto"
	@docker network ls | grep inventario || echo "sem redes do projeto"
	@echo "--- Os pedidos seguintes TEM de falhar"
	@curl -s --max-time 3 $(DEV_URL)/health > /dev/null && echo "ERRO: DEV ainda responde" || echo "DEV parado: OK"
	@curl -s --max-time 3 $(JAEGER_URL) > /dev/null && echo "ERRO: Jaeger ainda responde" || echo "Jaeger parado: OK"
	@curl -sk --max-time 3 $(STG_URL)/health/itens > /dev/null && echo "ERRO: STG ainda responde" || echo "STG parado: OK"
	@curl -sk --max-time 3 $(PRD_URL)/health/itens > /dev/null && echo "ERRO: PRD ainda responde" || echo "PRD parado: OK"