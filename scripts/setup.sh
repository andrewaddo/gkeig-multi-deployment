#!/bin/bash
set -e

PROJECT_ID="gpu-launchpad-playground"
REGION="us-central1"
CLUSTER_NAME="ducdo-gkeig-multideployment"

echo "===================================================="
echo "1. Checking/Creating GKE Standard Cluster with Node Auto-Provisioning (NAP)"
echo "===================================================="

if gcloud container clusters describe $CLUSTER_NAME --region $REGION --project $PROJECT_ID > /dev/null 2>&1; then
    echo "Cluster $CLUSTER_NAME already exists. Skipping creation."
else
    echo "Creating cluster $CLUSTER_NAME..."
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
        --max-accelerator type=nvidia-l4,count=16 \
        --quiet
fi

gcloud container clusters get-credentials $CLUSTER_NAME --region $REGION --project $PROJECT_ID

echo "===================================================="
echo "2. Applying Strict ComputeClasses"
echo "===================================================="
# Applies l4-class-primary and l4-class-secondary
kubectl apply -f manifests/compute-classes/strict-classes.yaml

echo "===================================================="
echo "3. Deploying Triton Inference Servers (L4 Primary and Secondary)"
echo "===================================================="
# Deploys Triton and uses an initContainer to generate a TorchScript DLRM model
kubectl apply -f manifests/inference-pools/triton-l4-primary.yaml
kubectl apply -f manifests/inference-pools/triton-l4-secondary.yaml

echo "===================================================="
echo "4. Deploying Unified Service"
echo "===================================================="
# Creates a unified service targeting all triton pods across both deployments
kubectl apply -f manifests/inference-pools/triton-services.yaml

echo "===================================================="
echo "5. Deploying Internal Gateway, HTTPRoute, HealthCheck, and UBB Policy"
echo "===================================================="
# Creates gke-l7-rilb Gateway, HealthCheck overrides, and UBB policy
kubectl apply -f manifests/inference-gateway/triton-gateway-resource.yaml
kubectl apply -f manifests/inference-gateway/triton-gateway.yaml
kubectl apply -f manifests/inference-gateway/healthcheck-policy.yaml
kubectl apply -f manifests/inference-gateway/ubb-policy.yaml

echo "===================================================="
echo "6. Deploying Performance Client and HPA"
echo "===================================================="
kubectl apply -f manifests/hpa/triton-hpa.yaml
kubectl run perf-client --image=nvcr.io/nvidia/tritonserver:24.01-py3-sdk -- sleep infinity

echo "===================================================="
echo "Setup Complete. Waiting for initial pods to become ready..."
echo "Use 'kubectl get pods -w' to monitor initialization."
echo "===================================================="
