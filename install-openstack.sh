#!/bin/bash


set -xe

export KUBECONFIG=~/kub-poc.kubeconfig

kubectl --kubeconfig ~/kub-poc.kubeconfig patch node vm01 -p '{"spec":{"taints":[]}}' || true
kubectl --kubeconfig ~/kub-poc.kubeconfig patch node vm02 -p '{"spec":{"taints":[]}}' || true
kubectl --kubeconfig ~/kub-poc.kubeconfig patch node vm03 -p '{"spec":{"taints":[]}}' || true

kubectl label --overwrite nodes --all openstack-control-plane=enabled
kubectl label --overwrite nodes --all openstack-compute-node=enabled
kubectl label --overwrite nodes --all openvswitch=enabled
kubectl label --overwrite nodes --all linuxbridge=enabled


# use argocd

argocd app sync openstack-ingress-nginx
argocd app sync openstack-public-ip
argocd app sync openstack-rabbitmq

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

export OPENSTACK_RELEASE=2025.1
export FEATURES="${OPENSTACK_RELEASE} ubuntu_noble"
export OVERRIDES_DIR=$(pwd)/overrides
rm -rf $OVERRIDES_DIR

export OVERRIDES_URL=https://opendev.org/openstack/openstack-helm/raw/branch/master/values_overrides

OVERRIDES_URL=https://opendev.org/openstack/openstack-helm/raw/branch/master/values_overrides
for chart in rabbitmq mariadb memcached openvswitch libvirt keystone heat glance cinder placement nova neutron horizon; do
    helm osh get-values-overrides -d -u ${OVERRIDES_URL} -p ${OVERRIDES_DIR} -c ${chart} ${FEATURES}
done

helm upgrade --install rabbitmq openstack-helm/rabbitmq \
    --namespace=openstack \
    --set pod.replicas.server=1 \
    --timeout=600s \
    $(helm osh get-values-overrides -p ${OVERRIDES_DIR} -c rabbitmq ${FEATURES})

helm osh wait-for-pods openstack

helm upgrade --install mariadb openstack-helm/mariadb \
    --namespace=openstack \
    --set pod.replicas.server=1 \
    $(helm osh get-values-overrides -p ${OVERRIDES_DIR} -c mariadb ${FEATURES})

helm osh wait-for-pods openstack

helm upgrade --install memcached openstack-helm/memcached \
    --namespace=openstack \
    $(helm osh get-values-overrides -p ${OVERRIDES_DIR} -c memcached ${FEATURES})

helm osh wait-for-pods openstack

helm upgrade --install keystone openstack-helm/keystone \
    --namespace=openstack \
    $(helm osh get-values-overrides -p ${OVERRIDES_DIR} -c keystone ${FEATURES})

helm osh wait-for-pods openstack

helm upgrade --install heat openstack-helm/heat \
    --namespace=openstack \
    $(helm osh get-values-overrides -p ${OVERRIDES_DIR} -c heat ${FEATURES})

helm osh wait-for-pods openstack

tee ${OVERRIDES_DIR}/glance/glance_pvc_storage.yaml <<EOF
storage: pvc
volume:
  class_name: general
  size: 10Gi
EOF

helm upgrade --install glance openstack-helm/glance \
    --namespace=openstack \
    $(helm osh get-values-overrides -p ${OVERRIDES_DIR} -c glance glance_pvc_storage ${FEATURES})

helm osh wait-for-pods openstack

helm upgrade --install cinder openstack-helm/cinder \
    --namespace=openstack \
    --timeout=600s \
    $(helm osh get-values-overrides -p ${OVERRIDES_DIR} -c cinder ${FEATURES})

helm osh wait-for-pods openstack

helm upgrade --install openvswitch openstack-helm/openvswitch \
    --namespace=openstack \
    $(helm osh get-values-overrides -p ${OVERRIDES_DIR} -c openvswitch ${FEATURES})

helm osh wait-for-pods openstack

helm upgrade --install libvirt openstack-helm/libvirt \
    --namespace=openstack \
    --set conf.ceph.enabled=true \
    $(helm osh get-values-overrides -p ${OVERRIDES_DIR} -c libvirt ${FEATURES})

helm upgrade --install placement openstack-helm/placement \
    --namespace=openstack \
    $(helm osh get-values-overrides -p ${OVERRIDES_DIR} -c placement ${FEATURES})

git clone https://github.com/ader1990/openstack-helm -b flatcar_june_2025
pushd openstack-helm/nova/
helm dependency build
cd ../neutron/
helm dependency build
popd

helm upgrade --install nova openstack-helm/nova \
    --namespace=openstack \
    --set bootstrap.wait_for_computes.enabled=true \
    --set conf.ceph.enabled=true \
    $(helm osh get-values-overrides -p ${OVERRIDES_DIR} -c nova ${FEATURES})

PROVIDER_INTERFACE=eth1
tee ${OVERRIDES_DIR}/neutron/neutron_simple.yaml << EOF
conf:
  neutron:
    DEFAULT:
      l3_ha: False
      max_l3_agents_per_router: 1
  # <provider_interface_name> will be attached to the br-ex bridge.
  # The IP assigned to the interface will be moved to the bridge.
  auto_bridge_add:
    br-ex: ${PROVIDER_INTERFACE}
  plugins:
    ml2_conf:
      ml2_type_flat:
        flat_networks: public
    openvswitch_agent:
      ovs:
        bridge_mappings: public:br-ex
EOF

helm upgrade --install neutron openstack-helm/neutron \
    --namespace=openstack \
    $(helm osh get-values-overrides -p ${OVERRIDES_DIR} -c neutron neutron_simple ${FEATURES})

helm osh wait-for-pods openstack

rm -rf openstack-helm/

helm upgrade --install horizon openstack-helm/horizon \
    --namespace=openstack \
    $(helm osh get-values-overrides -p ${OVERRIDES_DIR} -c horizon ${FEATURES})

helm osh wait-for-pods openstack

KUBECONFIG=~/kub-poc.kubeconfig kubectl node-shell vm01 -- sh -c 'chmod 777 /dev/kvm'
KUBECONFIG=~/kub-poc.kubeconfig kubectl node-shell vm02 -- sh -c 'chmod 777 /dev/kvm'
KUBECONFIG=~/kub-poc.kubeconfig kubectl node-shell vm03 -- sh -c 'chmod 777 /dev/kvm'

rand_suffix=$(dd of=/tmp/rand if=/dev/random bs=1M count=1 && md5sum /tmp/rand | awk '{print $1}')

openstack --os-cloud openstack_helm net show private || openstack --os-cloud openstack_helm net create private
openstack --os-cloud openstack_helm subnet show private || openstack --os-cloud openstack_helm subnet create private --network private --subnet-range 10.5.0.0/24
openstack --os-cloud openstack_helm server create --image 'Cirros 0.6.2 64-bit' --flavor m1.tiny --network private cirros-$rand_suffix
sleep 10
until openstack --os-cloud openstack_helm console log show cirros-$rand_suffix | grep -i gocubsgo; do sleep 1 && echo 'Trying again'; done

