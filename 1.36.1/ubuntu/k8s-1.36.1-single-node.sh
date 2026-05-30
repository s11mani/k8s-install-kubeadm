#!/bin/bash

set -e

HOSTNAME_NAME="k8s-master"

echo "===== Setting hostname ====="
hostnamectl set-hostname ${HOSTNAME_NAME}

grep -q "${HOSTNAME_NAME}" /etc/hosts || echo "127.0.1.1 ${HOSTNAME_NAME}" >> /etc/hosts

echo "===== Updating system ====="
apt update -y
apt upgrade -y

echo "===== Disabling swap ====="
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

echo "===== Loading kernel modules ====="
cat <<EOF >/etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

echo "===== Configuring sysctl ====="
cat <<EOF >/etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF

sysctl --system

echo "===== Installing containerd ====="
apt install -y containerd

mkdir -p /etc/containerd

containerd config default > /etc/containerd/config.toml

sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' \
/etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd

echo "===== Installing Kubernetes v1.36 ====="

apt-get install -y apt-transport-https ca-certificates curl gpg

mkdir -p /etc/apt/keyrings

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key \
| gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /" \
> /etc/apt/sources.list.d/kubernetes.list

apt update

apt install -y kubelet kubeadm kubectl

apt-mark hold kubelet kubeadm kubectl

systemctl enable kubelet

echo "===== Initializing Kubernetes Cluster ====="

kubeadm init \
  --pod-network-cidr=192.168.0.0/16

echo "===== Configuring kubectl ====="

mkdir -p $HOME/.kube

cp /etc/kubernetes/admin.conf $HOME/.kube/config

chown $(id -u):$(id -g) $HOME/.kube/config

export KUBECONFIG=$HOME/.kube/config

echo "===== Installing Calico ====="

kubectl apply -f \
https://raw.githubusercontent.com/projectcalico/calico/v3.30.3/manifests/calico.yaml

echo "===== Waiting for Calico ====="

kubectl wait --for=condition=Ready pods \
  -n kube-system \
  --all \
  --timeout=300s || true

echo "===== Removing Control Plane Taint ====="

kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

echo "===== Installing Helm ====="

curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

helm version

echo "===== Adding ingress-nginx Helm Repository ====="

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx

helm repo update

echo "===== Creating ingress-nginx values.yaml ====="

cat <<EOF > values.yaml
controller:
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
EOF

echo "===== Installing ingress-nginx ====="

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  -f values.yaml

echo "===== Waiting for ingress-nginx ====="

kubectl rollout status deployment/ingress-nginx-controller \
  -n ingress-nginx \
  --timeout=60s || true

echo "===== Cluster Status ====="

kubectl get nodes -o wide

echo ""
echo "===== System Pods ====="
kubectl get pods -A
echo ""
