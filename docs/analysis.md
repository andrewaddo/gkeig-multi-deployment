# Detailed Analysis: Active-Active Multi-Pool Architecture with UBB

This document outlines the pros, cons, and operational realities of implementing an **Active-Active** AI architecture on GKE using **Utilization-Based Balancing (UBB)** across multiple isolated nodepools.

## The Architecture at a Glance
To guarantee High Availability (HA) against physical GPU stockouts in a specific GCP zone, we utilize a decoupled approach managed by a unified Load Balancer:
1.  **Isolated Pools:** We maintain two identical deployments (`triton-torchrec-l4-primary` and `triton-torchrec-l4-secondary`), each governed by its own strict `ComputeClass` with `whenUnsatisfiable: DoNotScaleUp`. This ensures nodes are perfectly homogenous within their pool.
2.  **Unified Entrypoint:** A single Kubernetes `Service` selects all pods across both deployments using a shared label (`shared-app: triton-inference`).
3.  **Active-Active UBB Routing:** We apply a `GCPBackendPolicy` to the unified service. The Regional Load Balancer natively reads the `gke.gpu_duty_cycle` metric and continuously spreads incoming traffic to maintain an even 80% utilization across all pods in all pools.
4.  **Synchronized Scaling:** Because the load is spread uniformly, the independent HPAs for both deployments trigger scale-ups simultaneously when demand spikes.

---

## "Spreading" (Active-Active) vs. "Spillover" (Waterfall)

When using multiple `Deployments`, the Gateway's behavior depends entirely on how you configure the `GCPBackendPolicy`.

### 1. The Active-Active Strategy (Current Implementation)
By using a single **Unified Service** and setting a `maxUtilizationPercent` (e.g., 80%), the Load Balancer aggressively spreads traffic to ensure no single pod exceeds that threshold.
*   **Pros:** 
    *   **Maximum HA:** If one GCP zone completely runs out of L4 GPUs, the other deployment simply continues handling the spread load without requiring DNS updates or manual intervention.
    *   **Predictable Scaling:** HPAs scale gracefully and synchronously.
*   **Cons:**
    *   **Cost:** You must maintain a `minReplicas: 1` for every deployment 24/7.
    *   **Diluted Batching:** Distributing traffic widely means Triton receives fewer concurrent requests per pod, slightly reducing its ability to perform massive Dynamic Batching matrix optimizations.

### 2. The Spillover Strategy (Alternative)
If you prefer cost-efficiency over immediate HA, you would use **Two Separate Services** and attach a capacity policy only to the primary service. The Load Balancer would send 100% of traffic to the primary pool until its GPUs were saturated, and only *then* "spill over" to the secondary pool.
*   **Pros:** 
    *   **Cost Efficiency (Scale-to-Zero):** The secondary pool can sit at 0 replicas until the primary is genuinely full or suffering a stockout.
    *   **Maximized Batching:** Funneling all traffic into the primary pool maximizes Triton's queue depth, enabling the largest, most efficient CUDA batching.
*   **Cons:**
    *   **Spike Vulnerability:** If a sudden traffic spike hits, the secondary pool will take minutes to scale from 0 to 1, causing the primary pool to suffer `504 Gateway Timeouts` while the secondary hardware provisions.

---

## ⚠️ CRITICAL LIMITATION: Zonal NEG Granularity
A common misconception is that UBB routes traffic based on **individual pod utilization**. In reality, standard GKE Gateway UBB operates at the **Zonal Network Endpoint Group (NEG)** level.

- **The Aggregate Average:** The Load Balancer reads the `gke.gpu_duty_cycle` from all pods in a zone and calculates a single **Zonal Average**.
- **The Dilution Problem:** If you mix heterogeneous hardware (e.g., NVIDIA L4 and NVIDIA RTX 6000) in the same zone, a heavily loaded "slow" pod's utilization will be masked by an idle "fast" pod. The Load Balancer will continue sending traffic to the zone because the *average* appears healthy.
- **Scaling Impact:** This prevents the HPA from scaling the two pools independently if they are co-located in the same zones behind a single unified service.

### Recommendation: Zonal Isolation Strategy
To support heterogeneous hardware (e.g., L4 and G4 GPUs) without migrating to the complex GKE Inference Gateway, you should implement **Zonal Isolation**:
1.  **Pin Hardware to Zones:** Use `ComputeClass` zonal constraints to ensure `Pool-A (L4)` lives only in `Zone-A`, and `Pool-B (G4)` lives only in `Zone-B`.
2.  **Clean Metric Buckets:** This ensures each Zonal NEG contains perfectly homogeneous hardware. The Load Balancer can then accurately compare the utilization of the "Slow" zone vs the "Fast" zone.
3.  **Predictable Spillover:** When the L4s in Zone-A reach the `maxUtilizationPercent`, the Load Balancer will naturally spill over traffic to the G4s in Zone-B.

#### References
*   [GKE Gateway API Concepts](https://cloud.google.com/kubernetes-engine/docs/concepts/gateway-api) - Official documentation on routing and capacity management in GKE.
*   [GKE Network Endpoint Groups (NEGs)](https://cloud.google.com/kubernetes-engine/docs/how-to/standalone-neg) - Explains how Kubernetes Services are translated into Zonal NEGs, which is the root cause of the metric dilution issue.

---

## Operational Challenges & Solutions

### 1. Triton Resource Starvation (504 Timeouts)
During testing, we discovered that RecML payloads (JSON parsing, embedding lookups) are heavily CPU-bound before they even reach the GPU.
*   **The Problem:** With only `500m` CPU limits, a burst of parallel requests caused the CPU to stall. The HTTP connection timed out (504 Gateway Timeout) before Triton could ship the tensors to the GPU.
*   **The Solution:** We aligned the pod resources with the physical node (`g2-standard-4`), allocating `4 CPU` and `8Gi RAM` to Triton. We also updated the Triton `instance_group` configuration to spawn `count: 4` model instances, allowing it to process multiple threads concurrently. This completely resolved the timeouts.

### 2. Health Check Failures
When using GKE Gateways with inference servers like Triton, the default Gateway health check pings the root path (`/`). Because Triton returns a `404 Not Found` on `/`, the Load Balancer will mark the backends as broken.
*   **The Solution:** You must deploy a `HealthCheckPolicy` CRD (as shown in this repository) to explicitly instruct the Gateway to probe `/v2/health/ready`.

### 3. Metric Propagation Delay
GKE's metric pipeline and the Google Cloud Load Balancer update routing tables on a roughly 60-second cycle. 
*   **The Reality:** If you launch a sudden, massive burst of traffic from absolute zero, the Load Balancer will initially dump all traffic onto a single pod until the first metric report arrives. 
*   **The Mitigation:** Setting `maxUtilizationPercent: 80` informs the Load Balancer of the target ceiling, allowing it to react more aggressively once metrics begin flowing, bringing the system back into perfect Active-Active balance within 2 minutes.
