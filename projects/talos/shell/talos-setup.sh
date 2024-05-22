#!/bin/zsh

CLUSTERNAME=turingpi1
IPS=( "192.168.68.53" "192.168.68.55" "192.168.68.56" )
HOSTNAMES=( "tp-node1" "tp-node2" "tp-node4" )
ROLES=( "controlplane" "controlplane" "controlplane" )
ALLOW_SCHEDULING_ON_CONTROLPLANE=true
ENDPOINT_IP="192.168.50.2"
IMAGE=metal-turing_rk1-arm64_v1.7.2.raw

LONGHORN_NS=longhorn-system
LONGHORN_MOUNT=/var/mnt/longhorn

INSTALLER=ghcr.io/nullbutt/installer:v1.7.2-1

# The TS_AUTHKEY will be set in the terminal environment
TS_AUTHKEY="${TS_AUTHKEY}"

# Function to check if a command exists
command_exists() {
  type "$1" &> /dev/null
}

# Check required commands
for cmd in tpi talosctl kubectl helm yq; do
  if ! command_exists $cmd; then
    echo "*** $cmd must be installed! ***"
    exit 1
  fi
done

# Check image file exists
if [ ! -f "$IMAGE" ]; then
  echo "*** Image $IMAGE must exist on the filesystem, but it is not! ***"
  exit 1
fi

# Flash nodes and power on (excluding node 3 which is index 2)
for node in 1 2 4; do
  echo "Flashing node #$node / ${HOSTNAMES[$node-1]} with $IMAGE..."
  tpi flash -n $node -i $IMAGE
  tpi power on -n $node
done

# Create controlplane patch configuration
cat << EOF > ${CLUSTERNAME}-controlplane-patch.yaml
# Rockchip additions:
- op: add
  path: /machine/kernel
  value:
    modules:
      - name: rockchip-cpufreq
- op: replace
  path: /machine/install/disk
  value: /dev/mmcblk0
- op: add
  path: /machine/install/extraKernelArgs
  value:
    - irqchip.gicv3_pseudo_nmi=0
- op: replace
  path: /machine/install/image
  value: ${INSTALLER}

# Time:
- op: add
  path: /machine/time
  value:
    servers:
      - time.cloudflare.com
      - time.nist.gov
    bootTimeout: 2m0s

# Longhorn:
- op: add
  path: /machine/kubelet/extraMounts
  value:
    - destination: ${LONGHORN_MOUNT}
      type: bind
      source: ${LONGHORN_MOUNT}
      options:
        - bind
        - rshared
        - rw
- op: add
  path: /machine/disks
  value:
    - device: /dev/nvme0n1
      partitions:
        - mountpoint: ${LONGHORN_MOUNT}
# HugePages (for Longhorn):
- op: add
  path: /machine/sysctls
  value:
    vm.nr_hugepages: "1024"

# Cilium:
- op: add 
  path: /cluster/network/cni
  value:
    name: none

# Network:
- op: add
  path: /machine/network/interfaces
  value:
    - deviceSelector:
        busPath: "fe1c0000.ethernet"
      dhcp: true

# Control Plane VIP:
- op: add
  path: /machine/network/vip
  value:
    ip: $ENDPOINT_IP
# Misc:
- op: add
  path: /cluster/allowSchedulingOnControlPlanes
  value: $ALLOW_SCHEDULING_ON_CONTROLPLANE

# Exempt Longhorn namespace from admission control (next to 'kube-system'):
- op: add
  path: /cluster/apiServer/admissionControl/0/configuration/exemptions/namespaces/-
  value: $LONGHORN_NS

# Cilium:
- op: add 
  path: /cluster/proxy
  value:
    disabled: true
EOF

if [ -f secrets.yaml ]; then
  echo "Secrets already available, not overwriting."
else
  echo "Generating secrets..."
  talosctl gen secrets --output-file secrets.yaml
fi

echo "Generating general controlplane configurations..."
talosctl gen config $CLUSTERNAME https://${ENDPOINT_IP}:6443 \
         --with-secrets secrets.yaml \
         --config-patch-control-plane @${CLUSTERNAME}-controlplane-patch.yaml \
         --force

for node in 1 2 4; do
  echo "Generating config for ${ROLES[$node-1]} ${HOSTNAMES[$node-1]}..."
  talosctl machineconfig patch controlplane.yaml \
          --patch '[{"op": "add", "path": "/machine/network/hostname", "value": "'${HOSTNAMES[$node-1]}'"}]' \
          --output ${HOSTNAMES[$node-1]}.yaml
done

for node in 1 2 4; do
  printf "Waiting for node #$node to be ready..."
  until nc -zw 3 ${IPS[@]:$node-1:1} 50000; do sleep 3; printf '.'; done
  echo "Node ${HOSTNAMES[$node-1]} is ready!"
  echo "Applying config ${HOSTNAMES[$node-1]} to ${ROLES[$node-1]} at IP ${IPS[@]:$node-1:1}..."
  talosctl apply config \
           --file ${HOSTNAMES[$node-1]}.yaml \
           --nodes ${IPS[@]:$node-1:1} \
           --insecure
done

if [ -f ~/.talos/config ]; then
  echo "First, remove old Talos config for ${CLUSTERNAME}..."
  yq -i e "del(.contexts.${CLUSTERNAME})" ~/.talos/config
fi
echo "Merging Talos configs..."
talosctl config merge ./talosconfig --nodes $(echo ${IPS[@]} | tr ' ' ',')
# Replace 127.0.0.1 endpoint with the IP of the first node (ENDPOINT_IP is not available yet):
yq -i e ".contexts.${CLUSTERNAME}.endpoints += [\"${IPS[@]:0:1}\"]" ~/.talos/config
yq -i e ".contexts.${CLUSTERNAME}.endpoints -= [\"127.0.0.1\"]" ~/.talos/config

echo "Waiting for all nodes to be up and running..."
for node in 1 2 4; do
  until nc -zw 3 ${IPS[@]:$node-1:1} 50000; do sleep 3; printf '.'; done
  echo "Node ${HOSTNAMES[$node-1]} is ready!"
done

echo "Bootstrapping Kubernetes at ${IPS[@]:0:1}..."
talosctl bootstrap --nodes ${IPS[@]:0:1}

echo "Creating Kubernetes config..."
# Replace the IP of the first node with the Kubernetes endpoint:
yq -i e ".contexts.${CLUSTERNAME}.endpoints += [\"${ENDPOINT_IP}\"]" ~/.talos/config
yq -i e ".contexts.${CLUSTERNAME}.endpoints -= [\"${IPS[@]:0:1}\"]" ~/.talos/config

if [ -f ~/.kube/config ]; then
  echo "First, remove old Kubernetes context config for ${CLUSTERNAME}..."
  yq -i e "del(.clusters[] | select(.name == \"${CLUSTERNAME}\"))" ~/.kube/config
  yq -i e "del(.users[] | select(.name == \"admin@${CLUSTERNAME}\"))" ~/.kube/config
  yq -i e "del(.contexts[] | select(.name == \"admin@${CLUSTERNAME}\"))" ~/.kube/config
fi
talosctl kubeconfig --nodes ${IPS[@]:0:1}

echo "Waiting until nodes are ready..."
until kubectl get nodes | grep -qF "Ready"; do sleep 3; done

echo "Kubernetes nodes installed:"
kubectl get nodes -o wide

for node in 1 2 4; do
  echo "'Upgrading' ${HOSTNAMES[$node-1]} with extensions from ${INSTALLER}..."
  talosctl upgrade \
           --image ${INSTALLER} \
           --nodes ${IPS[@]:$node-1:1} \
           --timeout 3m0s \
           --force
done

echo "Waiting for all nodes to be up and running..."
for node in 1 2 4; do
  until nc -zw 3 ${IPS[@]:$node-1:1} 50000; do sleep 3; printf '.'; done
  echo "Node ${HOSTNAMES[$node-1]} is ready!"
done

# Create Tailscale configuration
cat << EOF > tailscale-config.yaml
---
apiVersion: v1alpha1
kind: ExtensionServiceConfig
name: tailscale
environment:
  - TS_AUTHKEY=${TS_AUTHKEY}
EOF

# Apply Tailscale configuration to each node (excluding node 3)
for node in 1 2 4; do
  echo "Applying Tailscale configuration to ${HOSTNAMES[$node-1]} at IP ${IPS[@]:$node-1:1}..."
  talosctl patch mc -p @tailscale-config.yaml --nodes ${IPS[@]:$node-1:1}
done

echo "Verifying Tailscale extension is in place..."
for node in 1 2 4; do
  talosctl get extensionserviceconfigs --nodes ${IPS[@]:$node-1:1}
done

helm repo add cilium https://helm.cilium.io/
helm repo update cilium
CILIUM_LATEST=$(helm search repo cilium --versions --output yaml | yq '.[0].version')
echo "Installing Cilium version ${CILIUM_LATEST}..."
helm install cilium cilium/cilium \
     --version ${CILIUM_LATEST} \
     --namespace kube-system \
     --set ipam.mode=kubernetes \
     --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
     --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
     --set cgroup.autoMount.enabled=false \
     --set cgroup.hostRoot=/sys/fs/cgroup \
     --set l2announcements.enabled=true \
     --set kubeProxyReplacement=true \
     --set loadBalancer.acceleration=native \
     --set k8sServiceHost=127.0.0.1 \
     --set k8sServicePort=7445 \
     --set bpf.masquerade=true \
     --set ingressController.enabled=true \
     --set ingressController.default=true \
     --set ingressController.loadbalancerMode=dedicated \
     --set bgpControlPlane.enabled=true \
     --set hubble.relay.enabled=true \
     --set hubble.ui.enabled=true

echo "Waiting for all Cilium pods to be Running..."
kubectl wait pod \
        --namespace kube-system \
        --for condition=Ready \
        --timeout 2m0s \
        --all
if type cilium &> /dev/null; then
  cilium version
  cilium status
fi

helm repo add longhorn https://charts.longhorn.io
helm repo update longhorn
LONGHORN_LATEST=$(helm search repo longhorn --versions --output yaml | yq '.[0].version')
echo "Installing Longhorn storage provider version ${LONGHORN_LATEST}..."
helm install longhorn longhorn/longhorn \
     --namespace ${LONGHORN_NS} \
     --create-namespace \
     --version ${LONGHORN_LATEST} \
     --set defaultSettings.defaultReplicaCount=2 \
     --set defaultSettings.defaultDataLocality="best-effort" \
     --set defaultSettings.defaultDataPath=${LONGHORN_MOUNT} \
     --set namespaceOverride=${LONGHORN_NS}

echo "Waiting for all Longhorn pods to be Running..."
kubectl wait pod \
        --namespace ${LONGHORN_NS} \
        --for condition=Ready \
        --timeout 2m0s \
        --all

echo "Cluster setup complete."

