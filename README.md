# aether-onramp

Single Click Deployment of Aether SD-Core.

This repository is [Aether OnRamp](https://github.com/opennetworkinglab/aether-onramp)
(upstream history preserved) plus a one-click path that deploys RKE2 Kubernetes and the
SD-Core 5G core on a single Ubuntu 22.04 node, then verifies it. No RAN or gNBsim is
installed. The deployment itself is still OnRamp's own `make` and Ansible roles.

## Quick start

Requirements: Ubuntu 22.04, 8+ cores, 16+ GiB RAM, ~40 GB free disk, passwordless sudo,
internet access to docker.io and ghcr.io.

```bash
git clone https://github.com/TOSSI-Foundation/aether-onramp.git ~/aether-onramp
cd ~/aether-onramp
./oneclick.sh
```

`oneclick.sh` works on any single-node VM or server. On every run it writes `hosts.ini`
and `vars/main.yml` for the host it runs on:

| Setting | Source |
|---|---|
| Ansible user (`hosts.ini`) | the user running the script |
| `core.data_iface`, `gnbsim.router.data_iface` | interface on the default route |
| `core.amf.ip` | that interface's IPv4 address |
| `core.ran_subnet` | `172.20.0.0/16`, or `172.30.0.0/16` if 172.20 is already routed (kind/Docker) |

Override any of them:

```bash
NODE_IP=10.0.0.5 IFACE=ens18 RAN_SUBNET=172.30.0.0/16 ./oneclick.sh
```

It is safe to re-run. A failed `sd-core` Helm release from an earlier attempt is removed
first; a healthy deployed release is left alone. Pulled images stay cached.

Multi-node: edit `hosts.ini` by hand as in standard OnRamp; the auto-config covers node1 only.

## What `oneclick.sh` does

1. Installs `make`, `git`, `pipx` and Ansible via pipx (Ubuntu 22.04's apt Ansible 2.10 is
   too old for `community.docker` 5.x), plus the Galaxy collections in `requirements.yml`.
2. Creates a localhost SSH key so Ansible can reach `node1` at `127.0.0.1`.
3. Writes `hosts.ini` and `vars/main.yml` for this host (table above).
4. Saves any existing `~/.kube/config` to `~/.kube/pre-aether.config` and merges it back
   afterwards, because OnRamp overwrites it with the RKE2 kubeconfig. The RKE2 context is
   named `aether-rke2`.
5. Runs `make aether-sdcore-oneclick`.

## Make targets added

| Target | Runs |
|---|---|
| `aether-sdcore-oneclick` | `aether-pingall` → `k8s-install` → `aether-sdcore-prepull` → `5gc-install` → `aether-sdcore-verify` |
| `aether-sdcore-prepull` | `prepull-sdcore.yml`: renders the SD-Core chart's image list and pulls all images into RKE2's containerd in parallel |
| `aether-sdcore-verify` | `verify-sdcore.yml`: node Ready, all `aether-5gc` pods Ready, UPF↔SMF PFCP association (recycles `upf-0` on the known "datapath down" startup race), AMF N2 SCTP 38412 exposed on `core.amf.ip`, webui API responding |

## Changes to upstream files

| File | Change |
|---|---|
| `deps/k8s/roles/rke2/tasks/install.yml` | Node-Ready wait was a fixed 300 s; now `k8s.rke2.ready_timeout` (default 900 s) |
| `deps/5gc/roles/core/tasks/install.yml` | Helm `--wait` was a fixed 5 min; now `core.helm.wait_timeout` (default 20 min). Rescue-path pod wait was 300 s; now `core.helm.pod_ready_timeout` (default 1200 s) |
| `deps/5gc/roles/core/templates/sdcore-5g-values.yaml` | MongoDB hardening for CPU-contended hosts, for both data nodes and the arbiter. Probe timeouts raised from 10 s/5 s to `core.mongodb.probe_timeout` (default 30 s), failureThreshold 10: the chart's `mongosh` exec probes time out and the kubelet restart-loops MongoDB. First-boot replica-set init retries raised from 7 x 5 s to `core.mongodb.init_retry_attempts` x `init_retry_delay` (default 60 x 10 s): Bitnami's `rs.initiate` otherwise gives up ("primary node failed to get configured") and the restarted pod never forms the replica set, which takes UDR, SMF and webui down with it |
| `vars/main.yml` | Adds the three timeout keys above |
| `Makefile` | Adds the three targets above |

The fixed upstream timeouts fail on slow registry links: the kubelet pulls images one at a
time, so the node or the SD-Core pods are not Ready within 5 minutes.

If MongoDB still restarts on a heavily loaded host, raise these in `vars/main.yml`:

```yaml
core:
  mongodb:
    probe_timeout: 60
    init_retry_attempts: 120
```

## Useful commands

```bash
make aether-sdcore-verify                 # re-run health checks only
kubectl -n aether-5gc get pods            # core NFs
make aether-5gc-uninstall                 # remove the core
make aether-k8s-uninstall                 # remove RKE2
```

---

# Upstream Aether OnRamp README

# Aether OnRamp

Aether OnRamp provides a low-overhead way to bring up a
Kubernetes cluster, deploy a 5G version of SD-Core on that
cluster, and then connect that Core to either an emulated 5G RAN
or a network of physical gNBs. (OnRamp also supports a 4G
configuration that connects physical eNBs.)

To download Aether OnRamp, type:

```
$ git clone https://github.com/opennetworkinglab/aether-onramp.git
```

Taking a quick look at your ``aether-onramp`` directory, you will
find the following.

1. The ``deps`` directory contains vendored Ansible deployment
   specifications for all the Aether subsystems. Each of these
   subdirectories (e.g., ``deps/5gc``) is self-contained, but
   the Makefile in the main OnRamp directory imports the
   per-subsystem Makefiles, meaning all the steps required
   to install Aether can be (and typically should be) managed from
   this main directory.

2. File ``vars/main.yml`` defines all the Ansible variables you will
   potentially need to modify to specify your deployment scenario.
   This file is the union of all the per-component ``var/main.yml``
   files you find in the corresponding ``deps`` directory. This
    top-level variable file overrides the per-component files, so
   you will not need to modify the latter. The ``vars`` directory
   contains several variants of ``main.yml``, each tailored for a
   different deployment scenario, with the default ``main.yml``
   supporting the Quick Start deployment described below.

3. File ``hosts.ini`` specifies the set of servers (physical or
   virtual) that Ansible targets with various playbooks. The
   default version included with OnRamp is simplified to run
   everything on a single server (the one you've cloned the
   repo onto). Example multi-node inventories are commented out.
   To keep connection passwords out of ``hosts.ini``, OnRamp also
   ships an optional Ansible Vault example at
   ``group_vars/all/vault.yml.example``; follow the instructions in
   that file to supply credentials via encrypted ``vault_password``
   and ``vault_sudo_password`` variables. This step is optional and
   disabled by default, so the default single-node setup works
   without it.

OnRamp is officially supported on Ubuntu 22.04 and Ubuntu 24.04.
Install the prerequisites, including Ansible, from the Ubuntu package
repository on those releases:

```
$ sudo apt update
$ sudo apt install sshpass ansible make git
```

Aether OnRamp assumes Ansible is installed. (See the
[Aether Guide](https://docs.aetherproject.org/onramp/start.html#prep-environment)
for instructions on doing this, along with additional guidance if this
is your first attempt to install OnRamp.) Then, once you edit ``hosts.ini`` to
match your local details, type the following to verify the setup:

```
$ make aether-pingall
```

## Quick Start

Edit ``vars/main.yml`` to reflect your local scenario. For
the Quick Start deployment, this means setting variable
``data_iface`` to your server's network interface. Note there are
**two** lines that define this variable, one in the ``core`` section
and one in the ``gnbsim`` section. You also need to set the
IP address of the AMF (in the ``core`` section) to your servers's
IP address.

You are now ready to install a one-node Kubernetes cluster. Type:

```
$ make aether-k8s-install
```

Once Kubernetes is running (which you can verify with ``kubectl``),
you are ready to install the 5G version of SD-Core. Type:

```
$ make aether-5gc-install
```

Once the Core is running (which you can verify by using ``kubectl`` to
check the ``omec`` name space), you are ready to emulate a RAN
workload. Type:

```
$ make aether-gnbsim-install
$ make aether-gnbsim-run
```

The second command can be executed multiple times, where the
results of each run are saved in a file within the Docker container
running the test. You can access that file by typing:

```
$ docker exec -it gnbsim-1 cat summary.log
```

Finally, you can bring up the Aether Monitoring Platform (AMP) to view
dashboards showing different aspects of Aether's runtime behavior. Type:

```
$ make aether-amp-install
```

You can access the dashboards for Aether's Monitoring system at the
following URL:

```
http://<server_ip>:30950
```

You will probably want to rerun ``make aether-gnbsim-run`` to generate
traffic for the monitoring system to display.

When you are ready to tear down your Quick Start deployment of Aether,
execute the following commands:

```
$ make aether-gnbsim-uninstall
$ make aether-amp-uninstall
$ make aether-5gc-uninstall
$ make aether-k8s-uninstall
```

Or alternatively:

```
$ make aether-uninstall
```

## Beyond Quick Start

Being able to support more complex configurations of Aether is whole
point of OnRamp. See the OnRamp documentation available as part of
the [Aether Guide](https://docs.aetherproject.org) for details.

## Deploying Behind a Proxy

If your servers access the Internet through an HTTP proxy, enable proxy
support in ``vars/main.yml``:

```yaml
proxy:
  enabled: true
  http_proxy: "http://proxy.example.com:3128"
  https_proxy: "http://proxy.example.com:3128"
  no_proxy: "localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,10.42.0.0/16,10.43.0.0/16,.svc,.svc.cluster.local,.cluster.local"
```

When ``proxy.enabled`` is ``true``, OnRamp automatically configures
proxy settings for all deployment steps, including:

* Ansible tasks that download packages and scripts (``apt``, ``pip``,
  ``get_url``, ``git``, ``helm``).
* The Docker daemon on nodes that run Docker-based components
  (gNBsim, OAI, srsRAN, etc.), so that ``docker pull`` works
  through the proxy.
* RKE2's embedded containerd runtime on Kubernetes master and worker
  nodes, so that container image pulls work through the proxy.

Adjust ``no_proxy`` to include any additional internal hosts or
domains that should bypass the proxy. The default value covers
localhost, private RFC 1918 subnets, and Kubernetes internal domains.

You might also check the `vars` directory of this repo, where file
`main.yml` specifies global variables used to configure how Aether is
deployed. By default, it is configured for the Quick Start deployment.
The other files define other common configurations, any one of which
you can copy to `main.yml`, and then edit to account for your local
details. These alternative configurations are identified in the README.

## Deploying Offline / On Local Mirrors (Airgap)

Several roles run `apt: update_cache=yes` to refresh the apt cache
before installing packages (`iptables` in the 5gc/router, gnbsim/router,
and oai/router roles, `software-properties-common` in
amp/monitor, the docker-ce stack in srsran/ocudu/oai/n3iwf/gnbsim/
oscric docker roles, build deps in ueransim/simulator). On a host
that can not reach upstream apt archives — airgapped sites, baked
images, internal mirrors that do not need upstream refresh — that
refresh hard-fails and aborts the install.

Set the `airgapped` block in `vars/main.yml` (and in any
`vars/main-<flavor>.yml` you `cp` over `main.yml`) to opt out:

```yaml
airgapped:
  enabled: true
```

When `enabled: true`, every gated `apt: update_cache` call site is
skipped. Operators are responsible for ensuring the required
packages are already installed (offline bundle, baked image, or a
local mirror keeping the apt cache fresh out-of-band) before running
the install. The default (`enabled: false`) preserves online
behaviour — apt cache is refreshed as before.
