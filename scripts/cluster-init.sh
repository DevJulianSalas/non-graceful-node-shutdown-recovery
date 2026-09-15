########################################
# Kubernetes Initialization
########################################
echo "Starting Kubeadm init..."
sudo kubeadm init --config=/etc/kubernetes/kubeadm-config.yaml
echo "Kubeadm init completed"

########################################
# Configure kubectl
########################################
echo "Configuring kubectl for ubuntu user..."
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
echo "Finished Kubectl configuration..."


########################################
# Install Flannel
########################################
echo "Starting Flannel configuration..."
# Add a retry loop in case GitHub or internet access experiences transient errors during boot
for i in {1..5}; do
    if kubectl apply -f https://github.com/flannel-io/flannel/releases/download/v0.28.6/kube-flannel.yml; then
        echo "Finished Flannel configuration..."
        break
    fi
    echo "Flannel apply failed, retrying in 5 seconds... ($i/5)"
    sleep 5
done
echo "Finished Flannel configuration..."