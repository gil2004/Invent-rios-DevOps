# Projeto Final DevOps — inventario-devops

**Autor:** Gil Alves · **Curso:** DevOps Engineering — Tokio School
**Repositório:** https://github.com/gil2004/Invent-rios-DevOps

---

## 1. A aplicação

Gestor de inventário para pequenas empresas: regista o material, o stock ou o
equipamento da empresa (nome, quantidade e preço). Qualquer pessoa pode consultar
a lista, mas só quem tem login pode criar, alterar ou apagar itens.

**Porque é útil para uma startup:** substitui folhas de Excel partilhadas por uma
API com controlo de acesso, testada automaticamente em cada alteração, com
redundância e monitorização, e que chega a produção em segundos sem intervenção
manual além da aprovação.

A aplicação é composta por dois microsserviços Python (Flask), que comunicam por
HTTP com respostas em JSON:

| Serviço | Função | Endpoints |
|---|---|---|
| **itens-service** (5002) | CRUD dos itens, guardados em SQLite | `GET /api/itens` · `GET /api/itens/<id>` · `POST /api/itens` · `PUT /api/itens/<id>` · `DELETE /api/itens/<id>` |
| **auth-service** (5001) | verificação do utilizador e da palavra-passe | `POST /api/verificar` (só interno) |

Para criar, alterar ou apagar, o pedido leva as credenciais (Basic Auth). O
itens-service pergunta ao auth-service se estão corretas antes de executar a
operação; se não estiverem, responde **401**.

## 2. Introdução — arquitetura do pipeline de entrega contínua

Cada `git push` para a branch `main` dispara o pipeline no GitHub Actions, com
três ambientes personalizados (GitHub Environments):

| Ambiente | O que acontece | Testes |
|---|---|---|
| **DEV** | lint do código | ruff + testes unitários (pytest) |
| **STG** | **build** das imagens Docker (tag = commit), arranque do ambiente completo e publicação das imagens no GitHub Container Registry (GHCR) | testes de integração |
| **PRD** | aprovação manual; **sem build**: `pull` das imagens já testadas em STG e arranque | smoke tests + verificação do tracing no Jaeger |

O build é feito **uma só vez**, em STG. Produção corre exatamente a imagem que
passou nos testes e sobe em segundos, porque só descarrega e arranca.

## 3. Desenho da arquitetura

![HLD](docs/20261002-HLD-ProjetoFinal-DevOps.drawio.png)

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
credenciais numa das réplicas do auth-service → grava no SQLite do volume → a
resposta em JSON regressa pelo mesmo caminho. Os dois serviços enviam os traces
de cada pedido para o Jaeger.

## 4. Ferramentas e bibliotecas

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
| Git + GitHub + GitHub Actions + GHCR | repositório, pipeline e registo de imagens |
| Make | execução de cada passo |
| draw.io | desenho da arquitetura |

## 5. Decisões de design

- **App simples de inventário** — CRUD completo e login, sem complexidade de negócio.
- **Basic Auth** — o mais simples para uma API usada com `curl`.
- **Credenciais de demonstração** (`admin` / `admin123`) — são o valor por defeito
  no código, mas podem ser substituídas pelas variáveis de ambiente `ADMIN_USER` e
  `ADMIN_PASSWORD` sem alterar o código. Em produção real viriam de um gestor de
  segredos (por exemplo, GitHub Secrets) e nunca ficariam no repositório.
- **Redundância** — 2 réplicas por serviço atrás do nginx, com `restart: unless-stopped`.
- **auth-service stateless, itens-service stateful** — o auth-service não guarda
  dados e escala sem alterações; o itens-service guarda os itens em SQLite num
  volume partilhado, para todas as réplicas verem os mesmos dados e para os dados
  sobreviverem a reinícios. O backup é uma cópia do volume.
- **auth-service não exposto** — só o itens-service lhe acede, pela rede interna.
- **Containers sem root** — utilizador `appuser` nos Dockerfiles.
- **Tracing ativado por variável de ambiente** — só com `OTEL_EXPORTER_OTLP_ENDPOINT`
  definida; os testes unitários correm sem precisar do Jaeger.
- **Um único `docker-compose.yml`** para os três ambientes: `build` (DEV e STG) e
  `image` no GHCR com a tag do commit (PRD, sem build).
- **Só a branch `main`** — cada push corre DEV → STG → PRD; produção protegida por aprovação manual.
- **Ambiente local** — desenvolvido e testado diretamente num PC com Ubuntu 24.04, sem máquina virtual.
- **Limitações conhecidas:**
  - o servidor é um ponto único de falha; a evolução natural seria Docker Swarm
    ou Kubernetes com vários nós;
  - se uma réplica cair, o primeiro pedido encaminhado para ela pode demorar até
    60 s (timeout por defeito do nginx) antes de passar para a outra réplica.

## 6. Passos de implementação, build, test e deploy

Todos os passos locais estão no Makefile. `make all` executa do zero até
produção (`setup` → `test` → `stg` → `prd` → `demo`); `make clean` destrói tudo.

### Passo 1 — Estrutura e ambiente virtual · `make setup`
Cria o venv e instala as dependências do `requirements.txt` único do projeto.

### Passo 2 — Desenvolvimento dos microsserviços (DEV)
O código é desenvolvido localmente no venv. Cada serviço pode correr isoladamente
com o servidor de desenvolvimento do Flask, o que permitiu testar o ciclo completo
do CRUD com login antes de criar os containers: listar, criar (201), alterar (200),
apagar (204) e palavra-passe errada (401). Cada pedido com login gerou um
`POST /api/verificar` no auth-service.

### Passo 3 — Testes unitários (DEV) · `make test`
Lint com ruff e testes unitários dos dois serviços. No itens-service, o auth-service
é simulado com `requests-mock` e cada teste usa uma base de dados SQLite temporária.
Resultado: **auth-service 5 · itens-service 17 testes aprovados.**

### Passo 4 — Repositório local e remoto
Repositório Git ligado ao GitHub, com uma só branch, `main`. Em *Settings →
Environments* foram criados os ambientes `dev`, `stg` e `prd`; o `prd` tem
*Required reviewers*, que obriga a aprovação manual antes de produção.

### Passo 5 — Containers, redundância e monitorização
Cada serviço tem um Dockerfile (`python:3.12-slim`, sem root, gunicorn). O
`docker-compose.yml` define o nginx, 2 réplicas de cada serviço, o volume
`itens-data`, o Jaeger e a rede `inventario-net` com sub-rede fixa (6 containers).
Com uma réplica do itens-service parada, a API continuou a responder com os mesmos
dados. Cada pedido de escrita aparece no Jaeger (`http://localhost:16686`) como
um trace com spans do itens-service e do auth-service; os 401 ficam assinalados.

### Passo 6 — STG: build e testes de integração · `make stg`
Build das imagens, arranque do ambiente completo e testes de integração através
do nginx: serviços ativos, CRUD completo, credenciais erradas recusadas e
auth-service inacessível do exterior. Resultado: **4 testes aprovados.**
No pipeline, as imagens que passam nestes testes são publicadas no GHCR com a tag
do commit e com `latest`.

### Passo 7 — PRD: deploy sem build e smoke tests · `make prd`
Produção não faz build: descarrega do GHCR as imagens testadas em STG e arranca-as
(`up --no-build`). Depois correm os smoke tests: health, listagem, criar e apagar,
e confirmação, pela API do Jaeger, de que os dois serviços enviaram spans.
Os smoke tests apagam os itens que criam, para não deixar dados em produção.
Resultado: **4 testes aprovados.**

### Passo 8 — Utilização em PRD · `make demo`
Demonstra o uso habitual da aplicação em produção: criar um item com login,
listar sem login, alterar a quantidade, apagar (204) e uma tentativa com a
palavra-passe errada (401).

### Passo 9 — Pipeline GitHub Actions
O ficheiro `.github/workflows/pipeline.yml` executa automaticamente os passos 3,
6 e 7 em cada push para a `main`: DEV → STG → aprovação manual → PRD. Os containers
de cada job são parados no fim, mesmo que os testes falhem (`if: always()`).

### Passo 10 — Paragem, destruição e limpeza · `make clean`
Remove os containers, a rede, o volume com a base de dados e as imagens do projeto
(incluindo nginx e Jaeger), a cache de build do Docker, o venv, as caches e as
bases de dados locais. No fim, verifica e mostra que não ficaram containers,
imagens, volumes nem redes do projeto. No GitHub, os runners são destruídos
automaticamente no fim de cada job.

## 7. Evidências

| Teste | Onde | Resultado |
|---|---|---|
| Unitários | local + DEV | auth 5 · itens 17 aprovados |
| CRUD com login entre os dois serviços | local | criar 201 · alterar 200 · apagar 204 · credenciais erradas 401 |
| Redundância com dados partilhados | Docker Compose | com uma réplica parada, a API respondeu com os mesmos dados |
| Tracing | Jaeger | trace com itens-service e auth-service; 401 assinalado |
| Integração | local + STG | 4 aprovados |
| Smoke | local + PRD | 4 aprovados |
| Pipeline completo | GitHub Actions | DEV 14 s · STG 1 min 30 s (com build) · PRD 54 s, dos quais o deploy sem build demorou 24 s (10 s são espera fixa) |

## 8. Problemas encontrados

| Problema | Causa | Solução |
|---|---|---|
| Com uma réplica parada, a lista de itens veio vazia | cada réplica guardava os itens na sua própria memória | itens guardados em SQLite num volume partilhado pelas réplicas |
| Os traces não chegavam ao Jaeger | o endpoint OTLP apontava para `otel-collector` em vez de `jaeger` | endpoint corrigido para `http://jaeger:4318`; diagnosticado verificando as variáveis dentro do container |

## 9. Correções em relação à primeira entrega

Esta é a segunda versão do projeto. A primeira versão recebeu as seguintes notas
do professor, resolvidas assim:

| Nota do professor | Como foi resolvida |
|---|---|
| Explicar o conceito da aplicação, para que serve e porque é útil para uma startup | secção 1 |
| O HLD não tinha o nome de ficheiro correto | `AAAAMMDD-HLD-ProjetoFinal-DevOps.drawio.png`, com a data de criação |
| O HLD não seguia o padrão de desenho das aulas | redesenhado segundo as regras do módulo de arquitetura e design: hierarquia, rede com sub-rede, portas, legenda e ícones oficiais |
| O HLD devia mostrar as peças, as portas de entrada, os serviços e os seus ícones, mais do que o workflow | o desenho centra-se no host, na rede, no nginx :80, nas réplicas, no volume e no Jaeger :16686; o CI/CD fica num bloco lateral |
| Não existia redundância do ambiente | 2 réplicas por serviço atrás de um nginx, com dados partilhados num volume |
| Não havia um passo de build separado e o PRD não subia rapidamente | o build é feito uma vez em STG e publicado no GHCR; o PRD só faz `pull` e arranca |
| Não estava explicado o build e o uso de DEV, STG e PRD, incluindo login e CRUD | passos 2 a 8, com o CRUD completo e login (Basic Auth) e o `make demo` |
| `make limpeza` não era das aulas e não deixava o ambiente limpo | substituído por `make clean`, que remove containers, rede, volume, imagens, cache e venv e verifica o resultado |

## 10. Utilização de IA

O código deste projeto foi escrito com o apoio do Claude (Anthropic), incluindo os
microsserviços, os testes, o Dockerfile, o Docker Compose, o pipeline e o Makefile.
As decisões de arquitetura, a execução e validação de todos os testes, a resolução
dos problemas encontrados e a revisão do projeto com base nas notas do professor
foram feitas pelo autor.