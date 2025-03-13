#!/bin/bash

# Skript zum vollständigen Bereinigen des vorherigen vLLM-Deployments und Neustart
set -e

# Pfad zum Skriptverzeichnis
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Lade Konfiguration
if [ -f "$ROOT_DIR/configs/config.sh" ]; then
    source "$ROOT_DIR/configs/config.sh"
else
    echo "Fehler: config.sh nicht gefunden."
    exit 1
fi

echo "=== Vollständige Bereinigung der vLLM-Ressourcen ==="
echo "Namespace: $NAMESPACE"

# Lösche vorhandene Ressourcen
echo "Lösche vorhandene vLLM-Deployments und Services..."
kubectl -n "$NAMESPACE" delete deployment "$VLLM_DEPLOYMENT_NAME" --ignore-not-found=true
kubectl -n "$NAMESPACE" delete service "$VLLM_SERVICE_NAME" --ignore-not-found=true

# Warte, bis alles gelöscht ist
echo "Warte auf vollständige Bereinigung..."
sleep 5

# Erstelle temporäre YAML-Datei für das neue Deployment
TMP_FILE=$(mktemp)

# Verwende TinyLlama - ein sehr kleines, frei verfügbares Modell für ersten Test
TINY_MODEL="TinyLlama/TinyLlama-1.1B-Chat-v1.0"

# Minimale Umgebungsvariablen
GPU_ENV="
            - name: CUDA_VISIBLE_DEVICES
              value: \"0\"
            - name: NCCL_DEBUG
              value: \"WARN\""

# Sehr einfache Argumente - absolute Minimaleinstellung
VLLM_COMMAND="[\"--model\", \"${TINY_MODEL}\", \"--host\", \"0.0.0.0\", \"--port\", \"8000\"]"

# Erstelle YAML für vLLM Deployment mit minimalster Konfiguration
cat << EOF > "$TMP_FILE"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${VLLM_DEPLOYMENT_NAME}-test
  namespace: $NAMESPACE
  labels:
    service: vllm-test
spec:
  replicas: 1
  selector:
    matchLabels:
      service: vllm-test
  template:
    metadata:
      labels:
        service: vllm-test
    spec:
      tolerations:
        - key: "gpu-tesla-v100"
          operator: "Exists"
          effect: "NoSchedule"
      containers:
        - image: vllm/vllm-openai:latest
          name: vllm
          args: $VLLM_COMMAND
          env:$GPU_ENV
          ports:
            - containerPort: 8000
              protocol: TCP
          resources:
            limits:
              memory: "16Gi"
              cpu: "2"
              nvidia.com/gpu: 1
          volumeMounts:
            - name: model-cache
              mountPath: /root/.cache/huggingface
            - name: dshm
              mountPath: /dev/shm
      volumes:
        - name: model-cache
          emptyDir: {}
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: 8Gi
---
apiVersion: v1
kind: Service
metadata:
  name: ${VLLM_SERVICE_NAME}-test
  namespace: $NAMESPACE
  labels:
    service: vllm-test
spec:
  ports:
    - name: http
      port: 8000
      protocol: TCP
      targetPort: 8000
  selector:
    service: vllm-test
  type: ClusterIP
EOF

# Anwenden der Konfiguration
echo "Deploying komplett neues vLLM zu Testzwecken..."
echo "Verwendete Konfiguration:"
cat "$TMP_FILE"
echo "---------------------------------"

kubectl apply -f "$TMP_FILE"

# Aufräumen
rm "$TMP_FILE"

echo "Warte auf das neue vLLM Test-Deployment..."
kubectl -n "$NAMESPACE" rollout status deployment/"${VLLM_DEPLOYMENT_NAME}-test" --timeout=300s

# Zeige direkt die Logs an
echo "Zeige Logs des neuen Test-Deployments:"
echo "---------------------------------"
POD_NAME=$(kubectl -n "$NAMESPACE" get pods -l service=vllm-test -o jsonpath='{.items[0].metadata.name}')
if [ -n "$POD_NAME" ]; then
    kubectl -n "$NAMESPACE" logs -f "$POD_NAME" &
    LOG_PID=$!
    
    # Warte maximal 5 Minuten auf Server-Start
    timeout=300
    elapsed=0
    echo "Warte auf erfolgreichen Start des vLLM-Servers (max. $timeout Sekunden)..."
    
    while [ $elapsed -lt $timeout ]; do
        if kubectl -n "$NAMESPACE" logs "$POD_NAME" | grep -q "Server started at"; then
            echo "vLLM-Server erfolgreich gestartet!"
            break
        fi
        
        # Prüfe auf Fehler
        if kubectl -n "$NAMESPACE" logs "$POD_NAME" | grep -q "Error"; then
            echo "Fehler beim Starten des vLLM-Servers gefunden."
            break
        fi
        
        sleep 5
        elapsed=$((elapsed + 5))
        echo "... noch am Warten ($elapsed/$timeout Sekunden)"
    done
    
    if [ $elapsed -ge $timeout ]; then
        echo "Zeitüberschreitung beim Warten auf Server-Start."
    fi
    
    # Beende Log-Anzeige
    kill $LOG_PID 2>/dev/null || true
    
    echo "---------------------------------"
    echo "Test-Deployment ist aktiv. Sie können die Logs weiterhin überwachen mit:"
    echo "kubectl -n $NAMESPACE logs -f $POD_NAME"
    echo
    echo "Bei Erfolg können Sie vLLM jetzt mit Ihrem gewünschten Modell neu deployen:"
    echo "kubectl -n $NAMESPACE delete deployment ${VLLM_DEPLOYMENT_NAME}-test"
    echo "kubectl -n $NAMESPACE delete service ${VLLM_SERVICE_NAME}-test"
    echo "./deploy.sh"
else
    echo "Konnte keinen Pod für das Test-Deployment finden."
fi
