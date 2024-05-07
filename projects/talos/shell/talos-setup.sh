#!/bin/sh

CLUSTERNAME=turingpi1
IPS=(      "192.168.50.11" "192.168.50.12" "192.168.50.13" "192.168.50.14")
HOSTNAMES=("talos-tp1-n1"  "talos-tp1-n2"  "talos-tp1-n3"  "talos-tp1-n4")
ROLES=(    "controlplane"  "controlplane"  "controlplane"  "worker")
ALLOW_SCHEDULING_ON_CONTROLPLANE=true
ENDPOINT_IP="192.168.50.2"
IMAGE=metal-turing_rk1-arm64_v1.7.1.raw

LONGHORN_NS=longhorn-system
LONGHORN_MOUNT=/var/mnt/longhorn

INSTALLER=ghcr.io/bguijt/installer:v1.7.1-1
# INSTALLER Image is created by the following commands:
#
# docker run --rm -t -v $PWD/_out:/out ghcr.io/nberlee/imager:v1.7.1 installer \
#        --arch arm64 \
#        --board turing_rk1 \
#        --platform metal \
#        --base-installer-image ghcr.io/nberlee/installer:v1.7.1-rk3588 \
#        --system-extension-image ghcr.io/nberlee/rk3588:v1.7.1@sha256:239ef59bb67c48436e242fd9e39c3ef6b041e7becc1e59351d3e01495bb4e290 \
#        --system-extension-image ghcr.io/siderolabs/wasmedge:v0.3.0@sha256:fcc7b087d1f08cb65a715c23bedda113233574882b89026075028599b0cb0c37 \
#        --system-extension-image ghcr.io/siderolabs/iscsi-tools:v0.1.4@sha256:32d67987046ef28dcb9c54a6b34d6055eb6d78ac4ff78fa18dc6181cf31668be \
#        --system-extension-image ghcr.io/siderolabs/util-linux-tools:2.39.3@sha256:1cdfab848cc2a6c2515f33ea732ac8ca34fe1a79a8bd99db6287f937b948b8f2
#
# crane push _out/installer-arm64.tar ${INSTALLER}

if ! type tpi &> /dev/null; then
  echo "*** tpi must be installed! Install 'tpi': https://github.com/turing-machines/tpi ***"
  exit 1
fi

if ! type talosctl &> /dev/null; then
  echo "*** talosctl must be installed! Install 'talosctl': https://github.com/siderolabs/homebrew-tap ***"
  exit 1
fi

if ! type kubectl &> /dev/null; then
  echo "*** kubectl must be installed! Install 'kubectl': https://kubernetes.io/docs/tasks/tools/install-kubectl-macos/ ***"
  exit 1
fi

if ! type helm &> /dev/null; then
  echo "*** helm must be installed! Install 'helm': https://helm.sh/docs/intro/install/ ***"
  exit 1
fi

if ! type yq &> /dev/null; then
  echo "*** yq (version 4+) must be installed! Install 'yq': https://github.com/mikefarah/yq/#install ***"
  exit 1
fi

if [ ! -f "$IMAGE" ]; then
  echo "*** Image $IMAGE must exist on the filesystem, but it is not! ***"
  exit 1
fi

for node in 0 1 2 3; do
  echo "Flashing node #$((node+1)) / ${HOSTNAMES[@]:$node:1} with $IMAGE..."
  tpi flash -n $((node+1)) -i $IMAGE
  tpi power on -n $((node+1))
  # echo "Resetting Talos node #$((node+1)) / ${HOSTNAMES[@]:$node:1}..."
  # talosctl reset \
  #          --nodes ${IPS[@]:$node:1} \
  #          --wipe-mode all \
  #          --reboot
done

cat << EOF > ${CLUSTERNAME}-worker-patch.yaml
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
        #driver: rk_gmac-dwmac
        busPath: "fe1c0000.ethernet"
      dhcp: true
EOF

cp -f ${CLUSTERNAME}-worker-patch.yaml ${CLUSTERNAME}-controlplane-patch.yaml
cat << EOF >> ${CLUSTERNAME}-controlplane-patch.yaml
      vip:
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

echo "Generating general controlplane and worker configurations..."
talosctl gen config $CLUSTERNAME https://${ENDPOINT_IP}:6443 \
         --with-secrets secrets.yaml \
         --config-patch-control-plane @${CLUSTERNAME}-controlplane-patch.yaml \
         --config-patch-worker @${CLUSTERNAME}-worker-patch.yaml \
         --force

for node in 0 1 2 3; do
  echo "Generating config for ${ROLES[@]:$node:1} ${HOSTNAMES[@]:$node:1}..."
  talosctl machineconfig patch ${ROLES[@]:$node:1}.yaml \
          --patch '[{"op": "add", "path": "/machine/network/hostname", "value": "'${HOSTNAMES[@]:$node:1}'"}]' \
          --output ${HOSTNAMES[@]:$node:1}.yaml
done

for node in 0 1 2 3; do
  printf "Waiting for node #$((node+1)) to be ready..."
  until nc -zw 3 ${IPS[@]:$node:1} 50000; do sleep 3; printf '.'; done
  echo "Applying config ${HOSTNAMES[@]:$node:1} to ${ROLES[@]:$node:1} at IP ${IPS[@]:$node:1}..."
  talosctl apply config \
           --file ${HOSTNAMES[@]:$node:1}.yaml \
           --nodes ${IPS[@]:$node:1} \
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
for node in 0 1 2 3; do
  until nc -zw 3 ${IPS[@]:$node:1} 50000; do sleep 3; printf '.'; done
  echo "Node ${HOSTNAMES[@]:$node:1} is ready!"
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
# Wel, ready... we like 'NotReady' as well because at least the API service is responsive:
until kubectl get nodes | grep -qF "Ready"; do sleep 3; done
#kubectl wait nodes --for condition=Ready --all --timeout 5m0s

echo "Kubernetes nodes installed:"
kubectl get nodes -o wide

for node in 0 1 2 3; do
  echo "'Upgrading' ${HOSTNAMES[$node]} with extensions from ${INSTALLER}..."
  talosctl upgrade \
           --image ${INSTALLER} \
           --nodes ${IPS[@]:$node:1} \
           --timeout 3m0s \
           --force
done

echo "Waiting for all nodes to be up and running..."
for node in 0 1 2 3; do
  until nc -zw 3 ${IPS[@]:$node:1} 50000; do sleep 3; printf '.'; done
  echo "Node ${HOSTNAMES[@]:$node:1} is ready!"
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

echo "Adding RuntimeClass for WASM workloads..."
kubectl apply -f - << EOF
kind: RuntimeClass
apiVersion: node.k8s.io/v1
metadata:
  name: wasm
handler: wasmedge
EOF

kubectl get runtimeclasses
