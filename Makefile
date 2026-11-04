# Projeto Final DevOps — inventario-devops
# Ciclo DevOps por ambiente: build_ / start_ / stop_ / clean_ para DEV, STG e PRD.
#   DEV: desenvolver e testar o código (testes de código e segurança + tracing com Jaeger)
#   STG: build das imagens de PRD, análise das imagens (Trivy), preparação do servidor Kubernetes
#        e testes de integração na app a correr em Kubernetes (namespace inventario-stg, porta 9443)
#   PRD: só pull das imagens validadas em STG e up (namespace inventario-prd, porta 8443)
# STG e PRD correm no mesmo Kubernetes do PC, separados por namespaces (simulam dois servidores).
# A limpeza só toca no que é deste projeto (não mexe noutros containers do PC).

SHELL       := /bin/bash
.SHELLFLAGS := -o pipefail -c

VENV       := venv
PY         := "$(CURDIR)/$(VENV)/bin/python"
DEV        := docker compose -f docker-compose.dev.yml
K          := microk8s kubectl
STG_NS     := inventario-stg
PRD_NS     := inventario-prd
KS         := $(K) -n $(STG_NS)
KP         := $(K) -n $(PRD_NS)
K8S_ARGS   := /var/snap/microk8s/current/args/kube-apiserver
K8S_LIGADO := microk8s status 2>/dev/null | grep -q "microk8s is running"
TRIVY      := docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v inventario-trivy-cache:/root/.cache aquasec/trivy:latest
TAG        ?= latest
export TAG
REGISTO    := ghcr.io/gil2004
IMAGENS    := $(REGISTO)/inventario-auth $(REGISTO)/inventario-itens $(REGISTO)/inventario-web
CERT       := nginx/certs/nginx.crt
REPORTS    := reports
DEV_URL    := http://localhost:5002
WEB_DEV    := http://localhost:5003
JAEGER_URL := http://localhost:16686
SONAR_URL  := http://localhost:9000
SONAR_STOP := docker ps -q -f name=^inventario-sonarqube$$ | xargs -r docker stop > /dev/null
STG_URL    := https://localhost:9443
PRD_URL    := https://localhost:8443
CRED       := admin:admin123
JSON       := -H "Content-Type: application/json"

.PHONY: all build_dev test_dev sonar_dev start_dev dev_status stop_dev clean_dev jaeger_dashboard jaeger_erro \
        cert k8s_preparar build_stg start_stg stg_status stop_stg clean_stg \
        k8s_stop start_prd prd_status stop_prd clean_prd prd_demo prd_ha prd_scale clean

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

# DEV SonarQube: análise de qualidade e segurança do código (painel em $(SONAR_URL) até ao stop_dev)
sonar_dev:
	bash sonarqube/analisar.sh $(REPORTS)/dev-sonarqube.txt

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

# DEV stop (também desliga o SonarQube, se estiver ligado)
stop_dev:
	$(DEV) down
	@$(SONAR_STOP)

# DEV clean: containers, imagens e volume de DEV, SonarQube, venv e caches
clean_dev:
	$(DEV) down --rmi all --volumes --remove-orphans
	@$(SONAR_STOP)
	docker image ls -q sonarqube | xargs -r docker rmi -f
	docker image ls -q sonarsource/sonar-scanner-cli | xargs -r docker rmi -f
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

## STG (Kubernetes / MicroK8s, namespace inventario-stg) ##

# Certificado self-signed para o HTTPS (só é gerado se ainda não existir)
cert:
	@test -f $(CERT) || ( mkdir -p nginx/certs && openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
		-keyout nginx/certs/nginx.key -out $(CERT) \
		-subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2>/dev/null )

# Preparar o servidor Kubernetes (ligar, portas 8443/9443, DNS e disco) — feito em STG, nunca em PRD
k8s_preparar:
	sudo bash k8s/preparar-servidor.sh

# STG build: imagens de PRD (só requirements-prd) com a tag $(TAG) e análise de vulnerabilidades com o Trivy
# (o relatório mostra todas as vulnerabilidades; o build só falha se houver HIGH/CRITICAL com correção)
build_stg:
	for s in auth itens web; do docker build -f $$s-service/Dockerfile -t $(REGISTO)/inventario-$$s:$(TAG) . || exit 1; done
	@mkdir -p $(REPORTS)
	for img in $(IMAGENS); do $(TRIVY) image --quiet --scanners vuln $$img:$(TAG) | tee $(REPORTS)/stg-trivy-$$(basename $$img).txt; done
	for img in $(IMAGENS); do $(TRIVY) image --quiet --scanners vuln --ignore-unfixed --severity HIGH,CRITICAL --exit-code 1 $$img:$(TAG) > /dev/null || exit 1; done
	@echo "--- Trivy: nenhuma vulnerabilidade HIGH/CRITICAL com correção por aplicar"

# STG start: prepara o servidor, sobe a app em Kubernetes com as imagens acabadas de construir e corre os testes de integração
start_stg: cert k8s_preparar
	@echo "--- Passar as imagens construídas para o Kubernetes"
	for img in $(IMAGENS); do docker save $$img:$(TAG) | microk8s ctr image import - > /dev/null || exit 1; done
	$(K) create namespace $(STG_NS) --dry-run=client -o yaml | $(K) apply -f -
	$(KS) create configmap nginx-conf --from-file=default.conf=nginx/nginx.conf --dry-run=client -o yaml | $(KS) apply -f -
	$(KS) create secret tls nginx-tls --cert=$(CERT) --key=nginx/certs/nginx.key --dry-run=client -o yaml | $(KS) apply -f -
	sed -e "s/:latest/:$(TAG)/" -e "s/imagePullPolicy: Always/imagePullPolicy: Never/" -e "s/nodePort: 8443/nodePort: 9443/" k8s/prd.yml | $(KS) apply -f -
	$(KS) wait --for=condition=available deployment --all --timeout=300s || ($(KS) get pods; $(KS) describe pods | grep -A5 "Events:"; exit 1)
	sleep 5
	@mkdir -p $(REPORTS)
	BASE_URL=$(STG_URL) $(PY) -m pytest -v tests/integracao | tee $(REPORTS)/stg-integracao.txt
	@echo ""
	@$(KS) get pods,svc
	@echo "--- STG validado: $(STG_URL)/"

# Estado do STG: pods, services e health dos serviços
stg_status:
	$(KS) get all
	@curl -s --cacert $(CERT) $(STG_URL)/health/web; echo
	@curl -s --cacert $(CERT) $(STG_URL)/health/itens; echo
	@curl -s --cacert $(CERT) $(STG_URL)/health/auth; echo

# STG stop: apagar o namespace de STG (leva tudo o que lá está)
stop_stg:
	@if $(K8S_LIGADO); then $(K) delete namespace $(STG_NS) --ignore-not-found; \
	else echo "--- Kubernetes desligado: o STG já está parado"; fi

# STG clean: stop, imagens construídas no Docker, e a imagem e a cache do Trivy
clean_stg: stop_stg
	docker image ls -q --filter=reference='$(REGISTO)/inventario-*' | xargs -r docker rmi -f
	docker image ls -q aquasec/trivy | xargs -r docker rmi -f
	docker volume ls -q -f name=inventario-trivy-cache | xargs -r docker volume rm

## PRD (Kubernetes / MicroK8s, namespace inventario-prd) ##

# Desligar o Kubernetes (liberta memória)
k8s_stop:
	@if $(K8S_LIGADO); then microk8s stop; else echo "--- Kubernetes já está desligado"; fi

# PRD start: só pull das imagens $(TAG) validadas em STG e up (o servidor já foi preparado em STG)
start_prd:
	@$(K8S_LIGADO) || (echo "--- Kubernetes desligado: o servidor é preparado em STG (make start_stg)"; exit 1)
	@test -f $(CERT) || (echo "--- Falta o certificado: é criado em STG (make start_stg)"; exit 1)
	@echo "--- Pull das imagens validadas em STG ($(TAG))"
	for img in $(IMAGENS); do echo "pull $$img:$(TAG)"; microk8s ctr image pull $$img:$(TAG) > /dev/null 2>&1 || { echo "ERRO: falhou o pull de $$img:$(TAG)"; exit 1; }; done
	$(K) create namespace $(PRD_NS) --dry-run=client -o yaml | $(K) apply -f -
	$(KP) create configmap nginx-conf --from-file=default.conf=nginx/nginx.conf --dry-run=client -o yaml | $(KP) apply -f -
	$(KP) create secret tls nginx-tls --cert=$(CERT) --key=nginx/certs/nginx.key --dry-run=client -o yaml | $(KP) apply -f -
	sed "s/:latest/:$(TAG)/" k8s/prd.yml | $(KP) apply -f -
	$(KP) wait --for=condition=available deployment --all --timeout=300s || ($(KP) get pods; $(KP) describe pods | grep -A5 "Events:"; exit 1)
	@echo ""
	$(K) get pods -A
	$(K) get svc -A
	@echo "K8s is Ready !"
	@echo " open $(PRD_URL)/  and login with admin / admin123 "

# Estado do PRD: pods, services e deployments
prd_status:
	$(KP) get all

# PRD stop: apagar o namespace de PRD (leva tudo o que lá está)
stop_prd:
	@if $(K8S_LIGADO); then $(K) delete namespace $(PRD_NS) --ignore-not-found; \
	else echo "--- Kubernetes desligado: o PRD já está parado"; fi

# PRD clean: stop, apagar as imagens do projeto no Kubernetes, desligar o Kubernetes e repor a gama de portas original
clean_prd: stop_prd
	@if $(K8S_LIGADO); then \
		for img in $(IMAGENS); do microk8s ctr image rm $$img:$(TAG) > /dev/null 2>&1; done; \
		echo "--- Kubernetes: não deve aparecer nenhum namespace inventario-*"; \
		$(K) get namespaces; \
	fi
	@$(MAKE) --no-print-directory k8s_stop
	@if grep -q "service-node-port-range" $(K8S_ARGS) 2>/dev/null; then sudo sed -i '/service-node-port-range/d' $(K8S_ARGS); echo "--- Gama de portas do Kubernetes reposta"; fi

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
	$(KP) get pods -l app=itens-service
	$(KP) delete $$($(KP) get pods -l app=itens-service -o name | head -1) --wait=false
	@echo "--- A API continua a responder (a outra réplica atende)"
	@curl -s --cacert $(CERT) $(PRD_URL)/api/itens; echo
	$(KP) rollout status deployment itens-service
	@echo "--- O Kubernetes já criou um pod novo"
	$(KP) get pods -l app=itens-service

# Escala: itens-service de 2 para 4 réplicas e de volta a 2
prd_scale:
	$(KP) scale deployment itens-service --replicas=4
	$(KP) rollout status deployment itens-service
	$(KP) get pods -l app=itens-service
	$(KP) scale deployment itens-service --replicas=2
	sleep 5
	$(KP) get pods -l app=itens-service

## Limpeza total ##

# Limpar os 3 ambientes (só o que é do projeto) e verificar que ficou limpo
clean: clean_dev clean_stg clean_prd
	docker builder prune -af
	rm -rf nginx/certs
	@echo "--- Verificacao: nada do projeto deve aparecer"
	@docker ps -a --filter "name=inventario" --format "{{.Names}}" | grep . || echo "sem containers do projeto"
	@docker images | grep -E "inventario|jaeger|trivy|sonar" || echo "sem imagens do projeto"
	@docker volume ls | grep inventario || echo "sem volumes do projeto"
	@docker network ls | grep inventario || echo "sem redes do projeto"
	@echo "--- Os pedidos seguintes TEM de falhar"
	@curl -s --max-time 3 $(WEB_DEV)/health > /dev/null && echo "ERRO: DEV ainda responde" || echo "DEV parado: OK"
	@curl -s --max-time 3 $(JAEGER_URL) > /dev/null && echo "ERRO: Jaeger ainda responde" || echo "Jaeger parado: OK"
	@curl -sk --max-time 3 $(STG_URL)/health/web > /dev/null && echo "ERRO: STG ainda responde" || echo "STG parado: OK"
	@curl -sk --max-time 3 $(PRD_URL)/health/web > /dev/null && echo "ERRO: PRD ainda responde" || echo "PRD parado: OK"