#!/usr/bin/env bash
# DEV: análise de qualidade e segurança do código com o SonarQube.
# Liga um SonarQube só do projeto (contentor inventario-sonarqube, porta 9000), analisa os 3 serviços
# e grava o resultado no relatório. O build falha se o Quality Gate falhar.
set -euo pipefail
URL=http://localhost:9000
PROJETO=inventario-devops
PASS="Inventario-DevOps-2026"            # password do admin do SonarQube local (contentor descartável)
RELATORIO=${1:-reports/dev-sonarqube.txt}
LOG=$(mktemp)

# 1. Ligar o servidor SonarQube (se ainda não estiver ligado)
if [ -z "$(docker ps -q -f name=^inventario-sonarqube$)" ]; then
  docker run -d --rm --quiet --name inventario-sonarqube -p 9000:9000 \
    -e SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true sonarqube:community > /dev/null
fi
echo "--- A aguardar que o SonarQube arranque (1 a 2 minutos)"
for _ in $(seq 1 60); do
  curl -s "$URL/api/system/status" | grep -q '"status":"UP"' && break
  sleep 5
done
curl -s "$URL/api/system/status" | grep -q '"status":"UP"' || { echo "ERRO: o SonarQube não arrancou"; exit 1; }

# 2. Trocar a password de origem (admin/admin) e criar um token para a análise
curl -s -o /dev/null -u admin:admin -X POST "$URL/api/users/change_password" \
  -d "login=admin&previousPassword=admin&password=$PASS"
TOKEN=$(curl -s -u "admin:$PASS" -X POST "$URL/api/user_tokens/generate" -d "name=analise-$(date +%s)" \
  | python3 -c 'import sys, json; print(json.load(sys.stdin)["token"])')

# 3. Analisar o código dos 3 serviços (os testes contam como testes, não como código)
echo "--- A analisar o código dos 3 serviços"
GATE=0
docker run --rm --quiet --network host -v "$PWD:/usr/src" sonarsource/sonar-scanner-cli \
  -Dsonar.host.url="$URL" -Dsonar.token="$TOKEN" \
  -Dsonar.projectKey="$PROJETO" -Dsonar.projectName="$PROJETO" \
  -Dsonar.sources=auth-service,itens-service,web-service -Dsonar.exclusions='**/tests/**' \
  -Dsonar.tests=auth-service/tests,itens-service/tests,web-service/tests \
  -Dsonar.python.version=3.12 -Dsonar.scm.disabled=true -Dsonar.working.directory=/tmp/scannerwork \
  -Dsonar.qualitygate.wait=true > "$LOG" 2>&1 || GATE=1
if ! grep -q "QUALITY GATE STATUS" "$LOG"; then
  echo "ERRO: a análise do SonarQube falhou"; tail -30 "$LOG"; exit 1
fi

# 4. Relatório: Quality Gate, métricas, problemas e pontos sensíveis de segurança
mkdir -p "$(dirname "$RELATORIO")"
python3 - "$URL" "$PROJETO" "$PASS" > "$RELATORIO" <<'PY'
import base64, json, sys, urllib.error, urllib.request
url, projeto, senha = sys.argv[1:4]
auth = base64.b64encode(f"admin:{senha}".encode()).decode()

def api(caminho):
    pedido = urllib.request.Request(url + caminho, headers={"Authorization": "Basic " + auth})
    return json.load(urllib.request.urlopen(pedido))

def ficheiro(chave):
    return chave.split(":", 1)[-1]

def hotspots_do_projeto():
    # o nome do parâmetro mudou entre versões do SonarQube (project / projectKey)
    for parametro in ("project", "projectKey"):
        try:
            return api(f"/api/hotspots/search?{parametro}={projeto}&ps=100")["hotspots"]
        except urllib.error.HTTPError:
            pass
    return []

gate = api(f"/api/qualitygates/project_status?projectKey={projeto}")["projectStatus"]["status"]
chaves = "ncloc,bugs,vulnerabilities,security_hotspots,code_smells,duplicated_lines_density"
medidas = api(f"/api/measures/component?component={projeto}&metricKeys={chaves}")["component"]["measures"]
m = {x["metric"]: x.get("value", "-") for x in medidas}
problemas = api(f"/api/issues/search?componentKeys={projeto}&resolved=false&ps=100")["issues"]
hotspots = hotspots_do_projeto()

print("SonarQube - análise de qualidade e segurança do código (DEV)")
print(f"Projeto: {projeto}    Painel: {url}/dashboard?id={projeto}")
print()
print(f"Quality Gate ............ {'PASSOU' if gate == 'OK' else 'FALHOU'} ({gate})")
print(f"Linhas de código ........ {m.get('ncloc', '-')}")
print(f"Bugs .................... {m.get('bugs', '-')}")
print(f"Vulnerabilidades ........ {m.get('vulnerabilities', '-')}")
print(f"Security Hotspots ....... {m.get('security_hotspots', '-')}")
print(f"Code Smells ............. {m.get('code_smells', '-')}")
print(f"Código duplicado ........ {m.get('duplicated_lines_density', '-')}%")
print()
print(f"Problemas encontrados ({len(problemas)}):")
for p in problemas:
    sev = p.get("severity") or (p.get("impacts") or [{}])[0].get("severity", "?")
    print(f"  - [{sev}] {ficheiro(p['component'])}:{p.get('line', '-')}  {p['message']}")
if not problemas:
    print("  nenhum")
print()
print(f"Pontos sensíveis de segurança - Security Hotspots ({len(hotspots)}):")
for h in hotspots:
    print(f"  - [{h.get('vulnerabilityProbability', '?')}] {ficheiro(h['component'])}:{h.get('line', '-')}  {h['message']}")
if not hotspots:
    print("  nenhum")
PY
cat "$RELATORIO"
rm -f "$LOG"
[ "$GATE" -eq 0 ] || { echo "ERRO: o Quality Gate do SonarQube falhou"; exit 1; }