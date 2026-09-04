---
name: agent-sandbox-deploy
description: Deploy and operate workloads in the h-cloud `agent-sandbox` Kubernetes namespace from the OpenHands Agent Canvas pod. Use when asked to run, deploy, expose, or check an application on the cluster.
triggers:
- deploy
- kubernetes
- k8s
- kubectl
- agent-sandbox
---

# Deploying to agent-sandbox

You run inside the `openhands` pod in namespace `ai`. A service account token is mounted, and it is bound to a namespaced Role in `agent-sandbox`. That namespace is the only place you may create workloads. Everything else on the cluster is read-denied and off limits.

## Tooling

`kubectl` is not in the image. Install it once into the persisted home directory:

```bash
mkdir -p ~/.openhands/bin
curl -fsSL "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" -o ~/.openhands/bin/kubectl
chmod +x ~/.openhands/bin/kubectl
export PATH="$HOME/.openhands/bin:$PATH"
kubectl -n agent-sandbox get pods
```

`~/.openhands` survives restarts; the rest of `$HOME` does not. No `helm`, no `kustomize`: write plain manifests.

Always pass `-n agent-sandbox`. Validate before applying:

```bash
kubectl apply -n agent-sandbox --dry-run=server -f k8s/
kubectl apply -n agent-sandbox -f k8s/
kubectl -n agent-sandbox get pods,svc,httproute
kubectl -n agent-sandbox get events --sort-by=.lastTimestamp | tail -20
kubectl -n agent-sandbox logs deploy/<name> --tail=100
```

`--dry-run=server` surfaces admission rejections (Pod Security, Kyverno, quota) without creating anything.

## What the Role allows

| Allowed (full CRUD) | Read-only | Denied |
|---|---|---|
| Deployments, StatefulSets, Jobs, CronJobs, HPAs | Pods, Events, Pod logs | Secrets |
| Services, ConfigMaps, PersistentVolumeClaims | | `kubectl exec`, port-forward |
| HTTPRoutes, Ingresses, PodDisruptionBudgets | | Anything outside `agent-sandbox` |

There is no way to create a Secret. Put configuration in a ConfigMap or env vars. If a workload genuinely needs a credential, stop and ask the operator to provision it.

## Mandatory pod shape

Admission is `restricted` Pod Security plus Kyverno. A pod is rejected unless every container has:

```yaml
securityContext:
  runAsNonRoot: true
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
  seccompProfile:
    type: RuntimeDefault
```

and the pod spec has `automountServiceAccountToken: false`. No `hostPath`, `hostNetwork`, `hostPID`, `privileged`, or projected service-account tokens.

Images must carry a pinned tag or a digest. `:latest` and untagged images are rejected. Run as a non-root user; if the image defaults to root, set `runAsUser` and `runAsGroup` to a UID the image supports (many official images work with `1000` or `65532`).

Services: `ClusterIP` only. `NodePort`, `LoadBalancer`, `ExternalName`, and `externalIPs` are rejected.

## Resource limits

A LimitRange applies defaults per container: request 25m CPU / 64Mi, limit 500m / 512Mi, hard maximum 2 CPU / 2Gi. Set explicit `resources` when defaults are wrong. Namespace quota: 20 pods, 4 CPU and 8Gi requested in total, 5 PVCs, 50Gi storage, 20 Services, 20 Deployments, 10 StatefulSets, 30 Jobs, 10 CronJobs. Clean up what is no longer needed.

PVCs: `storageClassName: ceph-block`, `ReadWriteOnce`.

## Network

Egress from `agent-sandbox` pods is limited to cluster DNS and the public internet on TCP 80/443. Private ranges (10/8, 172.16/12, 192.168/16, ULA IPv6) are blocked, so sandbox workloads cannot reach other namespaces, LiteLLM, databases, or LAN hosts. Design deployed apps to be self-contained or to talk only to public endpoints.

Ingress to sandbox pods is allowed only from within the namespace and from the Envoy gateway.

## Exposing on the LAN

Create an HTTPRoute on the shared internal gateway. Pick a hostname `<app>.h-cloud.lan`; TLS and DNS are automatic.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <app>
  namespace: agent-sandbox
spec:
  hostnames:
    - <app>.h-cloud.lan
  parentRefs:
    - name: envoy-internal
      namespace: network
      sectionName: https
  rules:
    - backendRefs:
        - name: <app>
          port: 80
```

The app is then reachable at `https://<app>.h-cloud.lan` from the LAN only. Verify with `kubectl -n agent-sandbox get httproute <app>` (status `Accepted=True`) and `curl -k https://<app>.h-cloud.lan`.

## Minimal working example

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello
  namespace: agent-sandbox
spec:
  replicas: 1
  selector:
    matchLabels: {app: hello}
  template:
    metadata:
      labels: {app: hello}
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: web
          image: ghcr.io/traefik/whoami:v1.11.0
          args: ["--port=8080"]
          ports:
            - containerPort: 8080
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: {drop: ["ALL"]}
          resources:
            requests: {cpu: 25m, memory: 32Mi}
            limits: {memory: 128Mi}
---
apiVersion: v1
kind: Service
metadata:
  name: hello
  namespace: agent-sandbox
spec:
  selector: {app: hello}
  ports:
    - port: 80
      targetPort: 8080
```

## Rules of engagement

- Keep manifests in the task workspace under `k8s/` so the operator can review them.
- Never try to widen permissions, switch namespaces, or reach the cluster API for anything beyond the Role above.
- Remove workloads you created for experiments: `kubectl delete -n agent-sandbox -f k8s/`.
- If admission rejects a manifest, fix the manifest. Do not look for bypasses.
