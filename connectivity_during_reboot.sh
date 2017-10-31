#!/bin/bash

set -e

TEST_LOGS=testlogs
IPERF=iperf
mkdir -p $TEST_LOGS
mkdir -p $TEST_LOGS/$IPERF

echo "Identifying worker nodes..."
worker_nodes=$(kubectl get nodes --no-headers | awk '{print $1}' | grep -v master)
node_count=$(kubectl get nodes --no-headers | awk '{print $1}' | grep -v master | wc -l)
echo "There are ${node_count} worker nodes."
worker_nodes_array=( $worker_nodes )
echo "${worker_nodes_array[0]}"
echo "${worker_nodes_array[1]}"
echo ""
mkdir -p ${TEST_LOGS}/${worker_nodes_array[1]}
echo ""
kubectl run iperf --image=phlak/iperf
kubectl scale deployment iperf --replicas=${node_count}
sleep 15
echo ""
iperf_client=$(kubectl get pods --no-headers --all-namespaces -o wide | grep ${worker_nodes_array[0]} | grep iperf  | awk '{print $2}')
echo "iperf client: ${iperf_client} on ${worker_nodes_array[0]}"
iperf_server_ip=$(kubectl get pods --no-headers --all-namespaces -o wide | grep ${worker_nodes_array[1]} | grep iperf | awk '{print $7}')
echo "iperf server ip: ${iperf_server_ip} on ${worker_nodes_array[1]}"
echo ""
kubectl exec ${iperf_client} -- sh -c "iperf -c ${iperf_server_ip} -t 3600 -i 1" > ${TEST_LOGS}/${IPERF}/iperf-logs &
cnode_wn1=$(kubectl get pods -n kube-system -l k8s-app=calico-node -o wide | grep "${worker_nodes_array[1]}" | awk '{print $1}')
kubectl logs -f  -n kube-system ${cnode_wn1} calico-node > ${TEST_LOGS}/${worker_nodes_array[1]}/"test-start-server-side-${cnode_wn1}" &
sleep 5

function cnodes_avail() {
  kubectl get ds --no-headers -n kube-system calico-node | awk '{print $6}'
}

function cnode_term() {
  kubectl get pods -n kube-system -l k8s-app=calico-node -o wide | grep ${worker_node} | grep "Terminating" | wc -l
}

iter="3"
for worker_node in $worker_nodes; do
  mkdir -p $TEST_LOGS/${worker_node}
  count="0"
  while [ "$count" -lt "$iter" ]; do
    all_fields=$(kubectl get pods -n kube-system -l k8s-app=calico-node -o wide | grep ${worker_node})
    echo "calico-node output on ${worker_node}: ${all_fields}"
    cnode=$(kubectl get pods -n kube-system -l k8s-app=calico-node -o wide | grep -v "Terminating"| grep ${worker_node} | awk '{print $1}')
    echo "deleting: ${cnode}"
    kubectl logs -f  -n kube-system ${cnode} calico-node > $TEST_LOGS/${worker_node}/"${cnode}-${count}" &
    cnodes_current=$(kubectl get ds --no-headers -n kube-system calico-node | awk '{print $3}')
    if [ "$cnodes_current" -eq "$(cnodes_avail)" ]; then
      echo "before deleting: "
      echo "$(cnode_term)"
      kubectl delete pod -n kube-system ${cnode}
      while [ "$(cnode_term)" -ne "0" ]; do
        echo "$(kubectl get ds -n kube-system calico-node)"
        echo "Waiting for ${cnode} to finish Terminating..."
        sleep 3
      done
      while [ "$cnodes_current" -ne "$(cnodes_avail)" ]; do
        echo "$(kubectl get ds -n kube-system calico-node)"
        echo "Waiting for current state to become available..."
        sleep 1
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
if [ $(tail -n +7 ${TEST_LOGS}/${IPERF}/iperf-logs | cut -f 2- -d 'c' | grep -c "0\.") -ne "0" ]; then
  tar -cvzf - ${TEST_LOGS} > ${TEST_LOGS}.tgz
  echo "Connectivity Error: Break in connectivity while restarting calico-node found in ${IPERF}/iperf-logs"
  exit 1
else
  echo "PASSED: Connectivity maintained during ${iter} client/server calico-node restarts."
fi
echo "Finished"
