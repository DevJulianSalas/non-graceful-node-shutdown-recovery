#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE_ROLE="${1:-control-plane}"
NODE_NAME="${2:-}"

if [[ "$NODE_ROLE" != "delete" && -z "$NODE_NAME" ]]; then
  NODE_NAME="${NODE_ROLE}-1"
fi

case "$NODE_ROLE" in
  control-plane)
    echo "Creating Kubernetes control-plane node: $NODE_NAME"
    multipass launch \
      --name "$NODE_NAME" \
      --cloud-init "$SCRIPT_DIR/cloud-init.yaml" \
      --cpus 2 \
      --memory 2G \
      --disk 10G

    multipass mount "$SCRIPT_DIR/scripts" "$NODE_NAME:/home/ubuntu/kubernetes/scripts"
    multipass mount "$SCRIPT_DIR/code" "$NODE_NAME:/home/ubuntu/kubernetes/code"
    multipass exec "$NODE_NAME" -- bash /home/ubuntu/kubernetes/scripts/cluster-init.sh
    multipass exec "$NODE_NAME" -- kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.12.1/deploy/longhorn.yaml
    multipass exec "$NODE_NAME" -- kubectl apply -f /home/ubuntu/kubernetes/code/manifests/storage-class.yaml
    multipass exec "$NODE_NAME" -- kubectl apply -f /home/ubuntu/kubernetes/code/manifests/redis-server.yaml
    multipass exec "$NODE_NAME" -- kubectl apply -f /home/ubuntu/kubernetes/code/manifests/producer-consumer.yaml
    ;;

  worker)
    echo "Creating Kubernetes worker node: $NODE_NAME"
    multipass launch \
      --name "$NODE_NAME" \
      --cloud-init "$SCRIPT_DIR/cloud-init.yaml" \
      --cpus 2 \
      --memory 2G \
      --disk 30G

    multipass mount "$SCRIPT_DIR/scripts" "$NODE_NAME:/home/ubuntu/kubernetes/scripts"
    multipass exec "$NODE_NAME" -- bash /home/ubuntu/kubernetes/scripts/cluster-join.sh
    ;;
  
  delete)
    if [[ -z "${NODE_NAME:-}" ]]; then
      echo "Deleting all Multipass instances and purging VM state..."
      multipass delete --all
      multipass purge
    else
      echo "Deleting Multipass instance: $NODE_NAME"
      multipass delete "$NODE_NAME"
      multipass purge
    fi
    echo "Cleanup completed."
    exit 0
    ;;
  

  *)
    echo "Usage: $0 [control-plane|worker|delete|taint-stateful] [vm-name]"
    echo "Examples:"
    echo "  $0 control-plane control-plane"
    echo "  $0 worker worker-1"
    echo "  $0 delete"
    echo "  $0 delete control-plane"
    exit 1
    ;;
esac

echo "Node setup completed for $NODE_NAME ($NODE_ROLE)."