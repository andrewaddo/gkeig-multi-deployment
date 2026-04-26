# GKE Multi-GPU Inference Routing: Quick Recipe

This is the lean, repeatable guide to spinning up the architecture, deploying the DLRM models, configuring the AI-aware Gateway (UBB), and running the load tests.

## 1. Environment & Cluster Setup

Set your environment variables and create the GKE Standard cluster with Node Auto-Provisioning (NAP) configured for L4 and RTX-6000 (G4) GPUs.

```bash
export PROJECT_ID="gpu-launchpad-playground"
export REGION="us-central1"
export CLUSTER_NAME="ducdo-gkeig-multideployment"

# Create the Cluster
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

# Authenticate kubectl
gcloud container clusters get-credentials $CLUSTER_NAME --region $REGION --project $PROJECT_ID
```

## 2. Deploy Hardware & Workloads

Apply the strict ComputeClasses (to prevent fallback) and deploy the Triton servers. The Triton pods contain an `initContainer` that dynamically generates the DLRM model on startup.

```bash
# Apply strict ComputeClasses
kubectl apply -f manifests/compute-classes/strict-classes.yaml

# Deploy Triton Services
kubectl apply -f manifests/inference-pools/triton-services.yaml

# Deploy Triton Pods (L4 and G4)
kubectl apply -f manifests/inference-pools/triton-l4.yaml
kubectl apply -f manifests/inference-pools/triton-g4.yaml
```
*Wait for pods to transition from `Init` to `Running` (takes ~2 minutes to generate the model).*
```bash
kubectl get pods -w
```

## 3. Deploy Gateway & UBB Routing

Deploy the Regional Gateway, HTTPRoute, HealthChecks (to fix the 503 error), and the UBB policy (to map Triton queue depth to the Load Balancer).

*Note: This setup utilizes the GA **GKE Gateway API** combined with **Utilization-Based Balancing (UBB)** to achieve AI-aware dynamic spillover. While the "GKE Inference Gateway" (which uses `InferencePool` and `EndpointPicker` CRDs) is an alternative path, it is currently in Preview and was bypassed in this setup due to API compatibility bugs on this specific GKE version.*

```bash
# 1. Gateway & Route
kubectl apply -f manifests/inference-gateway/triton-gateway-resource.yaml
kubectl apply -f manifests/inference-gateway/triton-gateway.yaml

# 2. HealthCheck Overrides (Prevents 503s)
kubectl apply -f manifests/inference-gateway/healthcheck-policy.yaml

# 3. UBB Policy (Enables Dynamic Spillover based on Queue Depth)
kubectl apply -f manifests/inference-gateway/ubb-policy.yaml
```

## 4. Deploy HPA & Test Client

Deploy the autoscalers and the pod we will use to generate load.

```bash
# Apply Queue Depth HPA
kubectl apply -f manifests/hpa-production/triton-queue-depth-hpa.yaml

# Deploy Performance Test Client
kubectl run perf-client --image=nvcr.io/nvidia/tritonserver:24.01-py3-sdk -- sleep infinity
```

---

## 5. Verification & Testing Commands

Run these commands to validate the setup and trigger the autoscaling/spillover logic.

### Check Infrastructure Health
```bash
# Verify Gateway IP is allocated and Programmed=True
kubectl get gateway triton-gateway

# Verify Gateway routing to Triton (Should return HTTP 200 OK)
GATEWAY_IP=$(kubectl get gateway triton-gateway -o jsonpath='{.status.addresses[0].value}')
kubectl exec perf-client -- curl -v -s $GATEWAY_IP/v2/health/ready

# Verify strict GPU hardware provisioning
kubectl get nodes -L cloud.google.com/gke-accelerator
```

### Run the Load Test
This will hit the Gateway with high concurrency. Because of the `GCPBackendPolicy`, the Gateway will automatically shift traffic away from the G4 pool if it saturates, shedding the load to the L4 pool.

```bash
GATEWAY_IP=$(kubectl get gateway triton-gateway -o jsonpath='{.status.addresses[0].value}')

# Trigger a 5-minute high-concurrency test
kubectl exec perf-client -- sh -c "perf_analyzer -m dlrm -u $GATEWAY_IP:80 -i http \
  --shape dense_x__0:13 \
  --shape sparse_x__1:26 \
  --concurrency-range 128:128 \
  --measurement-interval 300000 > /dev/null 2>&1" &
```

### Monitor the Results
Open separate terminal windows to watch the cluster react to the load test in real-time:

```bash
# Watch the Queue Depth metric directly from the Triton Pods (Updates every 2 seconds)
L4_POD_IP=$(kubectl get pod -l app=triton-l4 -o jsonpath='{.items[0].status.podIP}')
G4_POD_IP=$(kubectl get pod -l app=triton-g4 -o jsonpath='{.items[0].status.podIP}')
while true; do
  clear
  echo "Monitoring Triton Queue Depths..."
  kubectl exec perf-client -- sh -c "echo 'L4 Queue:' \$(curl -s $L4_POD_IP:8002/metrics | grep 'nv_inference_pending_request_count{model=\"dlrm\",version=\"1\"}' | awk '{print \$2}')"
  kubectl exec perf-client -- sh -c "echo 'G4 Queue:' \$(curl -s $G4_POD_IP:8002/metrics | grep 'nv_inference_pending_request_count{model=\"dlrm\",version=\"1\"}' | awk '{print \$2}')"
  sleep 2
done

# Watch the HPA scale up based on Queue Depth
kubectl get hpa -w

# Watch NAP provision new nodes and Pods schedule
kubectl get pods -w

# Check system events for STOCKOUT errors (proving strict hardware isolation)
kubectl get events -n kube-system --sort-by='.lastTimestamp' | grep -i "scale"
```
