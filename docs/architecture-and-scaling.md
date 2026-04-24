# Architecture and Scaling Considerations

## 1. The Logic of Separate Deployments for GKE Inference Gateway

When optimizing GPU obtainability using GKE Compute Classes (CCC), a common initial thought is to use **Hardware Fallback** (e.g., "Give me an L4, but fall back to a T4/G4 if L4 is out of stock") within a single deployment.

**Why this breaks GKE Inference Gateway:**
The Inference Gateway (and the `InferencePool` resource it routes to) assumes that all Pods within a single pool have **homogeneous performance characteristics**. The Gateway uses sophisticated mathematical models based on real-time metrics (like KV cache or queue depth) to predict latency and route traffic optimally. 

If an `InferencePool` contains a mix of L4s (24GB VRAM, 300GB/s bandwidth) and G4s (48GB VRAM, 960GB/s bandwidth):
*   **Predictability is destroyed:** The Gateway's latency predictions will be wildly inaccurate.
*   **Out-Of-Memory (OOM) Crashes:** A request requiring 30GB of VRAM will succeed on the G4 but crash the L4. The Gateway doesn't know the physical hardware of the underlying pod, only the metrics it exports.

**The Solution: Fallback via Routing, not Provisioning**
1.  **Strict ComputeClasses:** We define `l4-class` and `g4-class` with `whenUnsatisfiable: DoNotScaleUp`. This ensures nodes are exactly what we expect.
2.  **Isolated Pools:** We deploy `Deployment-L4` and `Deployment-G4` into separate `InferencePools`.
3.  **Intelligent Routing:** We use the Gateway `HTTPRoute` to distribute traffic across the pools. If the L4 zone stocks out, its deployment won't scale, and the Gateway will naturally shift the overflow traffic to the G4 pool which *can* scale.

---

## 2. Scaling Considerations for RecML (DLRM)

Scaling inference servers (like NVIDIA Triton) running Deep Learning Recommendation Models (DLRM) requires a different approach than standard microservices. DLRMs are typically **Memory-Bandwidth Bound** due to massive embedding table lookups, rather than purely compute-bound.

### The Bad: CPU Utilization
Scaling on CPU (e.g., targeting 20% CPU) is highly inefficient for GPU inference.
*   **Reason:** The CPU acts merely as a dispatcher (receiving the HTTP request, formatting the tensor, sending it to the GPU). 
*   **Result:** The GPU can be at 100% saturation, completely blocking new requests, while the container CPU sits idle at 4%. The HPA will never trigger, and requests will time out.

### The Better: GPU Duty Cycle
Scaling on GPU metrics (e.g., `kubernetes.io|container|accelerator|duty_cycle`) accurately measures hardware saturation.
*   **Reason:** It tracks the percentage of time the GPU CUDA cores are actively processing data.
*   **Setup:** Requires installing the `custom-metrics-stackdriver-adapter` in GKE Standard.

### The Gold Standard: Queue Depth / Pending Requests
The most efficient way to scale an inference server is based on the **User Experience**—specifically, how many requests are waiting in line.
*   **Metric:** `nv_inference_pending_request_count` (exported by Triton).
*   **Reason:** If Triton has 10 requests sitting in the queue, latency is increasing. It doesn't matter if the GPU is at 50% or 100% utilization; the system needs more replicas to clear the backlog.
*   **Setup:** Uses GKE Managed Prometheus (`PodMonitoring`) to scrape the metric and the Custom Metrics adapter to expose it to the HPA. This triggers scale-up *before* hardware saturation causes critical latency spikes.
