#!/bin/sh

set -x

if [ -z "$EUID" ]; then
    EUID=`id -u`
fi

# Grab our libs
. "`dirname $0`/setup-lib.sh"

if [ -f $OURDIR/deathstarbench-done ]; then
    exit 0
fi

logtstart "deathstarbench"

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi
if [ -f $LOCALSETTINGS ]; then
    . $LOCALSETTINGS
fi

# Deploy NFS Provisioner if NFS is enabled
if [ -n "$DONFS" -a $DONFS -eq 1 ]; then
    helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
    helm upgrade --install nfs-subdir-external-provisioner \
        --set nfs.server=$SINGLENODE_MGMT_IP \
        --set nfs.path=$NFSEXPORTDIR \
        --set storageClass.defaultClass=true \
        nfs-subdir-external-provisioner/nfs-subdir-external-provisioner
fi

# Clone DeathStarBench repo
git clone https://github.com/delimitrou/DeathStarBench

# Deploy DeathStarBench social network with clustered memcached and redis but not mongodb (for now)
helm upgrade --install socialnetwork \
    --set global.replicas=3 \
    --set global.nginx.resolverName=coredns.kube-system.svc.cluster.local \
    --set global.memcached.cluster.enabled=false \
    --set global.memcached.standalone.enabled=true \
    --set global.redis.cluster.enabled=false \
    --set global.redis.standalone.enabled=true \
    ./DeathStarBench/socialNetwork/helm-chart/socialnetwork

# Deploy Grafana
helm repo add grafana https://grafana.github.io/helm-charts
helm upgrade --install grafana grafana/grafana \
    --set persistence.enabled=true \
    --set persistence.size=10Gi \
    --set datasources."datasources\.yaml".apiVersion=1 \
    --set datasources."datasources\.yaml".datasources[0].name=Jaeger \
    --set datasources."datasources\.yaml".datasources[0].type=jaeger \
    --set datasources."datasources\.yaml".datasources[0].url=http://jaeger:16686 \
    --set datasources."datasources\.yaml".datasources[0].access=proxy \
    --set datasources."datasources\.yaml".datasources[0].isDefault=true \
    --set service.type=LoadBalancer \
    --set service.annotations."metallb\.universe\.tf/allow-shared-ip"=dsb \

# Patch DeathstarBench social network to allow shared public ip with grafana
kubectl patch svc nginx-thrift -p '{"metadata": {"annotations": {"metallb.universe.tf/allow-shared-ip": "dsb"}}, "spec": { "type": "LoadBalancer"} }'

# Initalize Social Graph
pip3 install typing-extensions \
    attrs \
    yarl \
    async-timeout \
    multidict \
    charset-normalizer \
    idna_ssl \
    aiosignal \
    aiohttp \

# TODO: Wait for socialnetwork to be ready

cd DeathStarBench/socialNetwork
python3 scripts/init_social_graph.py --ip $(kubectl get svc nginx-thrift -o json | yq r - 'spec.clusterIP')
cd ../..
