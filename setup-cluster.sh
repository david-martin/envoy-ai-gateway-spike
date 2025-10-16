#!/bin/bash

set -e

CLUSTER_NAME="${CLUSTER_NAME:-envoy-ai-gateway}"

echo "Checking if Kind cluster '$CLUSTER_NAME' already exists..."
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "Kind cluster '$CLUSTER_NAME' already exists. Skipping creation."
else
  echo "Creating Kind cluster '$CLUSTER_NAME'..."
  cat <<EOF | kind create cluster --name="${CLUSTER_NAME}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 8080
    protocol: TCP
  - containerPort: 443
    hostPort: 8443
    protocol: TCP
EOF
  echo "Kind cluster created successfully."
fi

echo "Installing Gateway API CRDs..."
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml

echo "Adding Istio Helm repository..."
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update

echo "Installing Istio base..."
if helm status istio-base -n istio-system &>/dev/null; then
  echo "istio-base already installed. Skipping."
else
  helm install istio-base istio/base -n istio-system --create-namespace --wait
fi

echo "Installing Istiod..."
if helm status istiod -n istio-system &>/dev/null; then
  echo "istiod already installed. Skipping."
else
  helm install istiod istio/istiod -n istio-system --wait
fi

echo "Deploying standalone MCP AI Gateway with Istio Gateway..."
kubectl apply -f mcp-proxy-direct.yaml

echo "Waiting for MCP AI Gateway to be ready..."
kubectl wait --timeout=2m -n default deployment/mcp-proxy-direct --for=condition=Available

echo "Waiting for Istio Gateway to be programmed..."
kubectl wait --timeout=2m \
  -n default \
  gateway/mcp-gateway \
  --for=condition=Programmed 2>/dev/null || echo "Istio Gateway not ready yet"

echo "Waiting for Istio Gateway to have an address..."
for i in {1..30}; do
  ISTIO_GATEWAY_URL=$(kubectl get gateway/mcp-gateway -n default -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "")
  if [ -n "$ISTIO_GATEWAY_URL" ]; then
    break
  fi
  echo "Waiting for Istio Gateway address... (attempt $i/30)"
  sleep 2
done

if [ -n "$ISTIO_GATEWAY_URL" ]; then
  echo ""
  echo "========================================="
  echo "Setup complete!"
  echo "========================================="
  echo "Cluster name: $CLUSTER_NAME"
  echo ""
  echo "MCP AI Gateway URL: http://${ISTIO_GATEWAY_URL}:8080"
  echo ""
  echo "Architecture:"
  echo "  Client -> Istio Gateway -> Standalone AI Gateway (aigw run) -> MCP Backends (Kiwi)"
  echo ""
  echo "Test MCP server with the following commands:"
  echo ""
  echo "# Initialize MCP session and capture session ID:"
  echo "SESSION_ID=\$(curl -s -i -X POST http://${ISTIO_GATEWAY_URL}:8080/mcp \\"
  echo "  -H 'Content-Type: application/json' \\"
  echo "  -d '{\"jsonrpc\": \"2.0\", \"id\": 1, \"method\": \"initialize\", \"params\": {}}' \\"
  echo "  | grep -i '^mcp-session-id:' | cut -d' ' -f2 | tr -d '\\r')"
  echo ""
  echo "# List available tools using the session ID:"
  echo "curl -X POST http://${ISTIO_GATEWAY_URL}:8080/mcp \\"
  echo "  -H 'Content-Type: application/json' \\"
  echo "  -H \"MCP-Session-ID: \$SESSION_ID\" \\"
  echo "  -d '{\"jsonrpc\": \"2.0\", \"id\": 2, \"method\": \"tools/list\", \"params\": {}}'"
  echo ""
  echo "========================================="
else
  echo "Warning: Could not retrieve Gateway URL"
  echo "Check gateway status with: kubectl get gateway -A"
fi
