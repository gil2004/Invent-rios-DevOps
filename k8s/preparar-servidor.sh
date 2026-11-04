#!/usr/bin/env bash
# Prepara o servidor Kubernetes (MicroK8s) para o projeto. É feito em STG.
# Em PRD o servidor já está preparado: só se faz pull das imagens e up.
set -euo pipefail
ARGS=/var/snap/microk8s/current/args/kube-apiserver

microk8s start
microk8s status --wait-ready > /dev/null

# Portas 8443 (PRD) e 9443 (STG): por defeito o Kubernetes só aceita NodePorts entre 30000 e 32767
if ! grep -q "service-node-port-range" "$ARGS"; then
  echo "--service-node-port-range=8000-32767" >> "$ARGS"
  microk8s stop
  microk8s start
  microk8s status --wait-ready > /dev/null
fi

# DNS (os serviços encontram-se pelo nome) e disco (para o SQLite do itens-service)
microk8s enable dns
microk8s enable hostpath-storage
microk8s kubectl wait --for=condition=available deployment --all -n kube-system --timeout=180s
echo "--- Servidor Kubernetes preparado"