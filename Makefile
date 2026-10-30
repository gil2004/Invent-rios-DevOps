# Projeto Final DevOps — inventario-devops
# Ciclo DevOps por ambiente: build_ / start_ / stop_ / clean_ para DEV, STG e PRD.
#   DEV: desenvolver e testar o código (testes de código e segurança + tracing com Jaeger)
#   STG: build das imagens de PRD, análise das imagens (Trivy) e testes de integração
#   PRD: só sobe o ambiente — o Kubernetes faz o pull das imagens validadas em STG
# A limpeza só toca no que é deste projeto (não mexe noutros containers do PC).

SHELL       := /bin/bash
.SHELLFLAGS := -o pipefail -c

VENV       := venv
PY         := "$(CURDIR)/$(VENV)/bin/python"
DEV        := docker compose -f docker-compose.dev.yml
K          := microk8s kubectl
K8S_LIGADO := microk8s status 2>/dev/null | grep -q "microk8s is running"
TRIVY      := docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v inventario-trivy-cache:/root/.cache aquasec/trivy:latest
TAG        ?= latest
export TAG
IMAGENS    := ghcr.io/gil2004/inventario-auth ghcr.io/gil2004/inventario-itens ghcr.io/gil2004/inventario-web
CERT       := nginx/certs/nginx.crt
REPORTS    := reports
DEV_URL    := http://localhost:5002
WEB_DEV    := http://localhost:5003
JAEGER_URL := http://localhost:16686
STG_URL    := https://localhost
PRD_URL    := https://localhost:30443
CRED       := admin:admin123
JSON       := -H "Content-Type: application/json"

.PHONY: all build_dev test_dev start_dev dev_status stop_dev clean_dev jaeger_dashboard jaeger_erro \
        cert build_stg start_stg stg_status stop_stg clean_stg \
        k8s_start k8s_stop start_prd prd_status stop_prd clean_prd prd_demo prd_ha prd_scale clean

## DEV ##

# DEV build: venv com requirements-dev e imagens de DEV (com OpenTelemetry)
build_dev:
	python3 -m venv $(VENV)
	$(PY) -m pip install -r requirements-dev.txt
	$(DEV) build

# DEV testes de código e segurança (sem ambiente a correr): lint, unitários, bandit e pip-audit dos 3 ambientes
test_dev:
	@mkdir -p $(REPORTS)
	$(PY) -m ruff check . | tee $(REPORTS)/dev-lint.txt
	cd auth-service && $(PY) -m pytest -v --cov=app tests | tee ../$(REPORTS)/dev-unitarios-auth.txt
	cd itens-service && $(PY) -m pytest -v --cov=app tests | tee ../$(REPORTS)/dev-unitarios-itens.txt
	cd web-service && $(PY) -m pytest -v --cov=app tests | tee ../$(REPORTS)/dev-unitarios-web.txt
	$(VENV)/bin/bandit -r auth-service itens-service web-service -x auth-service/tests,itens-service/tests,web-service/tests | tee $(REPORTS)/seguranca-bandit.txt
	for amb in dev stg prd; do $(VENV)/bin/pip-audit -r requirements-$$amb.txt 2>&1 | tee $(REPORTS)/seguranca-pip-audit-$$amb.txt || exit 1; done

# DEV start: serviços + Jaeger, e teste de que os traces chegam ao Jaeger
start_dev:
	$(DEV) up -d
	sleep 10
	@mkdir -p $(REPORTS)
	$(PY) -m pytest -v tests/dev | tee $(REPORTS)/dev-tracing.txt
	@echo ""
	@$(DEV) ps
	@echo abrir página: $(WEB_DEV)
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
	@curl -s -w "\nHTTP %{http_code}\n" -u $(CRED) $(JSON) -d '{"nome":"Erro"}' $(DEV_URL)/api/itens
	$(DEV) start auth-service
	@echo "--- Abrir $(JAEGER_URL), service itens-service: o trace com 503 mostra a causa raiz"

## STG (Docker Compose) ##

# Certificado self-signed para o HTTPS (só é gerado se ainda não existir)
cert:
	@test -f $(CERT) || ( mkdir -p nginx/certs && openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
		-keyout nginx/certs/nginx.key -out $(CERT) \
		-subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" )

# STG build: imagens de PRD (só requirements-prd) com a tag $(TAG) e análise de vulnerabilidades com o Trivy
# (o relatório mostra todas as vulnerabilidades; o build só falha se houver HIGH/CRITICAL com correção)
build_stg:
	docker compose build
	@mkdir -p $(REPORTS)
	for img in $(IMAGENS); do $(TRIVY) image --quiet --scanners vuln $$img:$(TAG) | tee $(REPORTS)/stg-trivy-$$(basename $$img).txt; done
	for img in $(IMAGENS); do $(TRIVY) image --quiet --scanners vuln --ignore-unfixed --severity HIGH,CRITICAL --exit-code 1 $$img:$(TAG) > /dev/null || exit 1; done
	@echo "--- Trivy: nenhuma vulnerabilidade HIGH/CRITICAL com correção por aplicar"

# STG start: sobe o ambiente de PRD em Compose e valida com os testes de integração
start_stg: cert
	docker compose up -d
	sleep 10
	@mkdir -p $(REPORTS)
	$(PY) -m pytest -v tests/integracao | tee $(REPORTS)/stg-integracao.txt
	@echo ""
	@docker compose ps
	@echo abrir página: $(STG_URL)/

# Estado do STG: containers e health dos serviços
stg_status:
	docker compose ps
	@curl -s --cacert $(CERT) $(STG_URL)/health/web; echo
	@curl -s --cacert $(CERT) $(STG_URL)/health/itens; echo
	@curl -s --cacert $(CERT) $(STG_URL)/health/auth; echo

# STG stop
stop_stg:
	docker compose down

# STG clean: containers, imagens, volume e rede de STG, e a imagem e a cache do Trivy
clean_stg:
	docker compose down --rmi all --volumes --remove-orphans
	docker image ls -q aquasec/trivy | xargs -r docker rmi -f
	docker volume ls -q -f name=inventario-trivy-cache | xargs -r docker volume rm

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
	@if $(K8S_LIGADO); then microk8s stop; else echo "--- Kubernetes já está desligado"; fi

# PRD start: só sobe o ambiente — o Kubernetes faz o pull das imagens $(TAG) validadas em STG e arranca os pods
start_prd: cert k8s_start
	$(K) create configmap nginx-conf --from-file=default.conf=nginx/nginx.conf --dry-run=client -o yaml | $(K) apply -f -
	$(K) create secret tls nginx-tls --cert=$(CERT) --key=nginx/certs/nginx.key --dry-run=client -o yaml | $(K) apply -f -
	sed "s/:latest/:$(TAG)/" k8s/prd.yml | $(K) apply -f -
	$(K) rollout restart deployment nginx
	$(K) wait --for=condition=available deployment --all --timeout=300s || ($(K) get pods; $(K) describe pods | grep -A5 "Events:"; exit 1)
	@echo ""
	@$(K) get pods
	@echo abrir página: $(PRD_URL)/

# Estado do PRD: pods, services e deployments
prd_status:
	$(K) get all

# PRD stop: apagar o que o prd.yml criou, o ConfigMap e o Secret (se o Kubernetes estiver ligado)
stop_prd:
	@if $(K8S_LIGADO); then \
		microk8s status --wait-ready > /dev/null; \
		$(K) delete -f k8s/prd.yml --ignore-not-found; \
		$(K) delete configmap nginx-conf --ignore-not-found; \
		$(K) delete secret nginx-tls --ignore-not-found; \
	else echo "--- Kubernetes desligado: o PRD já está parado"; fi

# PRD clean: stop, apagar as imagens do projeto no Kubernetes, confirmar e desligar o Kubernetes
clean_prd: stop_prd
	@if $(K8S_LIGADO); then \
		for img in $(IMAGENS); do microk8s ctr image rm $$img:$(TAG) > /dev/null 2>&1; done; \
		echo "--- PRD: só deve aparecer o service/kubernetes"; \
		$(K) get all; \
	fi
	@$(MAKE) --no-print-directory k8s_stop

# Uso da aplicação em PRD pela API: CRUD com login (a página está em $(PRD_URL)/)
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
	@docker images | grep -E "inventario|jaeger|nginx|trivy" || echo "sem imagens do projeto"
	@docker volume ls | grep inventario || echo "sem volumes do projeto"
	@docker network ls | grep inventario || echo "sem redes do projeto"
	@echo "--- Os pedidos seguintes TEM de falhar"
	@curl -s --max-time 3 $(WEB_DEV)/health > /dev/null && echo "ERRO: DEV ainda responde" || echo "DEV parado: OK"
	@curl -s --max-time 3 $(JAEGER_URL) > /dev/null && echo "ERRO: Jaeger ainda responde" || echo "Jaeger parado: OK"
	@curl -sk --max-time 3 $(STG_URL)/health/web > /dev/null && echo "ERRO: STG ainda responde" || echo "STG parado: OK"
	@curl -sk --max-time 3 $(PRD_URL)/health/web > /dev/null && echo "ERRO: PRD ainda responde" || echo "PRD parado: OK"