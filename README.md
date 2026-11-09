# Kubernetes Cluster with Ansible

![Ansible](https://img.shields.io/badge/Ansible-EE0000?style=flat-square&logo=ansible&logoColor=white)
![Kubernetes](https://img.shields.io/badge/Kubernetes-1.28-326CE5?style=flat-square&logo=kubernetes&logoColor=white)
![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04-E95420?style=flat-square&logo=ubuntu&logoColor=white)
![containerd](https://img.shields.io/badge/runtime-containerd-575757?style=flat-square)
![Flannel](https://img.shields.io/badge/CNI-Flannel%20v0.27.3-0A66C2?style=flat-square)

An Ansible role that builds a Kubernetes 1.28 cluster with kubeadm on Ubuntu machines: one control plane node and any number of workers, from bare OS to `Ready` nodes in one command. It also covers adding workers later and tearing the cluster down.

## How it works

```mermaid
flowchart LR
    A["Control node<br/>(Ansible)"] -- SSH --> C["controller1<br/>kubeadm init + Flannel"]
    A -- SSH --> W["worker1 ... workerN<br/>kubeadm join"]
    C -- "join command, fetched to<br/>Remote_Files/" --> A
    W -. joins .-> C

    classDef client fill:#8957e5,stroke:#a371f7,color:#ffffff,stroke-width:2px
    classDef controller fill:#238636,stroke:#3fb950,color:#ffffff,stroke-width:2px
    classDef app fill:#bd561d,stroke:#f0883e,color:#ffffff,stroke-width:2px
    class A client
    class C controller
    class W app
    linkStyle default stroke:#8b949e,stroke-width:2px
```

`site.yml` applies the `kubernetes_cluster` role to every host. The role runs three task files, chosen by inventory group:

| Task file | Runs on | What it does |
|---|---|---|
| `prerequisites.yml` | every node | Upgrades the OS packages, installs containerd with `SystemdCgroup = true`, disables swap (now and in `/etc/fstab`), loads `overlay` and `br_netfilter`, sets the bridge and IP forwarding sysctls, installs kubeadm, kubelet and kubectl 1.28 from `pkgs.k8s.io` and holds them with dpkg. |
| `master.yml` | `[controllers]` | Runs `kubeadm init` (pod CIDR `10.244.0.0/16`), copies the admin kubeconfig to the SSH user's `~/.kube/config`, installs Flannel v0.27.3, then generates the join command and fetches it to `Remote_Files/worker_conn_string` on the control node. |
| `worker.yml` | `[workers]` | Runs the fetched join command, one worker at a time. |

The playbook is safe to run again on a built cluster: `kubeadm init` is skipped when `/etc/kubernetes/admin.conf` exists, and the join is skipped when `/etc/kubernetes/kubelet.conf` exists.

## Requirements

- **Nodes:** Ubuntu 22.04 or 24.04 LTS, 2 CPUs and 2 GB RAM minimum (4 GB recommended for the controller), a unique hostname each, and internet access to `pkgs.k8s.io`, `registry.k8s.io`, `github.com` and `ghcr.io`.
- **Access:** SSH with a key from the control node, and passwordless `sudo` on the nodes. Otherwise add `-K` to each `ansible-playbook` command.
- **Control node:** Ansible 2.10 or newer with the `community.general` collection. The full `ansible` package includes it; with `ansible-core` only, run `ansible-galaxy collection install -r requirements.yml` from `cluster-k8s/`.
- **Shortcut:** on Ubuntu, `ansible-install/steps.sh` installs Ansible and gives the current user passwordless sudo.

## Quick start

**1. Clone the repository**

```bash
git clone https://github.com/raslenraslen/ansible-kubeadm-cluster.git
cd ansible-kubeadm-cluster/cluster-k8s
```

**2. Describe your nodes in `inventory.ini`**

Put one host in `[controllers]` and one or more in `[workers]`. Set `ansible_host` to the node IP and `ansible_user` to the SSH user.

```ini
[controllers]
controller1 ansible_host=192.168.216.142 ansible_user=raslen

[workers]
worker1 ansible_host=192.168.216.139 ansible_user=raslenworker
```

**3. Check that every node answers**

```bash
ansible all -i inventory.ini -m ping
```

Each host must reply `"ping": "pong"`.

**4. Build the cluster**

```bash
ansible-playbook -i inventory.ini site.yml
```

**5. Verify, on the controller**

```bash
kubectl get nodes
```

Every node must be `Ready`:

![kubectl get nodes: controller and worker Ready on v1.28.15](Screenshots/nodes.PNG)

## Add workers to a running cluster

The join command contains a bootstrap token that expires after 24 hours, so refresh it before adding a node.

**1.** Add the new host to `[workers]` in `inventory.ini`, for example:

```ini
worker2 ansible_host=192.168.216.143 ansible_user=raslenworker
```

**2.** Generate a fresh join command. This only runs the join-command tasks on the controller and changes nothing else:

```bash
ansible-playbook -i inventory.ini site.yml -l controllers --tags join_string
```

**3.** Prepare and join only the new node:

```bash
ansible-playbook -i inventory.ini site.yml -l worker2
```

To add several nodes at once, list them: `-l worker2,worker3`.

## Reset the cluster

> **Warning:** this destroys the cluster and all its workloads.

```bash
ansible-playbook -i inventory.ini reset.yml
```

On every node it runs `kubeadm reset -f`, then deletes `/etc/kubernetes`, `/var/lib/etcd`, `/etc/cni/net.d` and the SSH user's `~/.kube/config`. The packages stay installed, so `site.yml` can rebuild the cluster right away.

`kubeadm reset` does not flush iptables rules or delete the `cni0` and `flannel.1` interfaces. Reboot the nodes if you need a fully clean network state.

To remove a single worker, run `kubectl delete node <name>` on the controller, then `ansible-playbook -i inventory.ini reset.yml -l <name>`.

## Configuration

Defaults live in `cluster-k8s/roles/kubernetes_cluster/defaults/main.yml`. Set them before building a cluster, not on a running one.

| Variable | Default | Purpose |
|---|---|---|
| `kube_version` | `1.28` | Kubernetes minor version of the `pkgs.k8s.io` apt repository |
| `pod_network_cidr` | `10.244.0.0/16` | Pod CIDR passed to `kubeadm init`. Must match the `Network` value of the Flannel manifest |
| `flannel_version` | `v0.27.3` | Flannel release whose `kube-flannel.yml` is applied |

## Design choices

- **kubeadm** is the upstream bootstrap tool, so the cluster matches the official documentation with no extra layer to learn.
- **containerd with the systemd cgroup driver**: kubeadm configures kubelet with the systemd driver by default since Kubernetes 1.22, and the container runtime must use the same driver.
- **Pinned versions**: Kubernetes through the versioned apt repository plus a dpkg hold, Flannel through a release tag. An upstream release cannot change the cluster between two runs.
- **Join command fetched to the control node**: workers never need SSH access to the controller.

## Limitations

- **Single control plane.** `kubeadm init` uses the controller IP as the endpoint, so the cluster is not highly available.
- **Ubuntu with containerd 1.x.** The `SystemdCgroup` edit targets the containerd 1.x configuration layout, and the tasks use `apt`.
- **No version upgrades.** The Kubernetes packages are held; upgrade them with `kubeadm upgrade`.
- **Every run upgrades the OS packages and restarts containerd**, because the containerd configuration is rebuilt from the defaults on each run.
