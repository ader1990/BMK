#!/bin/bash

set -xe

sudo ls

CURRENT_BRANCH=$(git branch --show-current)
OLD_CURRENT_BRANCH="argocd-arm64-altra-mariner-amd64hybrid-nativemetallb-bitnamisecrets1"

DEPLOYMENT_TYPE="baremetal"

export IP_SUBNET_PREFIX="10.8.10"
export IP_BMC_SUBNET_PREFIX="10.8.0"

export MANAGEMENT_VIP_NIC="enp1s0f0np0"
export MANAGEMENT_HOST_IP="${IP_SUBNET_PREFIX}.2"
export MANAGEMENT_HOST_IP_CIDR="${MANAGEMENT_HOST_IP}/32"

export MANAGEMENT_ARGOCD_IP="${IP_SUBNET_PREFIX}.133"
export MANAGEMENT_TINKERBELL_IP="${IP_SUBNET_PREFIX}.130"
export OLD_MANAGEMENT_TINKERBELL_IP="${IP_SUBNET_PREFIX}.120"
export MANAGEMENT_TINKERBELL_HTTP="http://${MANAGEMENT_TINKERBELL_IP}:8080"
export MANAGEMENT_TINKERBELL_GRPC="${MANAGEMENT_TINKERBELL_IP}:42113"

export WORKLOAD_K8S_GATEWAY="${IP_SUBNET_PREFIX}.1"
export WORKLOAD_K8S_IP="${IP_SUBNET_PREFIX}.151"
export WORKLOAD_K8S_IP_POOL="${IP_SUBNET_PREFIX}.144/29"

export WORKLOAD_K8S_SERVER_IP_1="${IP_SUBNET_PREFIX}.42"
export WORKLOAD_K8S_SERVER_BMC_IP_1="${IP_BMC_SUBNET_PREFIX}.243"

# https://github.com/mikefarah/yq/releases/download/v4.33.3/yq_linux_arm64

sed -i "s/${OLD_CURRENT_BRANCH}/${CURRENT_BRANCH}/g" applications/workload/templates/*
sed -i "s/${OLD_CURRENT_BRANCH}/${CURRENT_BRANCH}/g" applications/management/templates/*

check_git_diff=`git diff`

if [[ "${check_git_diff}" != "" ]]
then
  echo "please commit the changes first: ${check_git_diff}"
  exit 1
fi

# Start the deployment
k3d cluster list k3s-default || k3d cluster create --network host --no-lb --k3s-arg "--disable=traefik,servicelb" \
  --k3s-arg "--kube-apiserver-arg=feature-gates=MixedProtocolLBService=true" \
  --host-pid-mode

mkdir -p ~/.kube/
k3d kubeconfig get -a >~/.kube/config
until kubectl wait --for=condition=Ready nodes --all --timeout=600s; do sleep 1; done

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add argo-cd https://argoproj.github.io/argo-helm
helm repo add kube-vip https://kube-vip.github.io/helm-charts/
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo update

helm upgrade --install sealed-secrets --namespace kube-system --version 2.13.0 sealed-secrets/sealed-secrets
# echo "---" > sealed_secrets_main.key
# kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml >> sealed_secrets_main.key
# remove sealed_secrets_main.key resource version and uuid
# cat bmc-auth/bmc-altra-auth.yaml | kubeseal --controller-namespace kube-system --controller-name sealed-secrets --format yaml > config/management/machine/bmc-altra-auth-sealed.yaml
# cat bmc-auth/bmc-altra-auth-02.yaml | kubeseal --controller-namespace kube-system --controller-name sealed-secrets --format yaml > config/management/machine/bmc-altra-auth-02-sealed.yaml

kubectl apply -f sealed_secrets_main.key 

kubectl delete pod -n kube-system -l app.kubernetes.io/name=sealed-secrets

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --version 4.5.2 --namespace ingress-nginx \
  --create-namespace \
  -f helm/config/management/ingress-nginx/values.yaml \
  --set-json "controller.service.loadBalancerIP=\"${MANAGEMENT_ARGOCD_IP}\""

until kubectl wait deployment -n ingress-nginx ingress-nginx-controller --for condition=Available=True --timeout=90s; do sleep 1; done

helm upgrade --install kube-vip kube-vip/kube-vip --version v0.8.0 \
  --namespace kube-vip --create-namespace \
  -f helm/config/management/ingress-nginx/kube-vip-values.yaml \
  --set-json ".env.vip_interface=\"${MANAGEMENT_VIP_NIC}\""

helm upgrade --install argo-cd \
  --create-namespace --namespace argo-cd \
  -f helm/config/management/argocd/values.yaml argo-cd/argo-cd \
  --set-json "global.hostAliases=[{\"ip\":\"${MANAGEMENT_ARGOCD_IP}\",\"hostnames\":[\"argo-cd.mgmt.kub-poc.local\"]}]"

until kubectl wait deployment -n argo-cd argo-cd-argocd-server --for condition=Available=True --timeout=90s; do sleep 1; done
until kubectl wait deployment -n argo-cd argo-cd-argocd-applicationset-controller --for condition=Available=True --timeout=90s; do sleep 1; done
until kubectl wait deployment -n argo-cd argo-cd-argocd-repo-server --for condition=Available=True --timeout=90s; do sleep 1; done

echo "${MANAGEMENT_ARGOCD_IP} argo-cd.mgmt.kub-poc.local" | sudo tee -a /etc/hosts

pass=$(kubectl -n argo-cd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
argocd repo list || argocd login argo-cd.mgmt.kub-poc.local --username admin --password $pass --insecure

until argocd repo list; do sleep 1; done

argocd repo add git@github.com:ader1990/BMK.git \
    --ssh-private-key-path ~/.ssh/id_rsa

argocd app sync management-apps || argocd app create management-apps \
    --repo git@github.com:ader1990/BMK.git \
    --path applications/management --dest-namespace argo-cd \
    --dest-server https://kubernetes.default.svc \
    --revision "${CURRENT_BRANCH}" --sync-policy automated

argocd app sync management-apps
argocd app get management-apps --hard-refresh

# until argocd app sync monitoring; do sleep 5; done

argocd app set tink-stack -p stack.loadBalancerIP="${MANAGEMENT_TINKERBELL_IP}"
argocd app set tink-stack -p smee.publicIP="${MANAGEMENT_TINKERBELL_IP}"
argocd app sync tink-stack

until kubectl wait deployment -n tink-system tink-stack --for condition=Available=True --timeout=90s; do sleep 1; done

until kubectl get hardware -A; do sleep 1; done

export TINKERBELL_IP="${MANAGEMENT_TINKERBELL_IP}"

rm -rf  ~/.cluster-api
mkdir -p ~/.cluster-api
cat > ~/.cluster-api/clusterctl.yaml <<EOF
providers:
  - name: "tinkerbell"
    url: "https://github.com/tinkerbell/cluster-api-provider-tinkerbell/releases/v0.4.0/infrastructure-components.yaml"
    type: "InfrastructureProvider"
EOF

export EXP_KUBEADM_BOOTSTRAP_FORMAT_IGNITION="true"
# GOPROXY=off 
clusterctl init --infrastructure tinkerbell -v 5
# --core cluster-api:v1.7.2
#3 --bootstrap cluster-api:v1.7.2
until kubectl wait deployment -n capt-system capt-controller-manager --for condition=Available=True --timeout=90s; do sleep 1; done

until argocd app sync hardware-${DEPLOYMENT_TYPE};  do sleep 1; done
until argocd app sync workload-cluster-${DEPLOYMENT_TYPE};  do sleep 1; done
argocd app sync machine-${DEPLOYMENT_TYPE}

sleep 30

clusterctl get kubeconfig kub-poc -n tink-system > ~/kub-poc.kubeconfig || sleep 100 || clusterctl get kubeconfig kub-poc -n tink-system > ~/kub-poc.kubeconfig
until kubectl --kubeconfig ~/kub-poc.kubeconfig get node -A; do sleep 1 && clusterctl get kubeconfig kub-poc -n tink-system > ~/kub-poc.kubeconfig; done
#until kubectl --kubeconfig ~/kub-poc.kubeconfig get node vm01-proxmox; do sleep 1; done

until argocd cluster add kub-poc-admin@kub-poc \
   --kubeconfig ~/kub-poc.kubeconfig \
   --server argo-cd.mgmt.kub-poc.local \
   --insecure --yes; do sleep 1; done

argocd app create workload-cluster-apps \
    --repo git@github.com:ader1990/BMK.git \
    --path applications/workload --dest-namespace argo-cd \
    --dest-server https://kubernetes.default.svc \
    --revision "${CURRENT_BRANCH}" --sync-policy automated

kubectl --kubeconfig ~/kub-poc.kubeconfig get node -o name | sed -e 's/.*\///g' | xargs -I {} kubectl --kubeconfig ~/kub-poc.kubeconfig patch node {} -p '{"spec":{"taints":[]}}' || true

argocd app get workload-cluster-apps --hard-refresh
argocd app sync cilium-manifests || true
argocd app sync cilium-kub-poc || true

sleep 5

until kubectl --kubeconfig ~/kub-poc.kubeconfig wait deployment -n kube-system cilium-operator --for condition=Available=True --timeout=90s; do argocd app sync cilium-kub-poc || sleep 1; done
sleep 5

argocd app sync cilium-manifests --force || argocd app sync cilium-kub-poc

until kubectl get CiliumLoadBalancerIPPool --kubeconfig ~/kub-poc.kubeconfig || (argocd app sync cilium-manifests && argocd app sync cilium-kub-poc); do sleep 1; done
until (argocd app sync cilium-manifests || argocd app sync cilium-kub-poc) && kubectl get CiliumLoadBalancerIPPool --kubeconfig ~/kub-poc.kubeconfig; do sleep 1; done

until kubectl --kubeconfig ~/kub-poc.kubeconfig wait deployment -n kube-system cilium-operator --for condition=Available=True --timeout=90s; do sleep 1; done

# verify cilium load balancer
argocd app sync nginx --force --prune
until kubectl --kubeconfig ~/kub-poc.kubeconfig wait pod -n nginx nginx --for condition=Ready --timeout=90s; do sleep 1; done
# does not work on ARM64 because MSSQL images for ARM64 do not exist
# argocd app sync mssql
# until kubectl --kubeconfig ~/kub-poc.kubeconfig exec -ti deployment/kub-poc-mssql2022v3 -- /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "P@ssw0rd1" -Q "SELECT name, database_id, create_date  FROM sys.databases"; do sleep 1; done

until argocd app sync rook-ceph-operator; do sleep 5; done
until kubectl --kubeconfig ~/kub-poc.kubeconfig wait deployment -n rook-ceph rook-ceph-operator --for condition=Available=True --timeout=90s; do sleep 1; done

until argocd app sync ceph-classes; do sleep 5; done

NODES=$(kubectl --kubeconfig ~/kub-poc.kubeconfig get node -o name | sed -e 's/.*\///g')

for NODE in $NODES; do
  # cleanup nodes from previous ceph
  until KUBECONFIG=~/kub-poc.kubeconfig kubectl node-shell $NODE -- sh -c 'export DISK=$(fdisk -l | grep "Disk model: INTEL SSD" -B 1 | head -n 1 | awk '\''{print $2}'\'' | sed "s/:$//") && echo "w" | fdisk $DISK && sgdisk --zap-all $DISK && blkdiscard $DISK || sudo dd if=/dev/zero of="$DISK" bs=1M count=100 oflag=direct,dsync && partprobe $DISK && rm -rf /var/lib/rook'; do sleep 1; done;
done

until argocd app sync rook-ceph-cluster; do sleep 5; done

sleep 30
#until kubectl --kubeconfig ~/kub-poc.kubeconfig delete -n rook-ceph pod -l app=rook-ceph-mon; do sleep 1; done
until kubectl  --kubeconfig ~/kub-poc.kubeconfig -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status; do sleep 1; done

# verify ceph pvc
argocd app sync wordpress --force --prune

# verify kubevirt
# argocd app sync cdi-manifests
until argocd app sync kubevirt; do sleep 1; done;

until kubectl --kubeconfig ~/kub-poc.kubeconfig wait deployment -n kubevirt virt-api --for condition=Available=True --timeout=90s; do sleep 1; done
until kubectl --kubeconfig ~/kub-poc.kubeconfig wait deployment -n kubevirt virt-operator --for condition=Available=True --timeout=90s; do sleep 1; done

argocd app sync kubevirt-vncproxy

#until KUBECONFIG=~/kub-poc.kubeconfig kubectl node-shell sut01-altra -- sh -c "echo 'fs.inotify.max_user_watches=1048576' >> /etc/sysctl.conf && echo 'fs.inotify.max_user_instances=512' >> /etc/sysctl.conf && sysctl -p /etc/sysctl.conf"; do sleep 1; done

argocd app sync testvm --force --prune || argocd app sync testvm --force --prune

until kubectl --kubeconfig ~/kub-poc.kubeconfig wait vm/vm-example-arm64 --for condition=Ready --timeout=90s; do sleep 1; done

# upload KubeVirt Windows image PVC
# virtctl image-upload pvc win2k22-qcow2 --size=50Gi --image-path=../win2k22-core-kubevirt-14052024.qcow2.gz     --uploadproxy-url https://cdi-uploadproxy:31001 --insecure

