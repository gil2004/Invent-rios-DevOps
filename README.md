# Projeto Final DevOps — inventario-devops

**Autor:** Gil Alves · **Curso:** DevOps Engineering — Tokio School
**Repositório:** https://github.com/gil2004/Invent-rios-DevOps

## 1. A aplicação

Gestor de inventário para pequenas empresas: regista o material, o stock ou o equipamento
(nome, quantidade e preço). Qualquer pessoa pode consultar a lista, mas só quem tem login
pode criar, alterar ou apagar itens.

**Porque é útil para uma startup:** substitui folhas de Excel partilhadas por uma API segura
(HTTPS e login), testada automaticamente em cada alteração e que continua a funcionar quando
uma peça falha (réplicas em Kubernetes).

Dois microsserviços Python (Flask) que comunicam por HTTP/JSON:

| Serviço | Função | Endpoints |
|---|---|---|
| **itens-service** (5002) | CRUD dos itens, guardados em SQLite | `GET/POST /api/itens` · `GET/PUT/DELETE /api/itens/<id>` |
| **auth-service** (5001) | verifica o utilizador e a palavra-passe | `POST /api/verificar` (só interno) |

Para criar, alterar ou apagar, o pedido leva as credenciais (Basic Auth: `admin` / `admin123`).
O itens-service pergunta ao auth-service se estão corretas; se não estiverem, responde **401**.

## 2. Ciclo DevOps: DEV → STG → PRD

| Ambiente | Para que serve | Onde corre | Bibliotecas | Testes |
|---|---|---|---|---|
| **DEV** | desenvolver e testar o código | venv + Docker Compose (`docker-compose.dev.yml`) com **Jaeger** | `requirements-dev.txt` (tudo, incluindo OpenTelemetry, bandit e pip-audit) | lint, unitários, segurança e tracing |
| **STG** | fazer o **build** das imagens de PRD e validar que passam nos testes | Docker Compose (`docker-compose.yml`) | imagens com `requirements-prd.txt`; testes com `requirements-stg.txt` | integração |
| **PRD** | subir a app já pronta | Kubernetes (MicroK8s, `k8s/prd.yml`) | imagens só com `requirements-prd.txt` (Flask, gunicorn, requests) | smoke tests (correm fora da app) |

- **Requirements por ambiente:** as imagens de produção só têm as bibliotecas mínimas para a
  app correr. O OpenTelemetry e o Jaeger existem apenas em DEV, porque servem para testes.
- **Build uma só vez, em STG:** cada imagem leva a tag do commit e, depois de passar nos
  testes, é publicada no GitHub Container Registry (GHCR).
- **PRD sem build:** faz apenas o *pull* da imagem com a tag que o STG testou e sobe o ambiente.

## 3. Arquitetura (PRD)

![HLD](docs/20261026-HLD-ProjetoFinal-DevOps.drawio.png)

| Componente | Réplicas | Função | Porta |
|---|---|---|---|
| **nginx** | 2 | única entrada da API, HTTPS (TLS 1.2/1.3) | **30443** (NodePort) |
| **itens-service** | 2 | CRUD dos itens | 5002 (interna) |
| **auth-service** | 2 | verificação das credenciais | 5001 (interna) |
| **PVC itens-data** | — | disco persistente do SQLite, partilhado pelas réplicas | — |

A porta 80 está fechada. **Percurso de um pedido:** HTTPS até ao nginx → Service
`itens-service` (escolhe uma réplica) → validação no Service `auth-service` → SQLite →
resposta pelo mesmo caminho.

## 4. Ferramentas

| Ferramenta | Utilização |
|---|---|
| Python 3.12 + venv, Flask, gunicorn, requests, sqlite3 | aplicação |
| pytest, pytest-cov, requests-mock | testes unitários, de integração e cobertura |
| ruff | lint |
| **bandit** | análise de segurança do código |
| **pip-audit** | vulnerabilidades conhecidas nas bibliotecas de PRD |
| OpenTelemetry + Jaeger v2 | rastreamento distribuído (só DEV) |
| Docker + Docker Compose | DEV e STG |
| Kubernetes (MicroK8s 1.33) + kubectl | PRD: réplicas, self-healing, escala |
| nginx + openssl | entrada HTTPS com certificado self-signed |
| Git, GitHub, GitHub Actions, GHCR | repositório, pipeline e registo de imagens |
| Make | uma tarefa por fase de cada ambiente |
| draw.io | desenho da arquitetura |

## 5. Passos: implementação, build, testes e deploy

O Makefile segue o ciclo **build → start → stop → clean** em cada ambiente. Os resultados
de todos os testes ficam na pasta `reports/`.

### Passo 1 — Repositório e ambiente Python (DEV) · `make build_dev`
Repositório Git local ligado ao GitHub (branch `main`). O `make build_dev` cria o **venv**
com o `requirements-dev.txt` e faz o build das imagens de DEV (com OpenTelemetry).

### Passo 2 — DEV: testes de código e segurança · `make test_dev`
Corre **sem nenhum ambiente ligado** (poupa CPU e memória): lint (ruff), testes unitários
dos dois serviços (pytest, com o auth-service simulado por `requests-mock`), análise de
segurança do código (bandit) e das bibliotecas de PRD (pip-audit).

### Passo 3 — DEV: ambiente com Jaeger · `make start_dev`
Sobe os dois serviços e o Jaeger (`http://localhost:16686`) e testa que os traces dos dois
serviços chegam ao Jaeger. O `make jaeger_erro` desliga o auth-service para provocar um 503:
no Jaeger, o trace mostra a causa raiz (falha de ligação ao auth-service). Parar:
`make stop_dev`.

### Passo 4 — STG: build das imagens de PRD · `make build_stg`
Gera o certificado HTTPS e faz o build das imagens com o `requirements-prd.txt` (sem
ferramentas de teste nem OpenTelemetry).

### Passo 5 — STG: validar o ambiente · `make start_stg`
Sobe o nginx (443, HTTPS) e 2 réplicas de cada serviço e corre os testes de integração:
CRUD completo, login errado recusado, auth-service não exposto e porta 80 fechada. Parar:
`make stop_stg`.

### Passo 6 — Pipeline · `git push`
Cada push corre DEV → STG → PRD no GitHub Actions (secção 6). As imagens aprovadas em STG
são publicadas no GHCR com a tag do commit.

### Passo 7 — PRD: pull das imagens · `make build_prd`
Não há build da app: liga o MicroK8s com os addons `dns` e `hostpath-storage` e faz o
*pull* das imagens do GHCR.

### Passo 8 — PRD: subir e confirmar · `make start_prd`
Guarda a configuração do nginx (ConfigMap) e o certificado (Secret), aplica o
`k8s/prd.yml` e corre os smoke tests contra `https://localhost:30443`.

### Passo 9 — PRD: usar a aplicação · `make prd_demo` · `make prd_ha` · `make prd_scale`
- `prd_demo` — criar (201), listar, alterar (200) e apagar (204) um item; login errado (401).
- `prd_ha` — apaga um pod: a API continua a responder e o Kubernetes cria outro.
- `prd_scale` — escala o itens-service de 2 para 4 réplicas e volta a 2.

### Passo 10 — Paragem, destruição e limpeza · `make clean`
Para e destrói os três ambientes (`clean_dev`, `clean_stg`, `clean_prd`): recursos do
Kubernetes, containers, imagens, volumes e redes do projeto, cache de build, venv, caches e
certificado, e desliga o MicroK8s. No fim lista o que existe para provar que ficou vazio e
tenta aceder a DEV, Jaeger, STG e PRD — esses pedidos **têm de falhar**. A limpeza remove
**apenas o que é do projeto**, sem afetar outros containers do PC.


## 6. Pipeline (GitHub Actions)

Cada push para a `main` corre três jobs, com os ambientes `dev`, `stg` e `prd` do GitHub:

1. **DEV** — instala o `requirements-dev.txt`, corre lint, unitários, bandit e pip-audit
   e depois sobe o `docker-compose.dev.yml` com o **Jaeger** para o teste de tracing.
2. **STG** — faz o build das imagens de PRD (tag = commit), sobe o Docker Compose, corre
   os testes de integração e publica as imagens aprovadas no GHCR.
3. **PRD** — sem build: aplica o `k8s/prd.yml` com a **tag do commit testado em STG** e
   corre os smoke tests. O pytest é instalado só no runner, para testar de fora; não entra
   na app.

Cada job guarda os seus relatórios como *artifact* (`reports-dev`, `reports-stg`,
`reports-prd`).

O certificado HTTPS está guardado nos **Secrets do GitHub** (`TLS_CRT` e `TLS_KEY`): o
pipeline não gera certificados, vai buscá-los ao cofre, como numa empresa.

O job PRD instala o MicroK8s porque o runner do GitHub é uma máquina nova e vazia em cada
execução, que simula o servidor de produção. Num servidor real, o cluster já existe e está
ligado, e o PRD faz apenas o *pull* da imagem testada e o `kubectl apply`.

## 7. Decisões de design

- **HTTPS só na 443**, certificado self-signed gerado com `openssl` (em produção real seria
  assinado por uma entidade de confiança). A chave privada nunca vai para o Git: no PC é
  gerada pelo Makefile e no pipeline vem dos Secrets do GitHub.
- **Kubernetes em PRD** — mantém o número de réplicas pedido, recria pods que falham,
  escala com um comando e distribui os pedidos pelas réplicas. O Docker Compose fica em DEV
  e STG, onde a simplicidade é mais importante.
- **2 réplicas de tudo, incluindo o nginx**, que é a única porta de entrada.
- **SQLite num disco partilhado (PVC)**, para todas as réplicas verem os mesmos dados e os
  dados sobreviverem à recriação dos pods.
- **auth-service não exposto** e **containers sem root** (`appuser`).
- **Tag do commit** — garante que o PRD corre exatamente a imagem que passou nos testes de STG.
- **Testes de código e segurança sem ambiente a correr** — só os testes de tracing (DEV) e
  de integração (STG) precisam do ambiente ligado.
- **Testes em PRD só de confirmação** — os testes completos ficam em DEV e STG; os smoke
  tests de PRD confirmam que a instalação subiu e correm de fora, sem acrescentar nada às
  imagens.
- **Três ficheiros de requirements** em vez de um `requirements.txt` único, como pedido na
  revisão do professor: cada ambiente instala só o que precisa.

## 8. Evidências (pasta `reports/`)

| Teste | Ambiente | Resultado |
|---|---|---|
| Lint (ruff) | DEV | sem erros |
| Unitários | DEV | auth-service 5 (cobertura 70 %) · itens-service 17 (86 %) |
| Segurança do código (bandit) | DEV | 0 problemas |
| Vulnerabilidades (pip-audit) | DEV | 0 vulnerabilidades |
| Tracing | DEV (PC e pipeline) | os dois serviços enviam traces ao Jaeger |
| Integração | STG | 5 aprovados, incluindo porta 80 fechada |
| Smoke tests | PRD | 3 aprovados (health, listagem, criar e apagar) |
| Alta disponibilidade e escala | PRD | pod apagado e recriado sem a API parar; 2 → 4 → 2 réplicas |
| Pipeline | GitHub Actions | DEV ✅ · STG ✅ · PRD ✅ |

## 9. Dificuldades e soluções

| Problema | Solução |
|---|---|
| Com réplicas, cada uma tinha itens diferentes | SQLite num disco partilhado pelas réplicas |
| `curl` e testes recusavam o HTTPS self-signed | confiar no certificado (`--cacert`, `REQUESTS_CA_BUNDLE`) |
| O k3s não arrancava (portas ocupadas) | usado o MicroK8s das aulas, já instalado |
| `make start_prd` falhava noutro PC (addons desligados) | o Makefile liga o `dns` e o `hostpath-storage` antes do deploy |
| bandit: `debug=True` e `0.0.0.0` no arranque manual | removidos; nos containers a app corre com gunicorn |
| pip-audit: vulnerabilidades no Flask 3.1.2 e requests 2.32.5 | atualizados para 3.1.3 e 2.33.0 |
| As imagens de PRD tinham bibliotecas de teste e OpenTelemetry | requirements separados por ambiente e Dockerfile com `requirements-prd.txt` por defeito |
| Certificado antigo no nginx depois de limpar | o `start_prd` reinicia o nginx depois de atualizar o certificado |
| Cada job do pipeline corre numa máquina nova, sem o certificado | certificado guardado nos Secrets do GitHub |

## 10. Limitações

Tudo corre num só PC: se o PC desligar, cai tudo. A evolução seria o Kubernetes em 3 ou mais
nós (cluster em alta disponibilidade) e uma base de dados servidor (PostgreSQL) em vez de
SQLite.

## 11. Correções da última revisão

| Nota do professor | Como foi resolvida |
|---|---|
| O ZIP não deve ter diretorias desnecessárias (`.git`) | ZIP sem `.git`, venv, caches nem certificados |
| Incluir os resultados dos testes de integração e de segurança | pasta `reports/` no ZIP |
| Make por ambiente: `build_`, `start_`, `stop_`, `clean_` | Makefile com o ciclo completo para DEV, STG e PRD |
| Requirements distintos para DEV/STG/PRD; sem OpenTelemetry/Jaeger em PRD | `requirements-dev/stg/prd.txt`; Jaeger só em DEV |
| DEV desenvolve e testa, STG faz o build e valida, PRD faz só o pull e sobe | secções 2, 5 e 6; o PRD sobe a tag do commit testado em STG |
| Não é preciso o ambiente a correr para os testes de código e segurança | `make test_dev` corre sem ambiente |
| `make start_prd` falhou (addons e timeout) | `k8s_start` liga os addons; diagnóstico automático se o deploy falhar |

## 12. Utilização de IA

O código foi escrito com o apoio do Claude (Anthropic). As decisões, a execução dos testes,
a validação e a revisão com base nas notas do professor foram feitas pelo autor.