#!/usr/bin/env bash
# Aether OnRamp one-click: RKE2 + SD-Core 5G core + verification (no RAN/gNBsim).
#   git clone <this repo> ~/aether-onramp && cd ~/aether-onramp && ./oneclick.sh
# Host prereqs + auto-config happen here; everything else is OnRamp make/Ansible:
#   make aether-sdcore-oneclick = aether-pingall k8s-install 5gc-install aether-sdcore-verify
# Overrides: NODE_IP=.. IFACE=.. RAN_SUBNET=a.b.0.0/16 ./oneclick.sh
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
export PATH=$HOME/.local/bin:/var/lib/rancher/rke2/bin:$PATH
log(){ echo -e "\n\033[1;36m[oneclick $(date +%T)] $*\033[0m"; }

IFACE=${IFACE:-$(ip -o -4 route show default | awk "{print \$5; exit}")}
NODE_IP=${NODE_IP:-$(ip -o -4 addr show dev "$IFACE" | awk "{split(\$4,a,\"/\"); print a[1]; exit}")}
if [[ -z "${RAN_SUBNET:-}" ]]; then         # default 172.20/16 clashes with kind/docker nets
  RAN_SUBNET=172.20.0.0/16
  ip -o -4 route | grep -q "^172\.20\." && RAN_SUBNET=172.30.0.0/16
fi
RAN_PREFIX=$(echo "$RAN_SUBNET" | cut -d. -f1-2)
log "iface=$IFACE node_ip=$NODE_IP ran_subnet=$RAN_SUBNET"
[[ -n "$IFACE" && -n "$NODE_IP" ]] || { echo "cannot detect IFACE/NODE_IP"; exit 1; }
sudo -n true || { echo "passwordless sudo required"; exit 1; }

log "host prerequisites"
if ! command -v ansible-playbook >/dev/null; then
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq make git pipx python3-venv sshpass
  pipx install --include-deps ansible     # jammy apt ansible 2.10 is too old for community.docker 5.x
fi
ansible-galaxy collection install -r requirements.yml >/dev/null
[[ -f ~/.ssh/id_ed25519 ]] || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -q
touch ~/.ssh/authorized_keys
grep -qF "$(cat ~/.ssh/id_ed25519.pub)" ~/.ssh/authorized_keys || cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new 127.0.0.1 true

log "configure hosts.ini + vars/main.yml"
sed -i "s/^node1 ansible_host=.*/node1 ansible_host=127.0.0.1 ansible_user=$USER/" hosts.ini
sed -i -E -e "s/^(\s*data_iface:).*/\1 $IFACE/" \
          -e "s#^(\s*ran_subnet:) \"[^\"]*\"#\1 \"$RAN_SUBNET\"#" \
          -e "s/^(\s*subnet_prefix:) \"[^\"]*\"/\1 \"$RAN_PREFIX\"/" \
          -e "/^  amf:/,/ip:/ s/^(\s*ip:) \"[^\"]*\"/\1 \"$NODE_IP\"/" vars/main.yml
grep -nE "data_iface|ran_subnet|subnet_prefix|^\s+ip: \"$NODE_IP\"" vars/main.yml

# OnRamp copies rke2.yaml over ~/.kube/config; keep any pre-existing clusters (e.g. kind).
if [[ -f ~/.kube/config && ! -f ~/.kube/pre-aether.config ]] && ! grep -q "server: https://127.0.0.1:6443" ~/.kube/config; then
  cp ~/.kube/config ~/.kube/pre-aether.config; log "saved existing kubeconfig -> ~/.kube/pre-aether.config"
fi

# Rerun safety: a half-installed sd-core release (helm failed/pending) cannot be
# upgraded cleanly, so remove it first. Pulled images stay cached in containerd.
if [[ -x /usr/local/bin/helm && -f /etc/rancher/rke2/rke2.yaml ]]; then
  st=$(sudo /usr/local/bin/helm --kubeconfig /etc/rancher/rke2/rke2.yaml -n aether-5gc status sd-core -o json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['info']['status'])" 2>/dev/null || true)
  if [[ -n "$st" && "$st" != "deployed" ]]; then
    log "sd-core release is '$st' from a previous run -> make 5gc-core-uninstall"
    make 5gc-core-uninstall
  fi
fi

rc=0; make aether-sdcore-oneclick || rc=$?

if [[ -f ~/.kube/pre-aether.config && -f /etc/rancher/rke2/rke2.yaml ]]; then
  sudo cat /etc/rancher/rke2/rke2.yaml | sed -e "s/: default$/: aether-rke2/" -e "s/name: default/name: aether-rke2/" > ~/.kube/aether-rke2.config
  KUBECONFIG=~/.kube/aether-rke2.config:~/.kube/pre-aether.config kubectl config view --flatten > ~/.kube/config.new
  mv ~/.kube/config.new ~/.kube/config; chmod 600 ~/.kube/config
  kubectl config use-context aether-rke2 >/dev/null
  log "kubeconfig merged: $(kubectl config get-contexts -o name | tr "\n" " ")(current: aether-rke2)"
fi
[[ $rc -eq 0 ]] && log "DONE: SD-Core deployed and verified (AMF N2 at $NODE_IP:38412)" || log "FAILED (rc=$rc)"
exit $rc
