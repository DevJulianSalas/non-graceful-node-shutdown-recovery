########################################
# Kubernetes join
########################################
echo "Starting kubeadm join cluster configuration..."
sudo kubeadm join 192.168.252.63:6443 --token o93c6l.1jfdazq4s47ajn0u \
	--discovery-token-ca-cert-hash sha256:3e89ffbf798b8f605e2068ff15ac2ce60a648e85ed331e5b52f5d792ffaeac4d 
echo "Successfully joined the Kubernetes cluster."
