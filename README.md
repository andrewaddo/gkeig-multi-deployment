# GKE Inference Gateway: Single-Region Multi-Deployment GPU Optimization

This project explores using the GKE Inference Gateway and Custom Compute Classes (CCC) to optimize GPU resource utilization and availability across multiple deployments in a single region.

## Overview

In scenarios where workloads must remain within a single region, optimizing for GPU "obtainability" and "utilization" is critical. This project demonstrates how to:

1.  **Leverage Compute Classes (CCC):** Define a prioritized list of GPU types (e.g., L4, G2) to ensure the Cluster Autoscaler can provide resources even if the preferred type is unavailable.
2.  **Use GKE Inference Gateway:** Route traffic intelligently across multiple `InferencePools` based on real-time metrics (like KV cache utilization) rather than simple round-robin.
3.  **Consolidate Resources:** Maximize GPU utilization by sharing resources across deployments while maintaining isolation and priority.

## Current Architecture (GKE Standard)

- **Cluster:** GKE Standard with Node Auto-Provisioning (NAP) enabled.
- **ComputeClasses:** 
    - `l4-class`: Targets `machineFamily: g2` and `nvidia-l4`.
    - `g4-class`: Targets `machineFamily: g4` and `nvidia-rtx-pro-6000`.
- **Workload:** NVIDIA Triton Inference Server running a TorchScript DLRM model (dynamically generated via `initContainer`).
- **Networking:** GKE Gateway API (`gke-l7-rilb`) with weighted traffic splitting between L4 and G4 pools.
- **Scaling:** HPA configured with aggressive CPU thresholds to trigger NAP provisioning.

## Documentation

For a deep dive into the architectural reasoning (why we isolate deployments per GPU type) and scaling strategies (CPU vs GPU vs Queue Depth), please read:
**[Architecture and Scaling Considerations](docs/architecture-and-scaling.md)**

## Setup Instructions

A fully automated bash script is provided to recreate this environment from scratch. It provisions a GKE Standard cluster with Node Auto-Provisioning configured for L4 and RTX-6000 (G4) GPUs.

```bash
chmod +x scripts/setup.sh
./scripts/setup.sh
```

## Verification & Testing

### 1. Verify GPU Provisioning (L4 vs G4)
Once the setup script finishes and pods are running, verify that GKE successfully provisioned distinct nodes for the L4 and G4 classes:

```bash
kubectl get nodes -L cloud.google.com/gke-accelerator
```
*Sample Output:*
```text
NAME                                                  STATUS   ROLES    AGE   VERSION               GKE-ACCELERATOR
gke-ducdo-gkeig-mult-nap-g2-standard--de064c0f-fk75   Ready    <none>   108m  v1.35.1-gke.1396002   nvidia-l4
gke-ducdo-gkeig-mult-nap-g4-standard--dffd03a8-czl6   Ready    <none>   67m   v1.35.1-gke.1396002   nvidia-rtx-pro-6000
```

### 2. Trigger the Performance Load Test
To test the autoscaling (HPA) and the Gateway's routing, execute the NVIDIA `perf_analyzer` from the client pod. This simulates high-concurrency requests against the synthetic DLRM model.

```bash
L4_IP=$(kubectl get svc triton-l4-svc -o jsonpath='{.spec.clusterIP}')
G4_IP=$(kubectl get svc triton-g4-svc -o jsonpath='{.spec.clusterIP}')

# Send high concurrency load to both pools simultaneously
kubectl exec perf-client -- sh -c "\
  perf_analyzer -m dlrm -u $L4_IP:8000 -i http --shape dense_x__0:13 --shape sparse_x__1:26 --concurrency-range 16:16 --measurement-interval 300000 > /dev/null 2>&1 & \
  perf_analyzer -m dlrm -u $G4_IP:8000 -i http --shape dense_x__0:13 --shape sparse_x__1:26 --concurrency-range 16:16 --measurement-interval 300000 > /dev/null 2>&1 &"
```

### 3. Monitor HPA Reaction
Watch the HPA react to the load spike. Notice how the GPU utilization (`duty_cycle`) quickly hits the 60% threshold, triggering GKE to provision new nodes.

```bash
kubectl get hpa -w
```
*Sample Output:*
```text
NAME            REFERENCE                       TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
triton-g4-hpa   Deployment/triton-torchrec-g4   88%/60%       1         5         5          121m
triton-l4-hpa   Deployment/triton-torchrec-l4   72%/60%       1         5         3          121m
```

### 4. Expected Test Results and Auto-Scaling Behavior

During the load test, you should observe the following lifecycle:

1.  **Scale Up (HPA Trigger):** As `perf_analyzer` saturates the Triton servers, the HPA will detect the spike in metrics and increase the desired replicas (e.g., from 1 to 5).
2.  **Node Provisioning (NAP):** Because each pod strictly requests 1 GPU, GKE Node Auto-Provisioning (NAP) will attempt to create new physical nodes.
    *   **Success (L4):** The `g2-standard-4` (L4) nodes will provision successfully, and new L4 pods will transition to `Running`.
    *   **Stockout Handling (G4):** High-end GPUs like the RTX 6000 Ada (G4) often face physical capacity constraints in specific GCP zones. You may see the new G4 pods remain in a `Pending` state. If you inspect the system events (`kubectl get events -n kube-system`), you will see:
        > `Failed adding 2 nodes... due to OutOfResource.RESOURCE_POOL_EXHAUSTED... (state:STOCKOUT, resource type:compute)`
    *   **Why this is good:** Because we used strict `ComputeClasses` with `whenUnsatisfiable: DoNotScaleUp`, the system correctly queues the pods rather than silently falling back to inferior hardware, preserving the homogeneity required for the Gateway's routing logic.
3.  **Scale Down (Cool Down):** Once the `perf_analyzer` test concludes, the load drops to 0. After the configured stabilization window, the HPA will scale the deployments back down to 1 replica. GKE will then detect the empty GPU nodes and automatically delete them to eliminate idle costs.
