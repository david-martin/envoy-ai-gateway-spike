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

echo "Installing Envoy Gateway..."
helm upgrade -i eg oci://docker.io/envoyproxy/gateway-helm \
  --version v0.0.0-latest \
  --namespace envoy-gateway-system \
  --create-namespace

echo "Waiting for Envoy Gateway to be ready..."
kubectl wait --timeout=2m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available

echo "Installing Envoy AI Gateway..."
helm upgrade -i aieg oci://docker.io/envoyproxy/ai-gateway-helm \
  --version v0.0.0-latest \
  --namespace envoy-ai-gateway-system \
  --create-namespace

echo "Waiting for AI Gateway controller to be ready..."
kubectl wait --timeout=2m -n envoy-ai-gateway-system deployment/ai-gateway-controller --for=condition=Available

echo "Applying Envoy Gateway AI configuration..."
kubectl apply -f https://raw.githubusercontent.com/envoyproxy/ai-gateway/main/manifests/envoy-gateway-config/redis.yaml
kubectl apply -f https://raw.githubusercontent.com/envoyproxy/ai-gateway/main/manifests/envoy-gateway-config/config.yaml
kubectl apply -f https://raw.githubusercontent.com/envoyproxy/ai-gateway/main/manifests/envoy-gateway-config/rbac.yaml

echo "Restarting Envoy Gateway to apply configuration..."
kubectl rollout restart -n envoy-gateway-system deployment/envoy-gateway
kubectl wait --timeout=2m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available

echo "Verifying AI Gateway installation..."
kubectl get pods -n envoy-ai-gateway-system
kubectl get pods -n envoy-gateway-system

echo "Deploying basic AI Gateway configuration..."
kubectl apply -f https://raw.githubusercontent.com/envoyproxy/ai-gateway/main/examples/basic/basic.yaml

echo "Waiting for Gateway pods to be ready..."
sleep 5
kubectl wait pods --timeout=2m \
  -l gateway.envoyproxy.io/owning-gateway-name=envoy-ai-gateway-basic \
  -n envoy-gateway-system \
  --for=condition=Ready

echo "Verifying Gateway connectivity..."
kubectl get svc -n envoy-gateway-system \
  --selector=gateway.envoyproxy.io/owning-gateway-namespace=default,gateway.envoyproxy.io/owning-gateway-name=envoy-ai-gateway-basic

GATEWAY_URL=$(kubectl get gateway/envoy-ai-gateway-basic -n default -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "")

if [ -n "$GATEWAY_URL" ]; then
  echo "Gateway URL: $GATEWAY_URL"
  echo ""
  echo "Testing Gateway connectivity..."
  curl -s -H "Content-Type: application/json" \
    -d '{
          "model": "some-cool-self-hosted-model",
          "messages": [
              {
                  "role": "system",
                  "content": "Hi."
              }
          ]
      }' \
    "$GATEWAY_URL/v1/chat/completions" || echo "Gateway connectivity test failed (this may be expected if no backend is configured)"
  echo ""
else
  echo "Warning: Could not retrieve Gateway URL"
fi

echo "Applying MCP route configuration..."
kubectl apply -f mcp-route.yaml

echo "Waiting for MCP Gateway to be programmed..."
kubectl wait --timeout=2m \
  -n default \
  gateway/aigw-run \
  --for=condition=Programmed 2>/dev/null || echo "Gateway not ready yet"

echo "Waiting for MCP Gateway pods to be ready..."
kubectl wait pods --timeout=2m \
  -l gateway.envoyproxy.io/owning-gateway-name=aigw-run \
  -n envoy-gateway-system \
  --for=condition=Ready 2>/dev/null || echo "Gateway pods not ready yet"

echo "Waiting for MCP Gateway to have an address..."
for i in {1..30}; do
  MCP_GATEWAY_URL=$(kubectl get gateway/aigw-run -n default -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "")
  if [ -n "$MCP_GATEWAY_URL" ]; then
    break
  fi
  echo "Waiting for Gateway address... (attempt $i/30)"
  sleep 2
done

echo ""
echo "========================================="
echo "Setup complete!"
echo "========================================="
echo "Cluster name: $CLUSTER_NAME"
echo ""

if [ -n "$MCP_GATEWAY_URL" ]; then
  echo "MCP Gateway URL: http://${MCP_GATEWAY_URL}:1975"
  echo ""
  echo "Test MCP server with the following commands:"
  echo ""
  echo "# Initialize MCP session and capture session ID:"
  echo "SESSION_ID=\$(curl -s -i -X POST http://${MCP_GATEWAY_URL}:1975/mcp \\"
  echo "  -H 'Content-Type: application/json' \\"
  echo "  -d '{\"jsonrpc\": \"2.0\", \"id\": 1, \"method\": \"initialize\", \"params\": {}}' \\"
  echo "  | grep -i '^mcp-session-id:' | cut -d' ' -f2 | tr -d '\\r')"
  echo ""
  echo "# List available tools using the session ID:"
  echo "curl -X POST http://${MCP_GATEWAY_URL}:1975/mcp \\"
  echo "  -H 'Content-Type: application/json' \\"
  echo "  -H \"MCP-Session-ID: \$SESSION_ID\" \\"
  echo "  -d '{\"jsonrpc\": \"2.0\", \"id\": 2, \"method\": \"tools/list\", \"params\": {}}'"
  echo ""
else
  echo "Warning: Could not retrieve MCP Gateway URL"
  echo "Check gateway status with: kubectl get gateway -A"
fi

echo "Creating MCP ClusterIP Service..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: mcp-gateway-svc
  namespace: envoy-gateway-system
  labels:
    app: mcp-gateway
spec:
  type: ClusterIP
  selector:
    gateway.envoyproxy.io/owning-gateway-name: aigw-run
    gateway.envoyproxy.io/owning-gateway-namespace: default
  ports:
    - name: mcp
      port: 1975
      targetPort: 1975
      protocol: TCP
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-default-to-envoy-gateway-system
  namespace: envoy-gateway-system
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: default
  to:
    - group: ""
      kind: Service
      name: mcp-gateway-svc
EOF

echo "Deploying standalone MCP proxy..."
kubectl apply -f mcp-proxy-direct.yaml

echo "Waiting for MCP proxy to be ready..."
kubectl wait --timeout=2m -n default deployment/mcp-proxy-direct --for=condition=Available 2>/dev/null || echo "MCP proxy not ready yet"

echo "Creating Istio Gateway and HTTPRoute for MCP..."
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: mcp-gateway
  namespace: default
  labels:
    istio: ingressgateway
spec:
  gatewayClassName: istio
  listeners:
    - name: mcp-via-envoy-gateway
      port: 8080
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All
    - name: mcp-direct
      port: 8081
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mcp-route-via-envoy-gateway
  namespace: default
spec:
  parentRefs:
    - name: mcp-gateway
      sectionName: mcp-via-envoy-gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /mcp
      backendRefs:
        - kind: Service
          name: mcp-gateway-svc
          namespace: envoy-gateway-system
          port: 1975
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mcp-route-direct
  namespace: default
spec:
  parentRefs:
    - name: mcp-gateway
      sectionName: mcp-direct
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /mcp
      backendRefs:
        - kind: Service
          name: mcp-proxy-direct
          namespace: default
          port: 1975
EOF

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
  echo "Istio Gateway URL: http://${ISTIO_GATEWAY_URL}"
  echo ""
  echo "========================================="
  echo "Two paths available for comparison:"
  echo "========================================="
  echo ""
  echo "1. Via Envoy Gateway (port 8080) - Goes through both Istio Envoy AND Envoy Gateway's Envoy"
  echo "   Path: Istio Envoy -> Envoy Gateway Envoy -> MCP Proxy -> Backend"
  echo ""
  echo "# Initialize MCP session via Envoy Gateway:"
  echo "SESSION_ID=\$(curl -s -i -X POST http://${ISTIO_GATEWAY_URL}:8080/mcp \\"
  echo "  -H 'Content-Type: application/json' \\"
  echo "  -d '{\"jsonrpc\": \"2.0\", \"id\": 1, \"method\": \"initialize\", \"params\": {}}' \\"
  echo "  | grep -i '^mcp-session-id:' | cut -d' ' -f2 | tr -d '\\r')"
  echo ""
  echo "curl -X POST http://${ISTIO_GATEWAY_URL}:8080/mcp \\"
  echo "  -H 'Content-Type: application/json' \\"
  echo "  -H \"MCP-Session-ID: \$SESSION_ID\" \\"
  echo "  -d '{\"jsonrpc\": \"2.0\", \"id\": 2, \"method\": \"tools/list\", \"params\": {}}'"
  echo ""
  echo "----------------------------------------"
  echo ""
  echo "2. Direct to MCP Proxy (port 8081) - Only goes through Istio Envoy"
  echo "   Path: Istio Envoy -> MCP Proxy -> Backend"
  echo ""
  echo "# Initialize MCP session directly:"
  echo "SESSION_ID_DIRECT=\$(curl -s -i -X POST http://${ISTIO_GATEWAY_URL}:8081/mcp \\"
  echo "  -H 'Content-Type: application/json' \\"
  echo "  -d '{\"jsonrpc\": \"2.0\", \"id\": 1, \"method\": \"initialize\", \"params\": {}}' \\"
  echo "  | grep -i '^mcp-session-id:' | cut -d' ' -f2 | tr -d '\\r')"
  echo ""
  echo "curl -X POST http://${ISTIO_GATEWAY_URL}:8081/mcp \\"
  echo "  -H 'Content-Type: application/json' \\"
  echo "  -H \"MCP-Session-ID: \$SESSION_ID_DIRECT\" \\"
  echo "  -d '{\"jsonrpc\": \"2.0\", \"id\": 2, \"method\": \"tools/list\", \"params\": {}}'"
  echo ""
fi

echo "========================================="
