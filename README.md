# Projeto Final DevOps — inventario-devops

**Autor:** Gil Alves · **Curso:** DevOps Engineering — Tokio School
**Repositório:** https://github.com/gil2004/inventario-devops

## 1. A aplicação

Gestor de inventário para pequenas empresas: regista o material, o stock ou o
equipamento da empresa (nome, quantidade e preço). Qualquer pessoa pode consultar
a lista, mas só quem tem login pode criar, alterar ou apagar itens.

**Porque é útil para uma startup:** substitui folhas de Excel partilhadas por uma
API com controlo de acesso, testada automaticamente, com redundância e
monitorização, pronta a crescer sem mudar a forma como é entregue.

A aplicação é composta por dois microsserviços Python (Flask), que comunicam por
HTTP com respostas em JSON:

| Serviço | Função | Endpoints |
|---|---|---|
| **itens-service** (5002) | CRUD dos itens, guardados em SQLite | `GET /api/itens` · `GET /api/itens/<id>` · `POST /api/itens` · `PUT /api/itens/<id>` · `DELETE /api/itens/<id>` |
| **auth-service** (5001) | verificação do utilizador e da palavra-passe | `POST /api/verificar` (só interno) |

Para criar, alterar ou apagar, o pedido leva as credenciais (Basic Auth). O
itens-service pergunta ao auth-service se estão corretas antes de executar a
operação; se não estiverem, responde **401**.

## 2. Arquitetura

![HLD](docs/20261005-HLD-ProjetoFinal-DevOps.drawio.png)

| Componente | Função | Porta |
|---|---|---|
| **nginx** | única porta de entrada da API; reverse proxy e load balancer | **80** (exposta) |
| **itens-service** × 2 réplicas | CRUD dos itens | 5002 (interna) |
| **auth-service** × 2 réplicas | verificação das credenciais | 5001 (interna) |
| **volume itens-data** | base de dados SQLite partilhada pelas réplicas do itens-service | — |
| **Jaeger** | receção e visualização dos traces | **16686** (exposta) · 4318 (interna) |

Todos os containers estão na rede Docker `inventario-net` (172.28.0.0/24). Do
exterior só são acessíveis as portas 80 (API) e 16686 (Jaeger).

**Percurso de um pedido:** o utilizador chega ao nginx na porta 80 → o nginx
encaminha para uma das réplicas do itens-service → o itens-service valida as
credenciais numa das réplicas do auth-service → grava no SQLite do volume →
a resposta em JSON regressa pelo mesmo caminho. Os dois serviços enviam os
traces de cada pedido para o Jaeger.

## 3. Ferramentas e bibliotecas

| Ferramenta | Utilização |
|---|---|
| Python 3.12 + venv | linguagem e ambiente virtual |
| Flask | APIs REST |
| requests | chamada do itens-service ao auth-service |
| sqlite3 | base de dados dos itens (biblioteca padrão do Python) |
| gunicorn | servidor de produção nos containers |
| pytest, pytest-cov, requests-mock | testes, cobertura e simulação de serviços |
| ruff | lint |
| OpenTelemetry (sdk, exporter OTLP, instrumentação Flask e requests) | envio dos traces |
| Docker + Docker Compose | containers, réplicas, rede e volume |
| nginx | reverse proxy e load balancer |
| Jaeger v2 | rastreamento distribuído |
| Git + GitHub + GitHub Actions | repositório e pipeline DEV → STG → PRD |
| Make | um comando por passo |

## 4. Decisões de design

- **App simples de inventário** — CRUD completo e login, sem complexidade de negócio.
- **Basic Auth** — o mais simples para uma API usada com `curl`. O enunciado aceita
  HTTP; em produção real seria necessário HTTPS, porque a palavra-passe viaja em cada pedido.
- **Credenciais em variáveis de ambiente** (`ADMIN_USER`, `ADMIN_PASSWORD`), não fixas no código.
- **Redundância** — 2 réplicas por serviço atrás do nginx, com `restart: unless-stopped`.
- **auth-service stateless, itens-service stateful** — o auth-service não guarda
  dados, por isso escala sem alterações; o itens-service guarda os itens em SQLite
  num volume partilhado, para todas as réplicas verem os mesmos dados e para os
  dados sobreviverem a reinícios. O backup é uma cópia do volume.
- **auth-service não exposto** — só o itens-service lhe acede, pela rede interna.
- **Containers sem root** — utilizador `appuser` nos Dockerfiles.
- **Tracing ativado por variável de ambiente** — só com `OTEL_EXPORTER_OTLP_ENDPOINT`
  definida; os testes unitários correm sem precisar do Jaeger.
- **Um único `docker-compose.yml`** para os três ambientes: `build` (DEV e STG) e
  `image` no GitHub Container Registry (PRD, sem build).
- **Só a branch `main`** — cada push corre DEV → STG → PRD; produção protegida por aprovação manual.
- **Limitações conhecidas:**
  - o servidor é um ponto único de falha; a evolução natural seria Docker Swarm
    ou Kubernetes com vários nós;
  - se uma réplica cair, o primeiro pedido encaminhado para ela pode demorar até
    60 s (timeout por defeito do nginx) antes de passar para a outra réplica.

## 5. Ambientes e testes

| Ambiente | Para que serve | Testes |
|---|---|---|
| **DEV** | desenvolvimento local, com venv e build local das imagens | lint + unitários (auth 5 · itens 17) |
| **STG** | build das imagens e validação dos containers a funcionar juntos | integração: serviços ativos, CRUD completo, credenciais erradas, auth-service não exposto (4) |
| **PRD** | arranque rápido com as imagens já testadas, sem build | smoke: health, listagem, criar e apagar, trace no Jaeger (4) |

*(build e utilização de cada ambiente através do pipeline e do Makefile — a completar)*

## 6. Passos de implementação

Cada passo é executado com o Makefile (`make help` lista todos os targets).

### Passo 1 — Estrutura e ambiente virtual · `make setup`
Cria o venv e instala as dependências do `requirements.txt`.

### Passo 2 — Testes unitários · `make test`
Lint (ruff) e testes unitários dos dois serviços. No itens-service, o auth-service
é simulado com `requests-mock`. Resultado: **5 + 17 testes aprovados.**

### Passo 3 — Teste local dos dois serviços
Com os serviços a correr fora de containers, foi feito o ciclo completo do CRUD
com login: listar, criar (201), alterar (200), apagar (204) e palavra-passe errada
(401). Cada pedido com login gerou um `POST /api/verificar` no auth-service.

### Passo 4 — Repositório local e remoto
Repositório Git ligado ao GitHub (`inventario-devops`), com uma só branch, `main`.

### Passo 5 — Ambiente DEV com containers · `make dev`
Dockerfiles por serviço (`python:3.12-slim`, sem root, gunicorn). O Compose
constrói as imagens e arranca o nginx, 2 réplicas de cada serviço e o Jaeger
(6 containers).

### Passo 6 — Redundância e dados partilhados · `make redundancia`
Uma réplica do itens-service é parada e a API continua a responder com os mesmos
dados, lidos do SQLite no volume partilhado.

### Passo 7 — Rastreamento com Jaeger
Cada pedido de escrita aparece em `http://localhost:16686` como um trace com os
spans do itens-service e do auth-service; pedidos com credenciais erradas ficam
assinalados com 401.

### Passo 8 — Testes de integração e smoke
Corridos contra os containers, através do nginx. Resultado: **4 testes de
integração + 4 smoke tests aprovados**, incluindo a confirmação, pela API do
Jaeger, de que os dois serviços enviaram spans.

### Passo 9 — STG: build das imagens e testes de integração · `make stg` *(a completar)*
### Passo 10 — PRD: deploy sem build e utilização (CRUD com login) · `make prd` · `make demo` *(a completar)*
### Passo 11 — Pipeline GitHub Actions *(a completar)*
### Passo 12 — Paragem, destruição e limpeza · `make clean` *(a completar)*

## 7. Evidências

| Teste | Onde | Resultado |
|---|---|---|
| Unitários | local | auth 5 · itens 17 aprovados |
| CRUD com login entre os dois serviços | local | criar 201 · alterar 200 · apagar 204 · credenciais erradas 401 |
| Redundância com dados partilhados | Docker Compose | com uma réplica parada, a API respondeu com os mesmos dados |
| Tracing | Jaeger | trace com itens-service e auth-service; 401 assinalado |
| Integração | containers | 4 aprovados |
| Smoke | containers | 4 aprovados |

## 8. Problemas encontrados

| Problema | Causa | Solução |
|---|---|---|
| Com uma réplica parada, a lista de itens veio vazia | cada réplica guardava os itens na sua própria memória | itens guardados em SQLite num volume partilhado pelas réplicas |
| Com uma réplica parada, o primeiro pedido demorou cerca de 60 s | o nginx espera o timeout por defeito antes de tentar a outra réplica | registado como limitação conhecida (corrige-se com `proxy_connect_timeout` e `proxy_next_upstream`) |
| Os traces não chegavam ao Jaeger | o endpoint OTLP apontava para `otel-collector` em vez de `jaeger` | endpoint corrigido para `http://jaeger:4318`; diagnosticado verificando as variáveis dentro do container |