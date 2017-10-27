#!/bin/bash

set -e

IPERF=iperf
mkdir -p $IPERF
mkdir -p WN1

echo "Identifying worker nodes..."
worker_nodes=$(kubectl get nodes --no-headers | awk '{print $1}' | grep -v master)
node_count=$(kubectl get nodes --no-headers | awk '{print $1}' | grep -v master | wc -l)
echo "There are ${node_count} worker nodes."
worker_nodes_array=( $worker_nodes )
echo "${worker_nodes_array[0]}"
echo "${worker_nodes_array[1]}"
echo ""
# TODO: Udpdate iperf to be run as a deployment
kubectl run iperf --image=phlak/iperf
kubectl scale deployment iperf --replicas=${node_count}
sleep 15
echo ""
iperf_client=$(kubectl get pods --no-headers --all-namespaces -o wide | grep ${worker_nodes_array[0]} | grep iperf  | awk '{print $2}')
echo "iperf client: $iperf_client"
iperf_server_ip=$(kubectl get pods --no-headers --all-namespaces -o wide | grep ${worker_nodes_array[1]} | grep iperf | awk '{print $7}')
echo "iperf server ip: $iperf_server_ip"
echo ""
kubectl exec ${iperf_client} -- sh -c "iperf -c ${iperf_server_ip} -t 3600 -i 1" > $IPERF/iperf-logs &
cnode_wn1=$(kubectl get pods -n kube-system -l k8s-app=calico-node -o wide | grep ${worker_nodes_array[1]} | awk '{print $1}')
kubectl logs -f  -n kube-system ${cnode_wn1} calico-node > WN1/${cnode_wn1} &
sleep 5

function cnodes_avail() {
  kubectl get ds --no-headers -n kube-system calico-node | awk '{print $6}'
}

function cnode_cnt() {
  kubectl get pods -n kube-system -l k8s-app=calico-node -o wide | grep ${worker_node} | grep "Terminating" | wc -l
}

iter="30"
for worker_node in $worker_nodes; do
  mkdir -p ${worker_node}
  count="0"
  while [ "$count" -lt "$iter" ]; do
    all_fields=$(kubectl get pods -n kube-system -l k8s-app=calico-node -o wide | grep ${worker_node})
    echo "calico-node output on ${worker_node}: ${all_fields}"
    cnode=$(kubectl get pods -n kube-system -l k8s-app=calico-node -o wide | grep -v "Terminating"| grep ${worker_node} | awk '{print $1}')
    echo "deleting: ${cnode}"
    kubectl logs -f  -n kube-system ${cnode} calico-node > ${worker_node}/"pre-${cnode}" &
    cnodes_current=$(kubectl get ds --no-headers -n kube-system calico-node | awk '{print $3}')
    if [ "$cnodes_current" -eq "$(cnodes_avail)" ]; then
      echo "before deleting: "
      echo "$(cnode_cnt)"
      kubectl delete pod -n kube-system ${cnode}
      echo "after deleting: "
      echo "$(cnode_cnt)"
      while [ "$(cnode_cnt)" -ne "0" ]; do
        echo "Waiting for ${cnode} to finish Terminating..."
        sleep 3
      done
    fi
    echo "Completed iteration: ${count}"
    count=$[$count+1]
    echo ""
  done
done

echo "kubectl delete deployment iperf..."
kubectl delete deployment iperf
echo ""
if [ $(tail -n +7 ${IPERF}/iperf-logs | cut -f 2- -d 'c' | grep -c "0\.") -ne "0" ]; then
  echo "Connectivity Error: Break in connectivity while restarting calico-node found in ${IPERF}/iperf-logs"
  exit 1
else
  echo "PASSED: Connectivity maintained during ${iter} client/server calico-node restarts."
fi
echo "Finished"
