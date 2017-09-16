import logging
import os
import threading
import time

from kubernetes import client
from kubernetes import config
from kubernetes.client import configuration
from kubernetes.client.rest import ApiException

# run on master: sudo kubectl --kubeconfig /etc/kubernetes/admin.conf proxy &

_log = logging.getLogger(__name__)
_log.setLevel(logging.DEBUG)


def main():
    logging.info('Starting logger for connectivity during reboot...')
    config.load_kube_config()
    v1 = client.CoreV1Api()
    v1.list_node()

    node_count = len(v1.list_node().items)
    _log.debug("Node count is: %s " % node_count)

    worker_nodes = []
    for n in range(0, node_count):
        if 'master' not in v1.list_node().items[n].metadata.name:
            worker_nodes.append(v1.list_node().items[n].metadata.name)

    _log.debug("Non-master nodes are: %s " % worker_nodes)
    _log.debug("")

    assert len(worker_nodes) >= 2, "Less than two non-master nodes in this cluster"

    body = client.V1Namespace()
    body.metadata = client.V1ObjectMeta(name="iperf", labels={'key1': 'iperf'})
    v1.create_namespace(body)
    # TODO: continue once namespace is created without using sleep
    time.sleep(5)

    configuration.assert_hostname = False
    name = 'iperf-deployment'
    replicas = len(worker_nodes)
    api = client.AppsV1beta1Api()
    resp = None
    try:
        resp = api.read_namespaced_deployment(name=name,
                                              namespace='iperf')
    except ApiException as e:
        if e.status != 404:
            _log.debug("Unknown error: %s" % e)
            exit(1)

    if not resp:
        _log.debug("Deployment: %s does not exits. Creating it..." % name)
        deployment_manifest = {
            "apiVersion": "apps/v1beta1",
            "kind": "Deployment",
            "metadata": {
                "name": "iperf-deployment",
                "namespace": "iperf",
                "labels": {
                    "app": "iperf"
                }
            },
            "spec": {
                "replicas": replicas,
                "template": {
                    "metadata": {
                        "labels": {
                            "app": "iperf"
                        }
                    },
                    "spec": {
                        "containers": [
                            {
                                "name": "iperf",
                                "image": "phlak/iperf"
                            }
                        ]
                    }
                }
            }
        }
        resp = api.create_namespaced_deployment(body=deployment_manifest,
                                                namespace='iperf')
        while True:
            resp = api.read_namespaced_deployment(name=name,
                                                  namespace='iperf')
            if resp.status.available_replicas == replicas:
                break
            time.sleep(1)
        _log.debug("%s created..." % name)
        _log.debug("")

    _log.debug("Selecting iperf server and client...")
    while True:
        resp = api.read_namespaced_deployment(name=name,
                                              namespace='iperf')
        if resp.status.available_replicas == replicas:
            iperf_client = [ns.metadata.name for ns in v1.list_namespaced_pod(namespace="iperf").items if (
                (worker_nodes[0] in ns.spec.node_name) and ('Terminating' not in ns.status.phase) and (
                    ns.status.container_statuses))]
            assert len(iperf_client) == 1, "Needs one element list."
            _log.debug("iperf_client: %s on node %s: " % (iperf_client[0], worker_nodes[0]))

            iperf_server_ip = [ns.status.pod_ip for ns in v1.list_namespaced_pod(namespace="iperf").items if (
                (worker_nodes[1] in ns.spec.node_name) and ('Terminating' not in ns.status.phase) and (
                    ns.status.container_statuses))]
            assert len(iperf_server_ip) == 1, "Needs one element list."
            _log.debug("iperf_server_ip: %s on node %s: " % (iperf_server_ip[0], worker_nodes[1]))
            _log.debug("")
            break
        time.sleep(1)

    def worker():
        """thread worker function"""
        f = open('iperf-logs', 'w')
        exec_command = [
            '/bin/sh',
            '-c',
            'iperf -c {ici} -t 180 -i 1'.format(ici=iperf_server_ip[0])]
        exec_resp = v1.connect_get_namespaced_pod_exec(iperf_client[0], 'iperf',
                                                       command=exec_command,
                                                       stderr=True, stdin=False,
                                                       stdout=True, tty=False)
        _log.debug("Response from exec_resp:\n%s" % exec_resp)
        f.write(exec_resp)
        f.close()
        return

    threads = []

    t = threading.Thread(target=worker)
    threads.append(t)
    t.start()

    def cnodes_avail(out, inner):
        time.sleep(5)
        cnode_containers = [ns.status.container_statuses[inner].ready for ns in
                            v1.list_namespaced_pod(label_selector="k8s-app=calico-node",
                                                   namespace="kube-system").items if (
                                (worker_nodes[out] in ns.spec.node_name) and (
                                    ns.metadata.deletion_timestamp is None))]
        _log.debug("calico-node container ready status is reporting %s: " % cnode_containers[0])
        return cnode_containers[0]

    cnode_body = client.V1DeleteOptions(grace_period_seconds=0)
    itr = 3
    t0 = time.time()
    for n in range(0, len(worker_nodes)):
        count = 0
        while count < itr:
            next2delete = [ns.metadata.name for ns in
                           v1.list_namespaced_pod(label_selector="k8s-app=calico-node", namespace="kube-system").items
                           if (
                               (worker_nodes[n] in ns.spec.node_name))]
            assert len(next2delete) == 1, "Needs one element list."
            _log.debug("Start iteration: %s on node: %s" % (count, worker_nodes[n]))
            _log.debug("calico-node next 2 be deleted: %s on node %s" % (next2delete[0], worker_nodes[n]))
            v1.delete_namespaced_pod(next2delete[0], 'kube-system', cnode_body)
            for cs in range(0, 2):
                while (cnodes_avail(n, cs) is not True):
                    _log.debug("Waiting for %s to finish Terminating... " % next2delete[0])
                break
            time.sleep(1)
            _log.debug("Completed iteration: %s on node: %s" % (count, worker_nodes[n]))
            _log.debug("")
            count += 1
    t1 = time.time()
    cnode_total_time = t1 - t0
    _log.debug("Total time spent on calico-node deletion workflow: %s" % cnode_total_time)
    t.join()

    with open('iperf-logs', 'r') as f:
        gresponse = os.system("tail -n +7 iperf_output | cut -f 2- -d 'c' | grep -c '0\.'")
        assert gresponse != 0, "Connectivity Error: Break in connectivity while restarting calico-node found in iperf-logs"

    _log.debug("PASSED: Connectivity maintained during %s client/server calico-node restarts." % itr)
    _log.debug("Finished")

    v1.delete_namespace(name="iperf", body=client.V1DeleteOptions())


if __name__ == '__main__':
    main()
