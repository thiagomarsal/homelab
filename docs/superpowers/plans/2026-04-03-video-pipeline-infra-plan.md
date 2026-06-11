# Video Pipeline Infrastructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Kafka (Strimzi KRaft), Redis, and MinIO on k3s-worker-1 (pve04) with Ansible playbooks for on-demand lifecycle management.

**Architecture:** All components run exclusively on k3s-worker-1 via `nodeSelector` + `on-demand=true:NoSchedule` toleration. Helm values files live in the repo. Ansible playbooks orchestrate deploy and teardown in dependency order. ZFS data at `/mnt/storage/minio` survives teardown cycles.

**Tech Stack:** Strimzi 0.45.0 (Kafka 3.9.0, KRaft mode), Bitnami Redis (20.x), MinIO (5.x), Longhorn (Kafka/Redis PVCs), ZFS local PV (MinIO), Ansible `kubernetes.core` collection.

> **Spec correction:** Design spec used `k3s-agent-1` as hostname. Actual Kubernetes node name is `k3s-worker-1` — use this everywhere.

---

## File Map

```
kubernetes/
  apps/
    kafka/
      namespace.yaml         CREATE — kafka namespace
      values.yaml            CREATE — Strimzi operator Helm values
      kafka-cluster.yaml     CREATE — KafkaNodePool + Kafka CRs
    redis/
      namespace.yaml         CREATE — redis namespace
      values.yaml            CREATE — Bitnami Redis Helm values
  storage/
    minio/
      namespace.yaml         CREATE — minio namespace
      pv.yaml                CREATE — Local PersistentVolume (ZFS)
      pvc.yaml               CREATE — PersistentVolumeClaim
      values.yaml            CREATE — MinIO Helm values

ansible/
  inventory/
    group_vars/
      all.yml                MODIFY — add video_pipeline vars + vault secrets
  playbooks/
    video-pipeline/
      deploy.yml             CREATE — full deploy in dependency order
      teardown.yml           CREATE — full teardown in reverse order
```

---

## Task 1: Directory Structure and Namespace YAMLs

**Files:**
- Create: `kubernetes/apps/kafka/namespace.yaml`
- Create: `kubernetes/apps/redis/namespace.yaml`
- Create: `kubernetes/storage/minio/namespace.yaml`

- [ ] **Step 1: Create directories**

```bash
mkdir -p kubernetes/apps/kafka
mkdir -p kubernetes/apps/redis
mkdir -p kubernetes/storage/minio
mkdir -p ansible/playbooks/video-pipeline
```

- [ ] **Step 2: Create kafka namespace**

`kubernetes/apps/kafka/namespace.yaml`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: kafka
```

- [ ] **Step 3: Create redis namespace**

`kubernetes/apps/redis/namespace.yaml`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: redis
```

- [ ] **Step 4: Create minio namespace**

`kubernetes/storage/minio/namespace.yaml`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: minio
```

- [ ] **Step 5: Validate all namespace YAMLs**

```bash
kubectl apply --dry-run=client -f kubernetes/apps/kafka/namespace.yaml
kubectl apply --dry-run=client -f kubernetes/apps/redis/namespace.yaml
kubectl apply --dry-run=client -f kubernetes/storage/minio/namespace.yaml
```

Expected output for each:
```
namespace/kafka configured (dry run)
namespace/redis configured (dry run)
namespace/minio configured (dry run)
```

- [ ] **Step 6: Commit**

```bash
git add kubernetes/apps/kafka/namespace.yaml \
        kubernetes/apps/redis/namespace.yaml \
        kubernetes/storage/minio/namespace.yaml
git commit -m "feat: add kafka, redis, minio namespace manifests"
```

---

## Task 2: Strimzi Operator Helm Values

**Files:**
- Create: `kubernetes/apps/kafka/values.yaml`

- [ ] **Step 1: Check latest Strimzi chart version**

```bash
helm repo add strimzi https://strimzi.io/charts/ 2>/dev/null || true
helm repo update
helm search repo strimzi/strimzi-kafka-operator --versions | head -5
```

Note the latest `0.45.x` version. Update `strimzi_version` in Task 6 if different from `0.45.0`.

- [ ] **Step 2: Create Strimzi operator values**

`kubernetes/apps/kafka/values.yaml`:
```yaml
# Strimzi Kafka Operator — Helm values
# Chart: strimzi/strimzi-kafka-operator
# Helm install: helm install strimzi strimzi/strimzi-kafka-operator \
#   -n kafka -f kubernetes/apps/kafka/values.yaml

# Watch only kafka namespace.
# PROTOTYPE: kafka only. Production: expand if Kafka serves other namespaces.
watchNamespaces:
  - kafka

# PROTOTYPE: pin operator to k3s-worker-1. Remove nodeSelector for production.
nodeSelector:
  kubernetes.io/hostname: k3s-worker-1

tolerations:
  - key: on-demand
    operator: Equal
    value: "true"
    effect: NoSchedule

# PROTOTYPE: 1 replica. Production: 2 for HA.
replicas: 1

resources:
  requests:
    cpu: 200m
    memory: 384Mi
  limits:
    cpu: 1000m
    memory: 512Mi
```

- [ ] **Step 3: Dry-run validate via helm template**

```bash
helm template strimzi strimzi/strimzi-kafka-operator \
  -n kafka \
  -f kubernetes/apps/kafka/values.yaml \
  --dry-run 2>&1 | tail -5
```

Expected: YAML output ends without errors.

- [ ] **Step 4: Commit**

```bash
git add kubernetes/apps/kafka/values.yaml
git commit -m "feat: add Strimzi operator Helm values (pve04-pinned, 1 replica)"
```

---

## Task 3: KafkaCluster CR (KRaft Mode)

**Files:**
- Create: `kubernetes/apps/kafka/kafka-cluster.yaml`

- [ ] **Step 1: Create KafkaNodePool and Kafka CRs**

`kubernetes/apps/kafka/kafka-cluster.yaml`:
```yaml
# KafkaNodePool — combined broker+controller (KRaft, no ZooKeeper)
# PROTOTYPE: 1 combined node. Production: split into dedicated controller pool
# (roles: [controller]) and broker pool (roles: [broker]), each with replicas: 3.
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: dual-role
  namespace: kafka
  labels:
    strimzi.io/cluster: kafka-cluster
spec:
  # PROTOTYPE: 1 node. Production: 3, remove nodeSelector.
  replicas: 1
  roles:
    - controller
    - broker
  storage:
    type: persistent-claim
    size: 20Gi
    deleteClaim: false
    class: longhorn
  template:
    pod:
      # PROTOTYPE: pin to k3s-worker-1. Remove nodeSelector for production.
      nodeSelector:
        kubernetes.io/hostname: k3s-worker-1
      tolerations:
        - key: on-demand
          operator: Equal
          value: "true"
          effect: NoSchedule
---
# Kafka cluster — KRaft mode, Strimzi node pools enabled
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: kafka-cluster
  namespace: kafka
  annotations:
    strimzi.io/node-pools: enabled
    strimzi.io/kraft: enabled
spec:
  kafka:
    version: 3.9.0
    metadataVersion: 3.9-IV0
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
      - name: tls
        port: 9093
        type: internal
        tls: true
    config:
      # PROTOTYPE: replication factor 1 (single broker). Production: set all to 3, min.insync.replicas: 2.
      offsets.topic.replication.factor: "1"
      transaction.state.log.replication.factor: "1"
      transaction.state.log.min.isr: "1"
      default.replication.factor: "1"
      min.insync.replicas: "1"
  entityOperator:
    topicOperator: {}
    userOperator: {}
```

- [ ] **Step 2: Dry-run validate**

```bash
kubectl apply --dry-run=client -f kubernetes/apps/kafka/kafka-cluster.yaml
```

Expected:
```
kafkanodepool.kafka.strimzi.io/dual-role configured (dry run)
kafka.kafka.strimzi.io/kafka-cluster configured (dry run)
```

Note: dry-run requires Strimzi CRDs to be installed. If CRDs are not yet installed, this will fail with "no kind KafkaNodePool". Skip this step until after Strimzi operator is deployed in Task 7.

- [ ] **Step 3: Commit**

```bash
git add kubernetes/apps/kafka/kafka-cluster.yaml
git commit -m "feat: add KafkaCluster CR — KRaft, 1 combined broker+controller on pve04"
```

---

## Task 4: Redis Values and Vault Secret

**Files:**
- Create: `kubernetes/apps/redis/values.yaml`
- Modify: `ansible/inventory/group_vars/all.yml` (redis_password vault var)

- [ ] **Step 1: Check latest Bitnami Redis chart version**

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
helm repo update
helm search repo bitnami/redis --versions | head -5
```

Note the latest `20.x.x` version. Use it in `redis_chart_version` in Task 6.

- [ ] **Step 2: Create Redis values**

`kubernetes/apps/redis/values.yaml`:
```yaml
# Bitnami Redis — Helm values
# Chart: bitnami/redis
# Helm install: helm install redis bitnami/redis \
#   -n redis -f kubernetes/apps/redis/values.yaml

# PROTOTYPE: standalone (no replicas). Production: architecture: replication.
architecture: standalone

auth:
  enabled: true
  existingSecret: redis-secret
  existingSecretPasswordKey: password

master:
  # PROTOTYPE: pin to k3s-worker-1. Remove nodeSelector for production.
  nodeSelector:
    kubernetes.io/hostname: k3s-worker-1

  tolerations:
    - key: on-demand
      operator: Equal
      value: "true"
      effect: NoSchedule

  persistence:
    enabled: true
    storageClass: longhorn
    size: 5Gi

  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 256Mi
```

- [ ] **Step 3: Generate and vault-encrypt redis password**

```bash
# Generate a strong password
openssl rand -base64 32

# Encrypt it with ansible-vault (paste the generated password when prompted)
ansible-vault encrypt_string --name 'redis_password' 'changeme'
```

Copy the vault-encrypted block output for the next step.

- [ ] **Step 4: Add redis_password to group_vars**

In `ansible/inventory/group_vars/all.yml`, add after the existing vars:
```yaml
# Redis password for video pipeline
redis_password: !vault |
  <paste vault-encrypted block from previous step>
```

- [ ] **Step 5: Validate values with helm template**

```bash
helm template redis bitnami/redis \
  -n redis \
  -f kubernetes/apps/redis/values.yaml \
  --dry-run 2>&1 | tail -5
```

Expected: YAML output ends without errors.

- [ ] **Step 6: Commit**

```bash
git add kubernetes/apps/redis/values.yaml ansible/inventory/group_vars/all.yml
git commit -m "feat: add Redis Helm values and vault-encrypted password"
```

---

## Task 5: MinIO PV, PVC, and Values

**Files:**
- Create: `kubernetes/storage/minio/pv.yaml`
- Create: `kubernetes/storage/minio/pvc.yaml`
- Create: `kubernetes/storage/minio/values.yaml`
- Modify: `ansible/inventory/group_vars/all.yml` (minio vault vars)

- [ ] **Step 1: Check latest MinIO chart version**

```bash
helm repo add minio https://charts.min.io/ 2>/dev/null || true
helm repo update
helm search repo minio/minio --versions | head -5
```

Note the latest `5.x.x` version. Use it in `minio_chart_version` in Task 6.

- [ ] **Step 2: Create MinIO PersistentVolume**

`kubernetes/storage/minio/pv.yaml`:
```yaml
# Local PersistentVolume — ZFS raidz2 on k3s-worker-1 (pve04)
# Path /mnt/storage/minio must exist on k3s-worker-1 before deploying.
# Data is NOT deleted on teardown — survives deploy/teardown cycles.
apiVersion: v1
kind: PersistentVolume
metadata:
  name: minio-pv
spec:
  capacity:
    storage: 100Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  local:
    path: /mnt/storage/minio
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - k3s-worker-1
  claimRef:
    name: minio-data
    namespace: minio
```

- [ ] **Step 3: Create MinIO PersistentVolumeClaim**

`kubernetes/storage/minio/pvc.yaml`:
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-data
  namespace: minio
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ""
  volumeName: minio-pv
  resources:
    requests:
      storage: 100Gi
```

- [ ] **Step 4: Create MinIO values**

`kubernetes/storage/minio/values.yaml`:
```yaml
# MinIO — Helm values
# Chart: minio/minio
# Helm install: helm install minio minio/minio \
#   -n minio -f kubernetes/storage/minio/values.yaml

# PROTOTYPE: standalone. Production: distributed mode (4+ nodes, dedicated storage class).
mode: standalone

persistence:
  enabled: true
  existingClaim: minio-data

# Credentials injected from Kubernetes Secret (created by Ansible deploy.yml)
existingSecret: minio-secret

# PROTOTYPE: pin to k3s-worker-1. Remove nodeSelector for production.
nodeSelector:
  kubernetes.io/hostname: k3s-worker-1

tolerations:
  - key: on-demand
    operator: Equal
    value: "true"
    effect: NoSchedule

resources:
  requests:
    memory: 512Mi
    cpu: 250m
  limits:
    memory: 1Gi
    cpu: 1000m

# S3 API ingress
ingress:
  enabled: true
  ingressClassName: traefik
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
  hosts:
    - host: minio.tmf-solutions.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: tmf-solutions-tls
      hosts:
        - minio.tmf-solutions.com

# MinIO console ingress
consoleIngress:
  enabled: true
  ingressClassName: traefik
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
  hosts:
    - host: minio-console.tmf-solutions.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: tmf-solutions-tls
      hosts:
        - minio-console.tmf-solutions.com
```

- [ ] **Step 5: Generate and vault-encrypt MinIO credentials**

```bash
# Generate root password
openssl rand -base64 32

# Encrypt user (can be a fixed value like 'admin')
ansible-vault encrypt_string --name 'minio_root_user' 'admin'

# Encrypt password (paste generated password)
ansible-vault encrypt_string --name 'minio_root_password' 'changeme'
```

- [ ] **Step 6: Add MinIO vars to group_vars**

In `ansible/inventory/group_vars/all.yml`, add:
```yaml
# MinIO credentials for video pipeline
minio_root_user: !vault |
  <paste vault-encrypted block>
minio_root_password: !vault |
  <paste vault-encrypted block>
```

- [ ] **Step 7: Validate PV and PVC YAMLs**

```bash
kubectl apply --dry-run=client -f kubernetes/storage/minio/pv.yaml
kubectl apply --dry-run=client -f kubernetes/storage/minio/pvc.yaml
```

Expected:
```
persistentvolume/minio-pv configured (dry run)
persistentvolumeclaim/minio-data configured (dry run)
```

- [ ] **Step 8: Commit**

```bash
git add kubernetes/storage/minio/pv.yaml \
        kubernetes/storage/minio/pvc.yaml \
        kubernetes/storage/minio/values.yaml \
        ansible/inventory/group_vars/all.yml
git commit -m "feat: add MinIO PV, PVC, Helm values and vault-encrypted credentials"
```

---

## Task 6: Ansible group_vars — video_pipeline versions block

**Files:**
- Modify: `ansible/inventory/group_vars/all.yml`

- [ ] **Step 1: Add video_pipeline versions to group_vars**

In `ansible/inventory/group_vars/all.yml`, add a new section (fill in the chart versions noted in Tasks 2, 4, and 5):
```yaml
# Video pipeline infrastructure versions
# Defaults below are current stable at plan writing date (2026-04-03).
# Verify with: helm search repo strimzi/strimzi-kafka-operator
#              helm search repo bitnami/redis --versions | head -3
#              helm search repo minio/minio --versions | head -3
# Update if a newer patch version is available before first deploy.
video_pipeline:
  strimzi_version: "0.45.0"
  kafka_version: "3.9.0"
  redis_chart_version: "20.6.3"
  minio_chart_version: "5.4.0"
  zfs_minio_path: "/mnt/storage/minio"
```

- [ ] **Step 2: Verify vault vars are all present**

The following vars must exist in `all.yml` (added in Tasks 4 and 5):
- `redis_password`
- `minio_root_user`
- `minio_root_password`

Run a quick check:
```bash
ansible -i ansible/inventory/hosts.yml localhost \
  -m debug \
  -a "msg={{ redis_password is defined and minio_root_user is defined and minio_root_password is defined }}"
```

Expected:
```
localhost | SUCCESS => {
    "msg": true
}
```

- [ ] **Step 3: Commit**

```bash
git add ansible/inventory/group_vars/all.yml
git commit -m "feat: add video_pipeline version vars to group_vars"
```

---

## Task 7: Ansible deploy.yml

**Files:**
- Create: `ansible/playbooks/video-pipeline/deploy.yml`

- [ ] **Step 1: Create deploy playbook**

`ansible/playbooks/video-pipeline/deploy.yml`:
```yaml
---
# Play 1: Ensure ZFS directory exists on k3s-worker-1
- name: Prepare k3s-worker-1 storage
  hosts: k3s-worker-1
  become: true
  tasks:
    - name: Ensure MinIO ZFS data directory exists
      file:
        path: "{{ video_pipeline.zfs_minio_path }}"
        state: directory
        owner: root
        group: root
        mode: "0755"

# Play 2: Deploy all components to the cluster
- name: Deploy video pipeline infrastructure
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    kubeconfig: "{{ lookup('env', 'HOME') }}/.kube/config"
    kube_context: homelab
    repo_root: "{{ playbook_dir }}/../../../"

  tasks:
    - name: Add Strimzi Helm repo
      kubernetes.core.helm_repository:
        name: strimzi
        repo_url: https://strimzi.io/charts/

    - name: Add Bitnami Helm repo
      kubernetes.core.helm_repository:
        name: bitnami
        repo_url: https://charts.bitnami.com/bitnami

    - name: Add MinIO Helm repo
      kubernetes.core.helm_repository:
        name: minio
        repo_url: https://charts.min.io/

    - name: Update Helm repos
      command: helm repo update

    - name: Create namespaces
      kubernetes.core.k8s:
        kubeconfig: "{{ kubeconfig }}"
        context: "{{ kube_context }}"
        src: "{{ item }}"
        state: present
      loop:
        - "{{ repo_root }}/kubernetes/apps/kafka/namespace.yaml"
        - "{{ repo_root }}/kubernetes/apps/redis/namespace.yaml"
        - "{{ repo_root }}/kubernetes/storage/minio/namespace.yaml"

    - name: Install Strimzi operator
      kubernetes.core.helm:
        kubeconfig: "{{ kubeconfig }}"
        kube_context: "{{ kube_context }}"
        name: strimzi
        chart_ref: strimzi/strimzi-kafka-operator
        chart_version: "{{ video_pipeline.strimzi_version }}"
        release_namespace: kafka
        values_files:
          - "{{ repo_root }}/kubernetes/apps/kafka/values.yaml"
        wait: true
        timeout: "5m0s"

    - name: Apply KafkaNodePool and Kafka CRs
      kubernetes.core.k8s:
        kubeconfig: "{{ kubeconfig }}"
        context: "{{ kube_context }}"
        src: "{{ repo_root }}/kubernetes/apps/kafka/kafka-cluster.yaml"
        state: present

    - name: Wait for Kafka cluster to be Ready
      kubernetes.core.k8s_info:
        kubeconfig: "{{ kubeconfig }}"
        context: "{{ kube_context }}"
        api_version: kafka.strimzi.io/v1beta2
        kind: Kafka
        name: kafka-cluster
        namespace: kafka
      register: kafka_info
      until: >
        kafka_info.resources | length > 0 and
        (kafka_info.resources[0].status.conditions |
         selectattr('type', 'equalto', 'Ready') |
         selectattr('status', 'equalto', 'True') | list | length > 0)
      retries: 30
      delay: 10

    - name: Create Redis secret
      kubernetes.core.k8s:
        kubeconfig: "{{ kubeconfig }}"
        context: "{{ kube_context }}"
        definition:
          apiVersion: v1
          kind: Secret
          metadata:
            name: redis-secret
            namespace: redis
          type: Opaque
          stringData:
            password: "{{ redis_password }}"
        state: present

    - name: Install Redis
      kubernetes.core.helm:
        kubeconfig: "{{ kubeconfig }}"
        kube_context: "{{ kube_context }}"
        name: redis
        chart_ref: bitnami/redis
        chart_version: "{{ video_pipeline.redis_chart_version }}"
        release_namespace: redis
        values_files:
          - "{{ repo_root }}/kubernetes/apps/redis/values.yaml"
        wait: true
        timeout: "3m0s"

    - name: Apply MinIO PersistentVolume and PVC
      kubernetes.core.k8s:
        kubeconfig: "{{ kubeconfig }}"
        context: "{{ kube_context }}"
        src: "{{ item }}"
        state: present
      loop:
        - "{{ repo_root }}/kubernetes/storage/minio/pv.yaml"
        - "{{ repo_root }}/kubernetes/storage/minio/pvc.yaml"

    - name: Create MinIO secret
      kubernetes.core.k8s:
        kubeconfig: "{{ kubeconfig }}"
        context: "{{ kube_context }}"
        definition:
          apiVersion: v1
          kind: Secret
          metadata:
            name: minio-secret
            namespace: minio
          type: Opaque
          stringData:
            rootUser: "{{ minio_root_user }}"
            rootPassword: "{{ minio_root_password }}"
        state: present

    - name: Install MinIO
      kubernetes.core.helm:
        kubeconfig: "{{ kubeconfig }}"
        kube_context: "{{ kube_context }}"
        name: minio
        chart_ref: minio/minio
        chart_version: "{{ video_pipeline.minio_chart_version }}"
        release_namespace: minio
        values_files:
          - "{{ repo_root }}/kubernetes/storage/minio/values.yaml"
        wait: true
        timeout: "3m0s"

    - name: Deployment summary
      debug:
        msg:
          - "=== Video Pipeline Infrastructure Deployed ==="
          - "Kafka (plain): kafka-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092"
          - "Kafka (TLS):   kafka-cluster-kafka-bootstrap.kafka.svc.cluster.local:9093"
          - "Redis:         redis-master.redis.svc.cluster.local:6379"
          - "MinIO S3:      minio.minio.svc.cluster.local:9000"
          - "MinIO Console: https://minio-console.tmf-solutions.com"
```

- [ ] **Step 2: Syntax check**

```bash
ansible-playbook ansible/playbooks/video-pipeline/deploy.yml --syntax-check
```

Expected:
```
playbook: ansible/playbooks/video-pipeline/deploy.yml
```
(No errors.)

- [ ] **Step 3: Commit**

```bash
git add ansible/playbooks/video-pipeline/deploy.yml
git commit -m "feat: add Ansible deploy playbook for video pipeline infrastructure"
```

---

## Task 8: Ansible teardown.yml

**Files:**
- Create: `ansible/playbooks/video-pipeline/teardown.yml`

- [ ] **Step 1: Create teardown playbook**

`ansible/playbooks/video-pipeline/teardown.yml`:
```yaml
---
- name: Tear down video pipeline infrastructure
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    kubeconfig: "{{ lookup('env', 'HOME') }}/.kube/config"
    kube_context: homelab

  tasks:
    - name: Uninstall MinIO
      kubernetes.core.helm:
        kubeconfig: "{{ kubeconfig }}"
        kube_context: "{{ kube_context }}"
        name: minio
        release_namespace: minio
        state: absent
        wait: true
        timeout: "2m0s"
      ignore_errors: true  # Continue if already absent

    - name: Delete MinIO PVC
      kubernetes.core.k8s:
        kubeconfig: "{{ kubeconfig }}"
        context: "{{ kube_context }}"
        api_version: v1
        kind: PersistentVolumeClaim
        name: minio-data
        namespace: minio
        state: absent
        wait: true
        wait_timeout: 60

    - name: Delete MinIO PV
      kubernetes.core.k8s:
        kubeconfig: "{{ kubeconfig }}"
        context: "{{ kube_context }}"
        api_version: v1
        kind: PersistentVolume
        name: minio-pv
        state: absent

    - name: Uninstall Redis
      kubernetes.core.helm:
        kubeconfig: "{{ kubeconfig }}"
        kube_context: "{{ kube_context }}"
        name: redis
        release_namespace: redis
        state: absent
        wait: true
        timeout: "2m0s"
      ignore_errors: true

    - name: Delete KafkaNodePool CR
      kubernetes.core.k8s:
        kubeconfig: "{{ kubeconfig }}"
        context: "{{ kube_context }}"
        api_version: kafka.strimzi.io/v1beta2
        kind: KafkaNodePool
        name: dual-role
        namespace: kafka
        state: absent
        wait: true
        wait_timeout: 120
      ignore_errors: true

    - name: Delete Kafka CR
      kubernetes.core.k8s:
        kubeconfig: "{{ kubeconfig }}"
        context: "{{ kube_context }}"
        api_version: kafka.strimzi.io/v1beta2
        kind: Kafka
        name: kafka-cluster
        namespace: kafka
        state: absent
        wait: true
        wait_timeout: 120
      ignore_errors: true

    - name: Uninstall Strimzi operator
      kubernetes.core.helm:
        kubeconfig: "{{ kubeconfig }}"
        kube_context: "{{ kube_context }}"
        name: strimzi
        release_namespace: kafka
        state: absent
        wait: true
        timeout: "3m0s"
      ignore_errors: true

    - name: Delete namespaces
      kubernetes.core.k8s:
        kubeconfig: "{{ kubeconfig }}"
        context: "{{ kube_context }}"
        api_version: v1
        kind: Namespace
        name: "{{ item }}"
        state: absent
        wait: true
        wait_timeout: 120
      loop:
        - minio
        - redis
        - kafka
      ignore_errors: true

    - name: Teardown complete
      debug:
        msg:
          - "=== Video Pipeline Infrastructure Torn Down ==="
          - "ZFS data at /mnt/storage/minio on k3s-worker-1 was NOT deleted."
          - "Re-run deploy.yml to restore the infrastructure."
```

- [ ] **Step 2: Syntax check**

```bash
ansible-playbook ansible/playbooks/video-pipeline/teardown.yml --syntax-check
```

Expected:
```
playbook: ansible/playbooks/video-pipeline/teardown.yml
```

- [ ] **Step 3: Commit**

```bash
git add ansible/playbooks/video-pipeline/teardown.yml
git commit -m "feat: add Ansible teardown playbook for video pipeline infrastructure"
```

---

## Task 9: End-to-End Deploy and Verify

Prerequisites: k3s-worker-1 is online and has joined the cluster.

- [ ] **Step 1: Confirm k3s-worker-1 is Ready**

```bash
kubectl --kubeconfig ~/.kube/config --context homelab get node k3s-worker-1
```

Expected:
```
NAME           STATUS   ROLES    AGE   VERSION
k3s-worker-1   Ready    worker   Xd    v1.34.5+k3s1
```

If status is `NotReady`, power on pve04 and wait for the node to rejoin (check with `kubectl get nodes -w`).

- [ ] **Step 2: Run deploy playbook**

```bash
cd ~/homelab
ansible-playbook ansible/playbooks/video-pipeline/deploy.yml
```

Expected final output includes the deployment summary block with all endpoints.

- [ ] **Step 3: Verify all pods are Running**

```bash
kubectl --kubeconfig ~/.kube/config --context homelab \
  get pods -n kafka -n redis -n minio
```

Expected — all pods in `Running` state:
```
NAMESPACE   NAME                                          READY   STATUS    RESTARTS
kafka       strimzi-cluster-operator-xxx                  1/1     Running   0
kafka       kafka-cluster-dual-role-0                     1/1     Running   0
redis       redis-master-0                                1/1     Running   0
minio       minio-xxx                                     1/1     Running   0
```

- [ ] **Step 4: Verify MinIO PVC is Bound**

```bash
kubectl --kubeconfig ~/.kube/config --context homelab \
  get pvc minio-data -n minio
```

Expected:
```
NAME         STATUS   VOLUME     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
minio-data   Bound    minio-pv   100Gi      RWO                           Xm
```

- [ ] **Step 5: Smoke-test Kafka bootstrap from within cluster**

```bash
kubectl --kubeconfig ~/.kube/config --context homelab \
  run kafka-test --rm -it --restart=Never \
  --image=bitnami/kafka:3.9.0 \
  -n kafka \
  -- kafka-broker-api-versions.sh \
     --bootstrap-server kafka-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092
```

Expected: broker API versions listed without connection errors. Type `exit` when done.

- [ ] **Step 6: Smoke-test Redis from within cluster**

```bash
REDIS_PASSWORD=$(kubectl --kubeconfig ~/.kube/config --context homelab \
  get secret redis-secret -n redis -o jsonpath='{.data.password}' | base64 -d)

kubectl --kubeconfig ~/.kube/config --context homelab \
  run redis-test --rm -it --restart=Never \
  --image=bitnami/redis:7.4 \
  -n redis \
  -- redis-cli -h redis-master.redis.svc.cluster.local \
               -a "$REDIS_PASSWORD" ping
```

Expected:
```
PONG
```

- [ ] **Step 7: Verify MinIO console is accessible**

Open `https://minio-console.tmf-solutions.com` in a browser.
Log in with `admin` / `<minio_root_password from vault>`.
Expected: MinIO console loads, shows 0 buckets.

- [ ] **Step 8: Run teardown and verify clean state**

```bash
ansible-playbook ansible/playbooks/video-pipeline/teardown.yml
kubectl --kubeconfig ~/.kube/config --context homelab get ns kafka redis minio
```

Expected:
```
Error from server (NotFound): namespaces "kafka" not found
Error from server (NotFound): namespaces "redis" not found
Error from server (NotFound): namespaces "minio" not found
```

- [ ] **Step 9: Verify ZFS data survived teardown**

```bash
ssh tfarias@192.168.1.53 "ls -la /mnt/storage/minio"
```

Expected: directory exists (may be empty for a fresh run, or contain MinIO data if objects were written).

- [ ] **Step 10: Re-run deploy to confirm idempotency**

```bash
ansible-playbook ansible/playbooks/video-pipeline/deploy.yml
```

Expected: completes successfully, all pods Running, no errors.
