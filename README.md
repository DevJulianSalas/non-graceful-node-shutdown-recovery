# K8s Non-Graceful Node Shutdown Recovery — Redis on Longhorn

## 🏗️ Architecture & The "Why"

In a production Kubernetes environment, node shutdowns can be **graceful** (controlled via systemd inhibitor locks) or **non-graceful** (hardware failures, kernel panics, or forceful power cuts). While Deployment workloads recover easily, **StatefulSets backed by Persistent Volumes (PVs)** hit a critical wall during a non-graceful shutdown:

1. The kubelet on the dead node cannot report back to the control plane.
2. The StatefulSet Pod gets stuck in a `Terminating` state.
3. `VolumeAttachments` are not released from the dead node.
4. The StatefulSet cannot spin up a replacement Pod on a healthy node because it cannot attach the required volume.

**Goal:** This repository simulates a non-graceful node failure and uses the `node.kubernetes.io/out-of-service` taint to forcefully detach the volumes and recover the stateful workload onto a healthy node — **with the Redis dataset intact**.

---

## 🧱 Lab Topology

| Component | Details |
|---|---|
| VMs | 3 Multipass instances: `control-plane`, `worker-stateful`, `worker-stateless` |
| Node specs | control-plane: 2 CPU / 2G RAM / 10G disk · workers: 2 CPU / 2G RAM / 30G disk |
| Kubernetes | v1.34 via kubeadm, Flannel CNI (`10.244.0.0/16` pod subnet) |
| Storage | Longhorn v1.12.1, StorageClass `longhorn-recovery` (2 replicas, `Retain`) |
| Workload | Redis 8 StatefulSet (1 replica, AOF enabled) in namespace `cache` |
| Producer/Consumer | Two Deployments pinned to the stateless worker via nodeSelector |

```
redis-0
  │
  └── /data
       │
       └── PVC: redis-data-redis-0-redis-0
             │
             └── PV: pvc-c48882db-...
                   │
                   └── VolumeAttachment
                         │
                         ├── attacher: driver.longhorn.io
                         ├── node: worker-stateful
                         └── attached: true
```

---

## 📋 Prerequisites

*   **Multipass** installed locally (`brew install multipass` on macOS).
*   ~50 GB free disk and ~6 GB RAM for the three VMs.
*   **kubectl** — either the one preconfigured inside the `control-plane` VM (recommended) or a local one pointed at the cluster via `~/.kube/config`.
*   K8s v1.28+ for the GA `out-of-service` features (this lab uses v1.34).

---

## 🚀 Lab Runbook

### Step 0 — Provision the cluster

Create the nodes **in this order** (control-plane first, then the stateless worker, then the stateful worker):

```bash
./pipeline-cluster.sh control-plane
./pipeline-cluster.sh worker worker-stateless
./pipeline-cluster.sh worker worker-stateful
```

> Provisioning the control-plane automatically installs Longhorn, defines `longhorn-recovery`, and applies all manifests in `code/manifests/` (Redis StatefulSet + producer/consumer). The producer/consumer Deployments are pinned via `nodeSelector` to the stateless worker (`worker-stateless`).

Verify the cluster is healthy:

```bash
kubectl get nodes -o wide
```

Expected output (pod IPs/roles will vary):

```text
NAME              STATUS   ROLES           AGE   VERSION   INTERNAL-IP      OS-IMAGE
control-plane     Ready    control-plane   5m    v1.34.x   192.168.252.xx   Ubuntu 24.04
worker-stateful   Ready    <none>          3m    v1.34.x   192.168.252.xx   Ubuntu 24.04
worker-stateless   Ready    <none>          1m    v1.34.x   192.168.252.xx   Ubuntu 24.04
```

> **New cluster?** `scripts/cluster-join.sh` contains a **hardcoded control-plane IP and bootstrap token** from a previous run. For a fresh cluster, regenerate them on the control-plane with `sudo kubeadm token create --print-join-command` and update the script before creating workers.

---

### Step 1 — Deploy & verify the stateful workload

The manifests are applied automatically during provisioning, but you can re-apply them at any time (edits to `code/` are visible in the VM immediately):

```bash
kubectl apply -f code/manifests/storage-class.yaml
kubectl apply -f code/manifests/redis-server.yaml
kubectl apply -f code/manifests/producer-consumer.yaml
```

Verify the workload and its storage:

```bash
kubectl get pods -n cache -o wide
kubectl get pvc -n cache
kubectl get storageclass
kubectl get volumeattachments -o wide
```

Expected output:

```text
NAME                                     STATUS   VOLUME              CAPACITY   ACCESS MODES   STORAGECLASS      AGE
redis-data-redis-0-redis-0               Bound    pvc-c48882db-...    1Gi        RWO            longhorn-recovery 4m
```

Note which node `redis-0` landed on — it should be **`worker-stateful`** (the node we will kill). If it scheduled elsewhere, drain/pin it before continuing. Also you could run simultaneously the step 0 for work node creation in each own terminal tab.

---

### Step 2 — Seed a marker key

Write a value that must survive the node failure:

```bash
kubectl exec -n cache redis-0 -- redis-cli SET node-failure-test "survives-longhorn-recovery"
kubectl exec -n cache redis-0 -- redis-cli GET node-failure-test
```

Expected output:

```text
OK
survives-longhorn-recovery
```

Confirm Redis persistence is on (AOF) and inspect the volume contents:

```bash
kubectl exec -n cache redis-0 -- redis-cli INFO persistence | grep aof
kubectl exec -n cache redis-0 -- ls -lahR /data
```

Expected output (`/data` tree):

```text
/data:
total 32K
drwxr-xr-x    4 root     root        4.0K Sep 14 22:10 .
drwxr-xr-x    1 root     root        4.0K Sep 14 22:00 ..
drwxr-xr-x    2 root     root        4.0K Sep 14 22:00 appendonlydir
-rw-r--r--    1 root     root         137 Sep 14 22:10 dump.rdb
drwx------    2 root     root       16.0K Sep 14 22:00 lost+found

/data/appendonlydir:
total 28K
drwxr-xr-x    2 root     root        4.0K Sep 14 22:00 .
drwxr-xr-x    4 root     root        4.0K Sep 14 22:10 ..
-rw-r--r--    1 root     root          88 Sep 14 22:00 appendonly.aof.1.base.rdb
-rw-r--r--    1 root     root       11.3K Sep 14 22:13 appendonly.aof.1.incr.aof
-rw-r--r--    1 root     root         102 Sep 14 22:00 appendonly.aof.manifest

/data/lost+found:
total 20K
drwx------    2 root     root       16.0K Sep 14 22:00 .
drwxr-xr-x    4 root     root        4.0K Sep 14 22:10 ..
```

Expected output (`aof` grep — key lines):

```text
aof_enabled:1
aof_last_write_status:ok
aof_current_size:11118
```

---

### Step 3 — Simulate a non-graceful node shutdown

SSH into the stateful worker (or use `multipass exec`) and force a power-off. **Do NOT use `multipass stop`** — that follows the graceful shutdown path. `poweroff -f` skips systemd's graceful node-shutdown inhibitor logic and bypasses kubelet's 2-phase termination.

```bash
# On your host:
multipass exec worker-stateful -- sudo poweroff -f
# or: ssh ubuntu@worker-stateful "sudo poweroff -f"
```

---

### Step 4 — Observe the "stuck" state

The node goes `NotReady` (may take ~180s for the node lease to expire), and the StatefulSet pod gets stuck in `Terminating`:

```bash
kubectl get nodes
kubectl get pods -n cache -o wide
kubectl get volumeattachments -o wide
```

Expected output (pod):

```text
NAME       READY   STATUS        RESTARTS   AGE   IP            NODE              NOMINATED NODE   READINESS GATES
redis-0    1/1     Terminating   0          17m   10.244.1.22   worker-stateful   <none>           <none>
```

The `VolumeAttachment` is still `attached: true` on the dead node — the scheduler will **not** start a replacement `redis-0` on a healthy node because the volume is locked to `worker-stateful`.

---

### Step 5 — Apply the `out-of-service` taint and recover

> ⚠️ **Verify the node is really dead first — data corruption risk.** `NotReady` does **not** mean the node stopped working. A node can be `NotReady` while it is still fully running its workload (e.g., a network partition that prevents it from reporting health to the control plane but leaves the kubelet, redis, and its writes to the block device alive). Applying the `out-of-service` taint on such a node forcefully detaches the volume and starts `redis-0` on another node — and **two processes writing to the same block volume will corrupt the data**. Only apply the taint after you have confirmed, out-of-band, that the node is truly powered off and no processes are writing to the storage (console access, ping, VM state, `poweroff -f` as we did above). This is exactly why the taint is the last step of the procedure, not the first.

Tell the control plane the node is permanently out of service. This forcefully deletes the pod and detaches the volume:

```bash
kubectl taint node worker-stateful node.kubernetes.io/out-of-service=nodeshutdown:NoExecute
```

Watch the recovery in one pane:

```bash
watch -n 1 '
echo "=== NODES ==="
kubectl get nodes

echo
echo "=== CACHE PODS ==="
kubectl get pods -n cache -o wide

echo
echo "=== VOLUME ATTACHMENTS ==="
kubectl get volumeattachments -o wide

echo
echo "=== LONGHORN VOLUMES ==="
kubectl -n longhorn-system get volumes.longhorn.io -o wide

echo
echo "=== LONGHORN REPLICAS ==="
kubectl -n longhorn-system get replicas.longhorn.io \
  -o custom-columns="NAME:.metadata.name,VOLUME:.spec.volumeName,NODE:.spec.nodeID,STATE:.status.currentState"
'
```

Expected timeline: the old pod is force-deleted, Longhorn detaches the volume from `worker-stateful`, and a **new `redis-0`** comes up `Running` on a healthy node with the same PVC/PV.

---

### Step 6 — Verify the data survived

```bash
kubectl get pods -n cache -o wide
kubectl exec -n cache redis-0 -- redis-cli GET node-failure-test
```

Expected output:

```text
survives-longhorn-recovery
```

Expected output (pod — note the new node; IPs will differ per run):

```text
NAME       READY   STATUS    RESTARTS   AGE   IP            NODE              NOMINATED NODE   READINESS GATES
redis-0    1/1     Running   0          1m    10.244.1.28   worker-stateless   <none>           <none>
```

The `GET` returning the seeded value proves the **dataset survived** the node failure and storage re-attach. Cross-check AOF again if you want extra evidence (`redis-cli INFO persistence | grep aof`).

---

### Step 7 — Restore the node and repeat the loop

To bring `worker-stateful` back and run the experiment again:

```bash
# Power the VM back on from your host
multipass start worker-stateful

# Wait until the node reports Ready again
kubectl get nodes -w

# Remove the taint (note the trailing dash)
kubectl taint node worker-stateful node.kubernetes.io/out-of-service:NoExecute-

# Re-run the persistence check
kubectl exec -n cache redis-0 -- redis-cli GET node-failure-test
```

The redo loop is: taint → `poweroff -f` → watch it get stuck → re-apply taint if the node restarted → recover → verify `GET` → restart node → remove taint.

---

## 🧹 Cleanup

```bash
# Remove the taint so the node can rejoin cleanly first (if it's powered on)
kubectl taint node worker-stateful node.kubernetes.io/out-of-service:NoExecute-

# Delete all VMs and purge state
./pipeline-cluster.sh delete
# ...or just one VM
./pipeline-cluster.sh delete worker-stateful
```

---

## 💡 Troubleshooting & Admin Notes

*   **PVC stuck `Pending`** → Longhorn isn't ready yet. Check `kubectl -n longhorn-system get pods`, and confirm `open-iscsi`/`iscsid` is running on the workers (cloud-init enables it).
*   **Producer/consumer pods `Pending`** → they are pinned via `nodeSelector: kubernetes.io/hostname: worker-stateless`. They only schedule on that exact node name — create the worker with that name.
*   **`taint-stateful` role in `pipeline-cluster.sh` is not implemented** — running it prints usage and exits. Apply taints manually with `kubectl`.
*   **Priority Classes in graceful shutdowns:** if the shutdown were *graceful*, K8s honors `PriorityClass`. To control shutdown ordering (web apps before databases), enable the `GracefulNodeShutdownBasedOnPodPriority` feature gate and assign priorities.
*   **Monitoring shutdowns:** in Prometheus you can track `graceful_shutdown_start_time_seconds` and `graceful_shutdown_end_time_seconds` to audit how often nodes are evicted gracefully vs. forcefully.
*   **`retain` on the StorageClass** means deleting the PVC/PV is intentional — the PV will not be auto-reclaimed.