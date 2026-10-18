# Projeto Final DevOps — inventario-devops
# Um alvo por fase (DEV, STG, PRD) + gestão do Kubernetes + demonstrações + limpeza.

VENV       := venv
PY         := "$(CURDIR)/$(VENV)/bin/python"
K          := microk8s kubectl
CERT       := nginx/certs/nginx.crt
STG_URL    := https://localhost
PRD_URL    := https://localhost:30443
JAEGER_STG := http://localhost:16686
JAEGER_PRD := http://localhost:30686
CRED       := admin:admin123
JSON       := -H "Content-Type: application/json"

.PHONY: all start_dev cert start_stg stg_status stop_stg k8s_start k8s_stop k8s_check \
        start_prd prd_status stop_prd prd_demo prd_ha prd_scale jaeger_dashboard jaeger_erro clean

## DEV ##

# DEV: venv, dependências, lint e testes unitários
start_dev:
	python3 -m venv $(VENV)
	$(PY) -m pip install -r requirements.txt
	$(PY) -m ruff check .
	cd auth-service && $(PY) -m pytest -v --cov=app
	cd itens-service && $(PY) -m pytest -v --cov=app

## STG (Docker Compose) ##

# Certificado self-signed para o HTTPS (só é gerado se ainda não existir)
cert:
	@test -f $(CERT) || ( mkdir -p nginx/certs && openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
		-keyout nginx/certs/nginx.key -out $(CERT) \
		-subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" )

# STG: build das imagens, arranque com Docker Compose e testes de integração
start_stg: cert
	docker compose build
	docker compose up -d
	sleep 10
	$(PY) -m pytest -v tests/integracao
	@echo ""
	@docker ps
	@echo ""
	@echo abrir API: $(STG_URL)/api/itens
	@echo abrir Jaeger: $(JAEGER_STG)

# Estado do STG: containers e health dos serviços
stg_status:
	docker compose ps
	@curl -s --cacert $(CERT) $(STG_URL)/health/itens; echo
	@curl -s --cacert $(CERT) $(STG_URL)/health/auth; echo

# Parar o STG
stop_stg:
	docker compose down

## Kubernetes (MicroK8s) ##

# Ligar o Kubernetes
k8s_start:
	microk8s start
	microk8s status --wait-ready

# Desligar o Kubernetes (liberta memória, não apaga nada)
k8s_stop:
	microk8s stop || (sleep 15 && microk8s stop)

# Estado do Kubernetes
k8s_check:
	microk8s status
	$(K) get nodes

## PRD (Kubernetes) ##

# PRD: configuração e certificado no cluster, deploy das imagens do GHCR (sem build) e smoke tests
start_prd: cert k8s_start
	$(K) create configmap nginx-conf --from-file=default.conf=nginx/nginx.conf --dry-run=client -o yaml | $(K) apply -f -
	$(K) create secret tls nginx-tls --cert=$(CERT) --key=nginx/certs/nginx.key --dry-run=client -o yaml | $(K) apply -f -
	$(K) apply -f k8s/prd.yml
	$(K) rollout restart deployment nginx
	$(K) wait --for=condition=available deployment --all --timeout=300s
	BASE_URL=$(PRD_URL) JAEGER_URL=$(JAEGER_PRD) $(PY) -m pytest -v tests/smoke
	@echo ""
	@$(K) get pods
	@echo ""
	@echo abrir API: $(PRD_URL)/api/itens
	@echo abrir Jaeger: $(JAEGER_PRD)

# Estado do PRD: pods, services e deployments
prd_status:
	$(K) get all

# Parar o PRD: apagar o que o prd.yml criou, o ConfigMap e o Secret
stop_prd:
	-$(K) delete -f k8s/prd.yml --ignore-not-found
	-$(K) delete configmap nginx-conf --ignore-not-found
	-$(K) delete secret nginx-tls --ignore-not-found

## Demonstrações em PRD ##

# Uso da aplicação: CRUD com login
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

## Jaeger ##

# Abrir a UI do Jaeger (PRD) no browser
jaeger_dashboard:
	@x-www-browser $(JAEGER_PRD) > /dev/null 2>&1 &

# Provocar um erro (auth-service em baixo) para encontrar a causa raiz no Jaeger
jaeger_erro:
	$(K) scale deployment auth-service --replicas=0
	-$(K) wait --for=delete pod -l app=auth-service --timeout=60s
	@echo "--- Criar item com o auth-service em baixo (esperado: 503)"
	-@curl -s -w "\nHTTP %{http_code}\n" --cacert $(CERT) -u $(CRED) $(JSON) -d '{"nome":"Erro"}' $(PRD_URL)/api/itens
	$(K) scale deployment auth-service --replicas=2
	$(K) rollout status deployment auth-service
	@echo "--- Abrir $(JAEGER_PRD), service itens-service: o trace com 503 mostra a causa raiz"

## Limpeza ##

# Parar e destruir tudo, e verificar que ficou limpo
clean:
	make stop_prd
	-make stop_stg
	docker ps -qa | xargs -r docker stop
	docker system prune -af --volumes
	docker network prune -f
	docker volume prune -af
	docker builder prune -af
	rm -rf $(VENV) .pytest_cache .ruff_cache .coverage nginx/certs
	find . -name "__pycache__" -type d -prune -exec rm -rf {} +
	find . -name ".pytest_cache" -type d -prune -exec rm -rf {} +
	find . -name ".coverage" -delete
	find . -name "*.db" -delete
	@echo "--- Verificacao: nada do projeto deve aparecer (exceto o service/kubernetes e as redes bridge, host e none)"
	-$(K) get all
	docker ps -a
	docker images
	docker volume ls
	docker network ls
	docker system df
	-make k8s_stop
	@echo "--- Os pedidos seguintes TEM de falhar"
	@curl -sk --max-time 3 $(STG_URL)/health/itens > /dev/null && echo "ERRO: STG ainda responde" || echo "STG parado: OK"
	@curl -sk --max-time 3 $(PRD_URL)/health/itens > /dev/null && echo "ERRO: PRD ainda responde" || echo "PRD parado: OK"
	@curl -s --max-time 3 $(JAEGER_PRD) > /dev/null && echo "ERRO: Jaeger ainda responde" || echo "Jaeger parado: OK"