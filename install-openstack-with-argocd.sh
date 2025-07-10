#!/bin/bash


set -xe

export KUBECONFIG=~/kub-poc.kubeconfig

kubectl --kubeconfig ~/kub-poc.kubeconfig patch node vm01 -p '{"spec":{"taints":[]}}' || true
kubectl --kubeconfig ~/kub-poc.kubeconfig patch node vm02 -p '{"spec":{"taints":[]}}' || true
kubectl --kubeconfig ~/kub-poc.kubeconfig patch node vm03 -p '{"spec":{"taints":[]}}' || true

kubectl --kubeconfig ~/kub-poc.kubeconfig label --overwrite nodes --all openstack-control-plane=enabled
kubectl --kubeconfig ~/kub-poc.kubeconfig label --overwrite nodes --all openstack-compute-node=enabled
kubectl --kubeconfig ~/kub-poc.kubeconfig label --overwrite nodes --all openvswitch=enabled
kubectl --kubeconfig ~/kub-poc.kubeconfig label --overwrite nodes --all linuxbridge=enabled


# use argocd

argocd app sync openstack-ingress-nginx
argocd app sync openstack-public-ip
argocd app sync openstack-rabbitmq
argocd app sync openstack-memcached
argocd app sync openstack-mariadb
argocd app sync openstack-keystone
argocd app sync openstack-glance
argocd app sync openstack-libvirt
argocd app sync openstack-placement
argocd app sync openstack-neutron

exit

# use local helm

helm repo add openstack-helm https://tarballs.opendev.org/openstack/openstack-helm
helm plugin install https://opendev.org/openstack/openstack-helm-plugin || helm plugin update osh || true

tee > /tmp/ceph_adpater.yaml <<EOF
ceph_cluster_namespace: rook-ceph
admin_secret_namespace: rook-ceph
endpoints:
  cluster_domain_suffix: cluster.local
  ceph_mon:
    namespace: rook-ceph
EOF

# this chart upgrade resets the mon discovery configmap: configmap/ceph-etc -n openstack
# do not upgrade!!!
helm install ceph-adapter-rook openstack-helm/ceph-adapter-rook --namespace=openstack --values /tmp/ceph_adpater.yaml || true
    helm osh get-values-overrides -d -u ${OVERRIDES_URL} -p ${OVERRIDES_DIR} -c ${chart} ${FEATURES}
done

KUBECONFIG=~/kub-poc.kubeconfig kubectl node-shell vm01 -- sh -c 'chmod 777 /dev/kvm'
KUBECONFIG=~/kub-poc.kubeconfig kubectl node-shell vm02 -- sh -c 'chmod 777 /dev/kvm'
KUBECONFIG=~/kub-poc.kubeconfig kubectl node-shell vm03 -- sh -c 'chmod 777 /dev/kvm'

source ~/openstack-client/bin/activate

rand_suffix=$(dd of=/tmp/rand if=/dev/random bs=1M count=1 && md5sum /tmp/rand | awk '{print $1}')

openstack --os-cloud openstack_helm net show private || openstack --os-cloud openstack_helm net create private
openstack --os-cloud openstack_helm subnet show private || openstack --os-cloud openstack_helm subnet create private --network private --subnet-range 10.5.0.0/24
openstack --os-cloud openstack_helm server create --image 'Cirros 0.6.2 64-bit' --flavor m1.tiny --network private cirros-$rand_suffix
sleep 10
until openstack --os-cloud openstack_helm console log show cirros-$rand_suffix | grep -i gocubsgo; do sleep 1 && echo 'Trying again'; done

