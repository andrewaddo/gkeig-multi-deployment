# Detailed Analysis: Multi-GPU Architecture with GKE Inference Gateway

This document outlines the pros, cons, and operational realities of the specific architecture implemented in this project: **Using the GKE Inference Gateway to unify multiple, independent GPU deployments (e.g., L4 and G4), each governed by its own strict `ComputeClass` and independent Horizontal Pod Autoscaler (HPA).**

## The Architecture at a Glance
Instead of using a single deployment with a "fallback" ComputeClass (which mixes GPU types and breaks Inference Gateway latency predictions), we utilize a decoupled approach:
1.  **Isolated Pools:** One deployment exclusively for L4 (`triton-torchrec-l4`), one exclusively for G4 (`triton-torchrec-g4`).
2.  **Strict Provisioning:** `ComputeClasses` are locked with `whenUnsatisfiable: DoNotScaleUp`.
3.  **Independent Scaling:** Each pool has its own HPA (scaling on Queue Depth / GPU utilization).
4.  **Unified Entrypoint:** The GKE Inference Gateway routes traffic across both pools.

---

## Pros of the Decoupled Multi-GPU Architecture

### 1. Safe Hardware Isolation
By explicitly splitting L4 and G4 workloads, we solve the single-region capacity problem safely. If G4 instances stock out in `us-central1`, the G4 deployment simply stops scaling without polluting its pool with incorrect fallback hardware. This preserves the homogeneity required for accurate AI-aware load balancing *within* the pool.

### 2. A/B Testing vs. Dynamic Spillover Routing
When using multiple `InferencePools`, the Gateway's behavior depends entirely on how you configure the `HTTPRoute`:
*   **Static Weighted Routing (Our Setup):** By explicitly setting `weight: 50` for L4 and `weight: 50` for G4, the Gateway performs strict partitioning. **Warning:** If G4 capacity stocks out and queues rise, the Gateway will *not* dynamically shift traffic to L4. It will blindly continue sending 50% of traffic to the overwhelmed G4 pool. This is excellent for A/B testing or partitioned billing, but poor for handling stockouts.
*   **Dynamic Overflow / Least-Request Routing:** To achieve true "spillover" (where the Gateway detects G4 is full and automatically routes to L4), you must avoid static weights. This requires advanced Gateway API configurations (such as global `least_request` load balancing policies or `InferenceObjectives` that define primary/fallback SLAs) so the Gateway evaluates queue depth *across* all pools globally, rather than just within a specific pool.

### 3. Graceful Degradation during Hardware Stockouts
During our testing, we explicitly encountered `RESOURCE_POOL_EXHAUSTED` (Stockout) for the G4 (`nvidia-rtx-pro-6000`) hardware. Because the HPAs are independent, the L4 HPA successfully provisioned new nodes and handled the load, while the G4 HPA safely queued pending pods without crashing the primary service. 

### 4. A/B Testing & Heterogeneous Pricing
This architecture allows you to apply different `InferenceObjective` priorities or `HTTPRoute` weights. You can route "Premium" users to the high-bandwidth G4 pool, and "Free" tier users to the cost-effective L4 pool, scaling their respective HPAs entirely independently based on distinct user demands.

---

## Cons & Operational Challenges of this Setup

### 1. The "Oscillation" Risk between Gateway and HPA
Because routing (Gateway) and scaling (HPA) are decoupled, they can sometimes fight each other if not tuned perfectly. 
*   **Example:** A massive traffic spike hits. The Gateway sends traffic to the G4 pool. The G4 HPA triggers a scale-up, but hits a GCP stockout. The Gateway sees G4 queues rising and shifts traffic to the L4 pool. The L4 HPA now triggers a scale-up. If the G4 capacity suddenly frees up, the G4 pods spin up, the Gateway shifts traffic *back* to G4, leaving the newly provisioned L4 nodes idle. 
*   **Mitigation:** Requires very careful tuning of HPA stabilization windows and Gateway routing weights.

### 2. Baseline Cost Inefficiencies
Because you are maintaining independent deployments to ensure high availability across hardware families, you must run at least `minReplicas: 1` for *every* GPU type in your architecture. You are paying for a baseline L4 and a baseline G4 24/7, rather than a single unified deployment that might only cost 1x L4 during low-traffic periods.

### 3. Configuration Sprawl
The number of Kubernetes manifests multiplies. For every new hardware family you want to support (e.g., adding an A100 pool), you must create a new:
*   `ComputeClass`
*   `Deployment`
*   `Service`
*   `InferencePool`
*   `HorizontalPodAutoscaler`
*   `PodMonitoring` (for custom metrics)

### 5. Health Check Failures (503 Errors)
When using GKE Gateways with inference servers like Triton, the default Gateway health check pings the root path (`/`). Because Triton returns a `404 Not Found` on `/`, the Load Balancer will mark the backends as broken, resulting in continuous `503 Service Unavailable` errors at the Gateway IP.
*   **Mitigation:** You must deploy a `HealthCheckPolicy` CRD (as shown in this repository) to explicitly instruct the Gateway to probe `/v2/health/ready`.

### 6. The Endpoint Picker (EPP) Controller Requirement
To achieve dynamic cross-pool spillover, the GKE Inference Gateway requires an active **Endpoint Picker (EPP)** logic. 
*   In a single-cluster setup, this is typically provided via a Helm-based controller that the `InferencePool` must reference.
*   In the newly available **Multi-cluster GKE Inference Gateway (Preview)**, this logic is managed globally by the Google Cloud Load Balancer via the `networking.gke.io` API group.

### 7. Fleet Membership and API Groups
During implementation, we identified a strict boundary between API groups:
*   **`inference.networking.k8s.io`**: Used for local pool management within a single cluster.
*   **`networking.gke.io`**: Used for multi-cluster extensions (like `GCPInferencePoolImport`). 
The error `group networking.gke.io is not supported` occurs if these multi-cluster resources are used in a cluster that is not registered as a **Config Cluster** within a Google Cloud Fleet. For production-grade AI-aware routing across heterogeneous hardware, registering the cluster to a Fleet and enabling Multi-cluster Gateway features is the recommended (Preview) path.

---

## Conclusion
For production RecML environments restricted to a single region, decoupling GPU families into isolated `InferencePools` with independent HPAs is the safest, most performant way to utilize the GKE Inference Gateway. While single-cluster setups are possible, the most advanced AI-aware routing features (global metric-based balancing) are currently being delivered through the **Multi-cluster GKE Inference Gateway** Preview, which utilizes Fleet-based management to unify disparate GPU pools.
