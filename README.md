# GKE Inference Gateway: Active-Active Multi-Pool GPU Routing

This project demonstrates how to build a highly available, **Active-Active** AI inference architecture on Google Kubernetes Engine (GKE). It utilizes the GKE Gateway API and **Utilization-Based Balancing (UBB)** to seamlessly route traffic across multiple independent GPU nodepools, ensuring uniform hardware utilization and synchronized autoscaling.

## Overview

When running critical AI workloads like RecML (DLRMs) or LLMs, relying on a single nodepool or deployment can be risky during zone-specific hardware stockouts. This project solves that by demonstrating how to:

1.  **Isolate Hardware Pools:** Use strict `ComputeClasses` to create independent primary and secondary nodepools (both using NVIDIA L4 GPUs).
2.  **Unify the Endpoint:** Group pods from multiple distinct deployments under a single, unified Kubernetes Service.
3.  **Active-Active UBB Routing:** Apply a `GCPBackendPolicy` using the native `gke.gpu_duty_cycle` metric. The Google Cloud Load Balancer natively reads the GPU utilization of every pod and spreads traffic dynamically to maintain an even 80% saturation across all pools.
4.  **Synchronized Autoscaling:** As the Load Balancer spreads traffic evenly, the independent HPAs for both pools trigger scaling operations simultaneously.

## Current Architecture

- **Cluster:** GKE Standard with Node Auto-Provisioning (NAP) enabled.
- **ComputeClasses:** 
    - `l4-class-primary`: Targets `machineFamily: g2` (NVIDIA L4).
    - `l4-class-secondary`: Targets `machineFamily: g2` (NVIDIA L4).
- **Workload:** NVIDIA Triton Inference Server running a TorchScript DLRM model (generated dynamically via `initContainer`). Optimized with 4 CPUs, 8Gi RAM, and an internal Triton concurrency of 4 instances per GPU.
- **Networking:** GKE Gateway API (`gke-l7-rilb`) routing to a `triton-unified-svc`.
- **Load Balancing:** UBB configured via `GCPBackendPolicy` targeting a `maxUtilizationPercent` of 80% on the GPU duty cycle.
- **Scaling:** HPA configured on standard CPU metrics (target 70%) for rapid, reliable scale-up during inference bursts.

## Documentation

For a deep dive into the architectural reasoning, the trade-offs between "Spillover" vs "Active-Active", and performance optimizations, read:
*   **[Detailed Analysis](docs/analysis.md)**
*   **[Architecture & Scaling Considerations](docs/architecture-and-scaling.md)**

## Setup Instructions

A fully automated bash script is provided to recreate this environment from scratch.

```bash
chmod +x scripts/setup.sh
./scripts/setup.sh
```

## Verification & Testing

To verify the Active-Active behavior, you can run a sustained load test using the deployed `perf-client` pod.

### Run the Load Test
```bash
GATEWAY_IP=$(kubectl get gateway triton-gateway -o jsonpath='{.status.addresses[0].value}')

# Generate a continuous load that will push CPU/GPU utilization up
kubectl exec perf-client -- sh -c "
cat << 'EOF' > /tmp/load.sh
for i in \$(seq 1 1000); do
  curl -s -X POST http://$GATEWAY_IP:80/v2/models/dlrm/infer -H \"Content-Type: application/json\" -d '{\"inputs\":[{\"name\":\"dense_x__0\",\"shape\":[1,13],\"datatype\":\"FP32\",\"data\":[0,0,0,0,0,0,0,0,0,0,0,0,0]},{\"name\":\"sparse_x__1\",\"shape\":[1,26],\"datatype\":\"INT64\",\"data\":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}]}' > /dev/null &
  sleep 0.2
done
wait
EOF
chmod +x /tmp/load.sh
/tmp/load.sh &
"
```

### Monitor the Results
In a separate terminal, watch the HPAs. Because the Gateway uses UBB to evenly spread the traffic based on GPU duty cycle, you will see both the primary and secondary deployments' CPU metrics rise together and scale simultaneously.

```bash
kubectl get hpa -w
```
