Projeto Final DevOps — inventario-devops

Autor: Gil Alves Repositório: https://github.com/gil2004/Invent-rios-DevOps

1. A aplicação

Gestor de inventário para pequenas empresas: regista o material, o stock ou o equipamento (nome, quantidade e preço). Qualquer pessoa pode consultar a lista, mas só quem tem login pode criar, alterar ou apagar itens.

Porque é útil para uma startup: substitui folhas de Excel partilhadas por uma aplicação web segura (HTTPS e login), testada automaticamente em cada alteração e que continua a funcionar quando uma peça falha (réplicas em Kubernetes).

O que o cliente vê: a página https://localhost:8443/, com a lista de itens, e a página "Gerir", onde, depois do login, cria, altera e apaga itens. A API REST/JSON (/api/itens) fica disponível para integrações com outros sistemas.

Três microsserviços Python (Flask), que comunicam por HTTP/JSON:

Serviço	Função	Endpoints
web-service (5003)	interface web: a página do cliente	GET / · GET /gerir · formulários de criar, alterar e apagar
itens-service (5002)	CRUD dos itens, guardados em SQLite	GET/POST /api/itens · GET/PUT/DELETE /api/itens/<id>
auth-service (5001)	verifica o utilizador e a palavra-passe	POST /api/verificar (só interno)

Para criar, alterar ou apagar é preciso login (Basic Auth: admin / admin123, que se podem mudar com as variáveis ADMIN_USER e ADMIN_PASSWORD sem alterar o código). O web-service e o itens-service perguntam ao auth-service se as credenciais estão corretas; se não estiverem, a resposta é 401.

2. Ciclo DevOps: DEV → STG → PRD
Ambiente	Para que serve	Onde corre	Bibliotecas	Testes
DEV	desenvolver e testar o código	venv + Docker Compose (docker-compose.dev.yml) com Jaeger	requirements-dev.txt (inclui OpenTelemetry, bandit e pip-audit)	lint, unitários, segurança (bandit, pip-audit, SonarQube) e tracing
STG	fazer o build das imagens de PRD, preparar o servidor Kubernetes e validar a app a correr em Kubernetes	Kubernetes (MicroK8s), namespace inventario-stg, porta 9443	imagens com requirements-prd.txt; testes com requirements-stg.txt	vulnerabilidades das imagens (Trivy) e integração
PRD	subir a app já validada	Kubernetes (MicroK8s), namespace inventario-prd, porta 8443	imagens só com requirements-prd.txt (Flask, gunicorn, requests)	nenhum: só pull + up da imagem testada em STG
Requirements por ambiente: as imagens de produção só têm as bibliotecas mínimas para a app correr.
OpenTelemetry e Jaeger só em DEV: o rastreamento serve para encontrar erros durante o desenvolvimento e não é necessário em produção. O código da aplicação não tem nada de OpenTelemetry: em DEV, cada serviço arranca com opentelemetry-instrument gunicorn ... (no docker-compose.dev.yml), que envia os traces para o Jaeger por fora da aplicação.
Testes de código o mais cedo possível ("shift left"): lint, unitários, bandit, pip-audit e SonarQube correm em DEV, antes de se construir qualquer imagem. Se falharem, o código não chega ao STG.
A construção e os testes do ambiente acontecem em STG: o STG constrói as imagens, prepara o servidor Kubernetes (ligar o MicroK8s, portas, DNS e disco) e testa a app a correr no mesmo k8s/prd.yml que vai para PRD. Depois de passar nos testes, as imagens são publicadas no GitHub Container Registry (GHCR) com a tag do commit.
PRD só faz pull + up: vai buscar ao GHCR as imagens que o STG validou e sobe o ambiente. Sem build, sem preparação do servidor e sem testes. No fim mostra os pods, os serviços com os IPs e as portas, e o endereço que o cliente pode abrir.
Um só servidor Kubernetes no PC: STG e PRD correm no mesmo MicroK8s, separados por namespaces (inventario-stg e inventario-prd), que simulam dois servidores. O servidor é preparado uma vez, em STG; o PRD só o usa.
3. Arquitetura (PRD)

HLD

Componente	Réplicas	Função	Porta
nginx	2	única entrada, HTTPS (TLS 1.2/1.3)	8443 (NodePort, externa) → 443
web-service	2	interface web	5003 (HTTP, interna)
itens-service	2	CRUD dos itens	5002 (HTTP, interna)
auth-service	2	verificação das credenciais	5001 (HTTP, interna)
PVC itens-data	—	disco persistente do SQLite, partilhado pelas réplicas	—

O STG tem exatamente os mesmos componentes, no namespace inventario-stg e na porta 9443.

HTTPS só por fora, HTTP por dentro: o TLS termina no nginx. Só a ligação do utilizador ao nginx é cifrada (HTTPS, externa). Dentro do cluster, o nginx e os serviços falam em HTTP (interno), numa rede que não está exposta. Um pedido em HTTP simples à porta da app é recusado pelo nginx.

Percurso de um pedido: browser → HTTPS 8443 → nginx → (HTTP) web-service → (HTTP) itens-service → (HTTP) auth-service para validar o login → SQLite → resposta pelo mesmo caminho.

4. Ferramentas
Ferramenta	Utilização
Python 3.12 + venv, Flask (com templates Jinja), gunicorn, requests, sqlite3	aplicação
pytest, pytest-cov, requests-mock	testes unitários, de integração e cobertura
ruff	lint
bandit	análise de segurança do código
SonarQube (Community, em contentor)	qualidade e segurança do código: bugs, vulnerabilidades, security hotspots e Quality Gate
pip-audit	vulnerabilidades conhecidas nas bibliotecas de DEV, STG e PRD
Trivy	vulnerabilidades das imagens Docker (sistema operativo e pacotes)
OpenTelemetry (opentelemetry-instrument) + Jaeger v2	rastreamento distribuído (só DEV)
Docker + Docker Compose	build das imagens; DEV em Compose; imagens python:3.12-alpine
Kubernetes (MicroK8s 1.33) + kubectl	STG e PRD: réplicas, self-healing, escala
nginx + openssl	entrada HTTPS com certificado self-signed
Git, GitHub, GitHub Actions, GHCR	repositório, pipeline e registo de imagens
Make	uma tarefa por fase de cada ambiente
draw.io	desenho da arquitetura
5. Passos: implementação, build, testes e deploy

O Makefile segue o ciclo build → start → stop → clean em cada ambiente. Os resultados dos testes ficam na pasta reports/.

Passo 1 — Repositório e ambiente Python (DEV) · make build_dev

Repositório Git local ligado ao GitHub (branch main). O make build_dev cria o venv com o requirements-dev.txt e faz o build das imagens de DEV.

Passo 2 — DEV: testes de código e segurança · make test_dev

Corre sem nenhum ambiente ligado (poupa CPU e memória): lint (ruff), testes unitários dos três serviços (pytest, com os outros serviços simulados por requests-mock), análise de segurança do código (bandit) e das bibliotecas dos três ambientes (pip-audit sobre o requirements-dev.txt, o -stg e o -prd).

Passo 3 — DEV: SonarQube · make sonar_dev

O script sonarqube/analisar.sh liga um SonarQube só do projeto (contentor inventario-sonarqube, porta 9000), analisa o código dos três serviços com o sonar-scanner e grava o resultado em reports/dev-sonarqube.txt: Quality Gate, bugs, vulnerabilidades, security hotspots, code smells e a lista dos problemas. O passo falha se o Quality Gate falhar. Enquanto o DEV estiver ligado, o painel fica em http://localhost:9000.

Passo 4 — DEV: ambiente com Jaeger · make start_dev

Sobe os três serviços e o Jaeger e testa que os traces chegam ao Jaeger. A página fica em http://localhost:5003 e o Jaeger em http://localhost:16686. O make jaeger_erro desliga o auth-service para provocar um 503: no Jaeger, o trace mostra a causa raiz (falha de ligação ao auth-service). Parar: make stop_dev (também desliga o SonarQube).

Passo 5 — STG: build e análise das imagens de PRD · make build_stg

Faz o build das três imagens com o requirements-prd.txt e analisa-as com o Trivy. O relatório mostra todas as vulnerabilidades; o build falha se houver alguma HIGH ou CRITICAL com correção disponível.

Passo 6 — STG: preparar o servidor e validar a app em Kubernetes · make start_stg
Prepara o servidor Kubernetes com o script k8s/preparar-servidor.sh: liga o MicroK8s, alarga a gama de portas NodePort (por defeito só aceita 30000–32767) para permitir as portas 8443 e 9443, e ativa o DNS e o disco (hostpath-storage).
Passa as imagens acabadas de construir para o Kubernetes.
Sobe a app no namespace inventario-stg com o mesmo k8s/prd.yml de PRD, trocando só a porta (9443) e a origem das imagens (as locais, ainda não publicadas).
Corre os testes de integração contra o Kubernetes: serviços ativos, página web e login, CRUD completo, login errado recusado, auth-service não exposto e HTTP simples recusado.

Parar: make stop_stg (apaga o namespace de STG).

Passo 7 — Pipeline · git push

Cada push corre DEV → STG → PRD no GitHub Actions (secção 6). As imagens aprovadas em STG são publicadas no GHCR com a tag do commit.

Passo 8 — PRD: subir o ambiente (pull + up) · make start_prd

Confirma que o servidor já foi preparado em STG (se não foi, para com uma mensagem clara em vez de o preparar). Faz o pull das imagens validadas, guarda a configuração do nginx (ConfigMap) e o certificado (Secret) no namespace inventario-prd e aplica o k8s/prd.yml. No fim mostra os pods e os serviços de todo o cluster (com os IPs e as portas) e: "K8s is Ready ! open https://localhost:8443/ and login with admin / admin123". Parar: make stop_prd.

Passo 9 — PRD: usar a aplicação
Browser: https://localhost:8443/ (lista) e "Gerir" (criar, alterar e apagar com login).
make prd_demo — o mesmo pela API: criar (201), listar, alterar (200) e apagar (204) um item; login errado (401).
make prd_ha — apaga um pod: a aplicação continua a responder e o Kubernetes cria outro.
make prd_scale — escala o itens-service de 2 para 4 réplicas e volta a 2.
Passo 10 — Paragem, destruição e limpeza · make clean

Para e destrói os três ambientes (clean_dev, clean_stg, clean_prd): namespaces do Kubernetes, containers, imagens, volumes e redes do projeto, o SonarQube, a imagem e a cache do Trivy, a cache de build, o venv, as caches e o certificado; desliga o MicroK8s e repõe a gama de portas original. No fim lista o que existe para provar que ficou vazio e tenta aceder a DEV, Jaeger, STG e PRD — esses pedidos têm de falhar. A limpeza remove apenas o que é do projeto, sem afetar outros containers do PC.

6. Pipeline (GitHub Actions)

Cada push para a main corre três jobs, com os ambientes dev, stg e prd do GitHub (o PRD pede aprovação manual):

DEV — lint, unitários dos três serviços, bandit, pip-audit dos três ambientes e SonarQube; depois sobe o docker-compose.dev.yml com o Jaeger para o teste de tracing.
STG — build das imagens de PRD (tag = commit), Trivy, preparação do Kubernetes (k8s/preparar-servidor.sh), app no namespace inventario-stg, testes de integração e publicação das imagens aprovadas no GHCR.
PRD — dois passos separados: "Preparar o servidor" e "Subir o PRD (pull das imagens validadas em STG + up)", que termina com os pods, os serviços e o endereço da aplicação.

Os jobs DEV e STG guardam os relatórios como artifact (reports-dev, reports-stg).

O certificado HTTPS está guardado nos Secrets do GitHub (TLS_CRT e TLS_KEY): o pipeline não gera certificados, vai buscá-los ao cofre, como numa empresa.

Porque é que o job PRD prepara o servidor: no GitHub cada job corre numa máquina nova e vazia, por isso o job PRD tem de instalar o MicroK8s antes do pull + up. Esse passo está separado e identificado ("runner vazio; num servidor real este passo já está feito"). No PC, onde o servidor existe, o make start_prd faz só pull + up.

7. Decisões de design
Interface web num microsserviço próprio (web-service): não guarda dados, usa a API do itens-service e valida o login no auth-service.
HTTPS só por fora (porta 443 no nginx, NodePort 8443), HTTP por dentro do cluster. Certificado self-signed gerado com openssl (em produção real seria assinado por uma entidade de confiança). A chave privada nunca vai para o Git: no PC é gerada pelo Makefile e no pipeline vem dos Secrets do GitHub.
Kubernetes em STG e PRD — mantém o número de réplicas pedido, recria pods que falham, escala com um comando e distribui os pedidos pelas réplicas. Testar o STG no mesmo Kubernetes e com o mesmo manifesto garante que o que passa em STG funciona em PRD. O Docker Compose fica em DEV, onde a simplicidade é mais importante.
O mesmo k8s/prd.yml para STG e PRD: em PRD as imagens são sempre puxadas do GHCR (política de pull Always); em STG o Makefile troca para as imagens acabadas de construir (Never) e para a porta 9443.
Portas 8443 (PRD) e 9443 (STG), em vez da 30443: o 8443 é a porta tradicional para HTTPS alternativo. Como o Kubernetes só aceita NodePorts entre 30000 e 32767, a gama é alargada na preparação do servidor e reposta no make clean.
2 réplicas de tudo, incluindo o nginx, que é a única porta de entrada.
SQLite num disco partilhado (PVC), para todas as réplicas verem os mesmos dados e os dados sobreviverem à recriação dos pods.
Imagens mínimas: base python:3.12-alpine, atualizações de segurança do sistema (apk upgrade) e o pip removido depois de instalar as bibliotecas (só serve para instalar, a app não precisa dele). Containers sem root (appuser).
SonarQube em DEV — faz análise estática (lê o código sem o correr), por isso fica com os outros testes de código. Corre num contentor só do projeto, igual no PC e no pipeline, sem contas nem serviços externos.
Avisos do SonarQube revistos: os avisos de CSRF nos três serviços foram analisados e marcados no código com # NOSONAR e o motivo — o auth-service e o itens-service são APIs JSON com Basic Auth e sem cookies, onde o CSRF não se aplica; o web-service já recusa formulários de outros sites (verificação do Origin, com teste). Os avisos de acessibilidade foram corrigidos (etiquetas nos campos do formulário).
Tag do commit — garante que o PRD corre exatamente a imagem que passou nos testes de STG.
Testes de código e segurança sem ambiente a correr — só o tracing (DEV) e a integração (STG) precisam do ambiente ligado.
Sem testes nem construção em PRD — o PRD só faz pull + up do que o STG validou.
Três ficheiros de requirements em vez de um requirements.txt único: cada ambiente instala só o que precisa.
8. Evidências (pasta reports/)
Teste	Ambiente	Ficheiro	Resultado
Lint (ruff)	DEV	dev-lint.txt	sem erros
Unitários	DEV	dev-unitarios-*.txt	auth 5 (95 %) · itens 17 (95 %) · web 10 (86 %)
Segurança do código (bandit)	DEV	seguranca-bandit.txt	0 problemas
Qualidade e segurança do código (SonarQube)	DEV	dev-sonarqube.txt	Quality Gate PASSOU · 0 bugs · 0 vulnerabilidades · 0 hotspots · 0 code smells
Bibliotecas (pip-audit)	DEV, STG, PRD	seguranca-pip-audit-{dev,stg,prd}.txt	0 vulnerabilidades nos três
Tracing	DEV	dev-tracing.txt	os serviços enviam traces ao Jaeger
Imagens (Trivy)	STG	stg-trivy-inventario-{auth,itens,web}.txt	0 vulnerabilidades
Integração (app em Kubernetes)	STG	stg-integracao.txt	6 aprovados, incluindo página web e HTTP simples recusado
Subida do PRD	PRD	shell_output.txt	pull + up; 8 pods Running em segundos; pods, serviços e endereço mostrados
Alta disponibilidade e escala	PRD	shell_output.txt	pod apagado e recriado sem parar; 2 → 4 → 2 réplicas
Pipeline	GitHub Actions	separador Actions	DEV ✅ · STG ✅ · PRD ✅

Vulnerabilidades das imagens (Trivy), por imagem:

Imagem	Sistema operativo	Pacotes Python	Total
Antes: python:3.12-slim	164 (44 HIGH)	6	170
Depois: python:3.12-alpine, com apk upgrade e sem pip	0	0	0

SonarQube: a primeira análise encontrou 9 problemas (3 avisos de CSRF e 6 de acessibilidade no formulário); depois da revisão ficou com 0 (secção 7).

9. Dificuldades e soluções
Problema	Solução
Com réplicas, cada uma tinha itens diferentes	SQLite num disco partilhado pelas réplicas
curl e testes recusavam o HTTPS self-signed	confiar no certificado (--cacert, REQUESTS_CA_BUNDLE)
O k3s não arrancava (portas ocupadas)	usado o MicroK8s, já instalado e estável no servidor
pip-audit: vulnerabilidades no Flask, requests, pytest e OpenTelemetry	versões atualizadas nos requirements
Imagens com 170 vulnerabilidades (base Debian e pip)	base alpine, apk upgrade e pip removido da imagem
Dúvida sobre a app correr sem OpenTelemetry em STG/PRD	OpenTelemetry tirado do código; ligado só em DEV com opentelemetry-instrument
O nginx não arrancava ("host not found in upstream")	faltava o Service do itens-service no prd.yml; o log do pod mostrou a causa
Erros "(ignorado)" no make clean com o Kubernetes desligado	os alvos de STG e PRD verificam primeiro se o MicroK8s está ligado
Cada job do pipeline corre numa máquina nova, sem o certificado	certificado guardado nos Secrets do GitHub
O Kubernetes recusava as portas 8443 e 9443 (só aceita 30000–32767)	a preparação do servidor alarga a gama de NodePorts; o make clean repõe-na
A app antiga, no namespace default, ainda ocupava a porta	removida uma vez; STG e PRD passaram a ter namespaces próprios, apagados no stop
O teste "porta 80 fechada" falhou com o STG na porta 9443	o teste passou a confirmar que o nginx recusa HTTP simples na porta da app (400)
No GitHub, microk8s start falhava dentro do script com sudo	o script liga e reinicia o MicroK8s com os comandos do snap
Logo a seguir a ligar, o microk8s status falhava	o script espera e volta a tentar até o Kubernetes responder
O pull com o ctr escrevia uma linha "ERRO" sem importância	a saída do pull é escondida; um pull que falhe mesmo para com mensagem clara
SonarQube: mensagens e API diferentes na versão atual	o script deteta o fim da análise pelo Quality Gate e aceita os dois nomes do parâmetro dos hotspots
GitHub Actions por vezes lento ou preso (snap, jobs sem fechar)	cancelar e voltar a correr (Re-run all jobs); não depende do código


O código foi escrito com o apoio do Claude (Anthropic). As decisões técnicas, a execução dos testes, a validação e a revisão foram feitas pelo autor.