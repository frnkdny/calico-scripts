#!/bin/bash

set -e

IPERF=iperf
mkdir -p $IPERF

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
sleep 5
iperf_server=$(kubectl get pods --no-headers --all-namespaces -o wide | grep ${worker_nodes_array[0]} | grep iperf  | awk '{print $2}')
echo "iperf server: $iperf_server"
iperf_client_ip=$(kubectl get pods --no-headers --all-namespaces -o wide | grep ${worker_nodes_array[1]} | grep iperf | awk '{print $7}')
echo "iperf client ip: $iperf_client_ip"
echo ""
kubectl exec ${iperf_server} -- sh -c "iperf -c ${iperf_client_ip} -t 360 -i 1" > $IPERF/iperf-logs &
sleep 5

function cnodes_avail() {
  kubectl get ds --no-headers -n kube-system calico-node | awk '{print $6}'
}

iter="3"
for worker_node in $worker_nodes; do
  count="0"
  while [ "$count" -lt "$iter" ]; do
    all_fields=$(kubectl get pods -n kube-system -l k8s-app=calico-node -o wide | grep ${worker_node})
    echo "calico-node output on ${worker_node}: ${all_fields}"
    cnode=$(kubectl get pods -n kube-system -l k8s-app=calico-node -o wide | grep -v "Terminating"| grep ${worker_node} | awk '{print $1}')
    echo "deleting: ${cnode}"
    cnodes_current=$(kubectl get ds --no-headers -n kube-system calico-node | awk '{print $3}')
    if [ "$cnodes_current" -eq "$(cnodes_avail)" ]; then
      kubectl delete pod -n kube-system ${cnode}
      while [ "$cnodes_current" -ne "$(cnodes_avail)" ]; do
        echo "Waiting for ${cnode} to finish Terminating..."
        sleep 3
      done
    fi
    echo "count is ${count}"
    count=$[$count+1]
    echo "incremeted count is ${count}"
  done
done

echo "kubectl delete deployment iperf..."
kubectl delete deployment iperf
echo ""
if [ $(tail -n +7 iperf-logs | cut -f 2- -d 'c' | grep -c "0\.") -ne "0" ]; then
  echo "Connectivity Error: Break in connectivity while restarting calico-node found in $IPERF/iperf-logs"
  exit 1
else
  echo "PASSED: Connectivity maintained during multiple calico-node restarts."
fi
echo "Finished"
