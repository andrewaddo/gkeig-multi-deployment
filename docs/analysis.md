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

### 1. True GPU "Obtainability" Without Performance Chaos
By explicitly splitting L4 and G4 workloads, we solve the single-region capacity problem safely. If G4 instances stock out in `us-central1`, the G4 deployment simply stops scaling. The GKE Gateway will detect rising queues/latency on the G4 pool and dynamically shift overflow traffic to the L4 pool (which can still scale). This gives you the resilience of fallback *without* mixing hardware types in a single autoscaling group.

### 2. Accurate AI-Aware Routing
The GKE Inference Gateway relies on metrics like KV cache utilization or queue depth to make smart routing decisions. These mathematical models assume homogeneous backend capacity. By isolating L4 and G4 into separate `InferencePools`, the Gateway's algorithms remain accurate, preventing Out-Of-Memory (OOM) crashes and latency spikes that occur when a Gateway accidentally sends a heavy request to a weak GPU.

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

### 4. Metric Propagation Delays
While the GKE Gateway reacts to internal inference metrics in real-time, the HPA scaling path (Triton -> Managed Prometheus -> Cloud Monitoring -> Custom Metrics Adapter -> HPA) introduces a 1 to 3-minute delay. In highly bursty RecML environments, you may need to over-provision slightly to absorb the load while the HPA pipeline catches up.

---

## Conclusion
For production RecML environments restricted to a single region, decoupling GPU families into isolated `InferencePools` with independent HPAs is the safest, most performant way to utilize the GKE Inference Gateway. It trades slightly higher baseline costs and configuration complexity for rock-solid predictability and built-in resilience against physical GCP hardware stockouts.
