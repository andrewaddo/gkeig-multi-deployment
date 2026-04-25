#!/bin/bash
set -e

PROJECT_ID="gpu-launchpad-playground"
REGION="us-central1"
CLUSTER_NAME="ducdo-gkeig-multideployment"

echo "===================================================="
echo "1. Creating GKE Standard Cluster with Node Auto-Provisioning (NAP)"
echo "===================================================="
gcloud container clusters create $CLUSTER_NAME \
    --region $REGION \
    --project $PROJECT_ID \
    --gateway-api=standard \
    --release-channel=regular \
    --num-nodes=1 \
    --machine-type=e2-standard-4 \
    --cluster-ipv4-cidr=/20 \
    --enable-autoprovisioning \
    --min-cpu 1 --max-cpu 200 \
    --min-memory 1 --max-memory 1000 \
    --min-accelerator type=nvidia-l4,count=0 \
    --max-accelerator type=nvidia-l4,count=8 \
    --min-accelerator type=nvidia-rtx-pro-6000,count=0 \
    --max-accelerator type=nvidia-rtx-pro-6000,count=8 \
    --quiet

gcloud container clusters get-credentials $CLUSTER_NAME --region $REGION --project $PROJECT_ID

echo "===================================================="
echo "2. Applying Strict ComputeClasses"
echo "===================================================="
# Applies l4-class and g4-class with whenUnsatisfiable: DoNotScaleUp
kubectl apply -f manifests/compute-classes/strict-classes.yaml

echo "===================================================="
echo "3. Deploying Triton Inference Servers (L4 and G4)"
echo "===================================================="
# Deploys Triton and uses an initContainer to generate a TorchScript DLRM model
kubectl apply -f manifests/inference-pools/triton-l4.yaml
kubectl apply -f manifests/inference-pools/triton-g4.yaml

echo "===================================================="
echo "4. Deploying InferencePools via Helm (EPP Controller)"
echo "===================================================="
# Installs the official gateway-api-inference-extension chart for both pools
helm install triton-l4-pool \
  --dependency-update \
  --set inferencePool.modelServers.matchLabels.app=triton-l4 \
  --set provider.name=gke \
  --set inferenceExtension.monitoring.prometheus.enabled=true \
  --version v1.4.0 \
  oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool

helm install triton-g4-pool \
  --dependency-update \
  --set inferencePool.modelServers.matchLabels.app=triton-g4 \
  --set provider.name=gke \
  --set inferenceExtension.monitoring.prometheus.enabled=true \
  --version v1.4.0 \
  oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool

echo "===================================================="
echo "5. Deploying Internal Gateway, HTTPRoute, and HealthCheck"
echo "===================================================="
# Creates gke-l7-rilb Gateway, HealthCheck overrides, and routes to InferencePools
kubectl apply -f manifests/inference-gateway/healthcheck-policy.yaml
kubectl apply -f manifests/inference-gateway/triton-gateway-resource.yaml
kubectl apply -f manifests/inference-gateway/triton-gateway.yaml

echo "===================================================="
echo "6. Deploying Performance Client and HPA"
echo "===================================================="
kubectl apply -f manifests/hpa/triton-hpa.yaml
kubectl run perf-client --image=nvcr.io/nvidia/tritonserver:24.01-py3-sdk -- sleep infinity

echo "===================================================="
echo "Setup Complete. Waiting for initial pods to become ready..."
echo "Use 'kubectl get pods -w' to monitor initialization."
echo "===================================================="
