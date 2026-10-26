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
| **PRD** | subir a app já pronta | Kubernetes (MicroK8s, `k8s/prd.yml`) | só `requirements-prd.txt` (Flask, gunicorn, requests) | confirmação com 3 `curl` |

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

## 5. Como usar cada ambiente (Makefile)

O Makefile segue o ciclo **build → start → stop → clean** em cada ambiente. Os resultados
de todos os testes ficam na pasta `reports/`.

**DEV**
- `make build_dev` — cria o venv com o `requirements-dev.txt` e faz o build das imagens de DEV.
- `make test_dev` — lint, testes unitários, bandit e pip-audit, **sem nenhum ambiente a
  correr** (poupa CPU e memória).
- `make start_dev` — sobe os serviços e o Jaeger (`http://localhost:16686`) e testa que os
  traces chegam ao Jaeger.
- `make jaeger_erro` — desliga o auth-service para provocar um 503; no Jaeger, o trace
  mostra a causa raiz (falha de ligação ao auth-service).
- `make stop_dev` · `make clean_dev`

**STG**
- `make build_stg` — gera o certificado e faz o build das imagens de PRD.
- `make start_stg` — sobe nginx (443) + 2 réplicas de cada serviço e corre os testes de
  integração.
- `make stop_stg` · `make clean_stg`

**PRD**
- `make build_prd` — não há build da app: liga o MicroK8s com os addons `dns` e
  `hostpath-storage` e faz o *pull* das imagens do GHCR.
- `make start_prd` — guarda a configuração do nginx (ConfigMap) e o certificado (Secret),
  aplica o `k8s/prd.yml` e confirma com 3 `curl` que a API responde
  (`https://localhost:30443`).
- `make prd_demo` — criar, listar, alterar e apagar um item, e login errado (401).
- `make prd_ha` — apaga um pod: a API continua a responder e o Kubernetes cria outro.
- `make prd_scale` — escala o itens-service de 2 para 4 réplicas e volta a 2.
- `make stop_prd` · `make clean_prd`

**Tudo:** `make all` corre DEV → STG → PRD, parando cada ambiente antes do seguinte.
`make clean` limpa os três e confirma que nada do projeto ficou a correr. A limpeza remove
**apenas o que é do projeto** (containers, imagens, volumes e redes `inventario`), sem
afetar outros containers do PC.

## 6. Pipeline (GitHub Actions)

Cada push para a `main` corre três jobs, com os ambientes `dev`, `stg` e `prd` do GitHub:

1. **DEV** — instala o `requirements-dev.txt` e corre lint, unitários, bandit e pip-audit.
2. **STG** — faz o build das imagens de PRD (tag = commit), sobe o Docker Compose, corre
   os testes de integração e publica as imagens aprovadas no GHCR.
3. **PRD** — sem Python e sem build: aplica o `k8s/prd.yml` com a **tag do commit testado em
   STG** e confirma com 3 `curl` que a API responde.

Cada job guarda os seus relatórios como *artifact* (`reports-dev`, `reports-stg`,
`reports-prd`).

O job PRD instala o MicroK8s porque o runner do GitHub é uma máquina nova e vazia em cada
execução, que simula o servidor de produção. Num servidor real, o cluster já existe e está
ligado, e o PRD faz apenas o *pull* da imagem testada e o `kubectl apply`.

## 7. Decisões de design

- **HTTPS só na 443**, certificado self-signed gerado com `openssl` (em produção real seria
  assinado por uma entidade de confiança). A chave privada nunca vai para o Git: cada
  ambiente gera a sua.
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
- **PRD só com confirmação mínima** — os testes completos ficam em DEV e STG; em PRD só se
  confirma que a instalação subiu.

## 8. Evidências (pasta `reports/`)

| Teste | Ambiente | Resultado |
|---|---|---|
| Lint (ruff) | DEV | sem erros |
| Unitários | DEV | auth-service 5 (cobertura 70 %) · itens-service 17 (86 %) |
| Segurança do código (bandit) | DEV | 0 problemas |
| Vulnerabilidades (pip-audit) | DEV | 0 vulnerabilidades |
| Tracing | DEV | os dois serviços enviam traces ao Jaeger |
| Integração | STG | 5 aprovados, incluindo porta 80 fechada |
| Confirmação de PRD | PRD | health dos 2 serviços e listagem com resposta |
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
| DEV desenvolve e testa, STG faz o build e valida, PRD faz só o pull e sobe | secções 2, 5 e 6 |
| Não é preciso o ambiente a correr para os testes de código e segurança | `make test_dev` corre sem ambiente |
| `make start_prd` falhou (addons e timeout) | `k8s_start` liga os addons; diagnóstico automático se o deploy falhar |

## 12. Utilização de IA

O código foi escrito com o apoio do Claude (Anthropic). As decisões, a execução dos testes,
a validação e a revisão com base nas notas do professor foram feitas pelo autor.