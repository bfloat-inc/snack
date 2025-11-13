#!/bin/bash
# Snackager GCP Deployment Script
# This script automates the deployment of snackager to Google Cloud Platform

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration - UPDATE THESE VALUES
GCP_PROJECT_ID="${GCP_PROJECT_ID:-}"
GCP_REGION="${GCP_REGION:-us-central1}"
CLUSTER_NAME="${CLUSTER_NAME:-snackager-cluster}"
REDIS_INSTANCE_NAME="${REDIS_INSTANCE_NAME:-snackager-redis}"
ARTIFACT_REGISTRY_REPO="${ARTIFACT_REGISTRY_REPO:-snackager}"

# S3 Configuration (if using AWS S3)
S3_BUCKET="${S3_BUCKET:-}"
IMPORTS_S3_BUCKET="${IMPORTS_S3_BUCKET:-}"
S3_REGION="${S3_REGION:-us-west-1}"
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"

# Snackager Configuration
SNACKAGER_URL="${SNACKAGER_URL:-}"
API_SERVER_URL="${API_SERVER_URL:-https://exp.host}"

function info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

function warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

function error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

function check_prerequisites() {
    info "Checking prerequisites..."
    
    # Check if gcloud is installed
    if ! command -v gcloud &> /dev/null; then
        error "gcloud CLI is not installed. Please install it from https://cloud.google.com/sdk/docs/install"
    fi
    
    # Check if kubectl is installed
    if ! command -v kubectl &> /dev/null; then
        error "kubectl is not installed. Install it with: gcloud components install kubectl"
    fi
    
    # Check if docker is installed
    if ! command -v docker &> /dev/null; then
        error "docker is not installed. Please install Docker Desktop or Docker Engine"
    fi
    
    # Check if helm is installed
    if ! command -v helm &> /dev/null; then
        warn "helm is not installed. It's needed for External Secrets Operator. Install from: https://helm.sh/docs/intro/install/"
    fi
    
    info "All prerequisites are installed"
}

function validate_config() {
    info "Validating configuration..."
    
    if [ -z "$GCP_PROJECT_ID" ]; then
        error "GCP_PROJECT_ID is not set. Set it with: export GCP_PROJECT_ID=your-project-id"
    fi
    
    if [ -z "$SNACKAGER_URL" ]; then
        error "SNACKAGER_URL is not set. Set it with: export SNACKAGER_URL=https://your-domain.com"
    fi
    
    if [ -z "$S3_BUCKET" ] || [ -z "$IMPORTS_S3_BUCKET" ]; then
        error "S3 buckets not configured. Set S3_BUCKET and IMPORTS_S3_BUCKET environment variables"
    fi
    
    if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
        error "AWS credentials not configured. Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"
    fi
    
    info "Configuration is valid"
}

function setup_gcp_project() {
    info "Setting up GCP project: $GCP_PROJECT_ID"
    
    gcloud config set project "$GCP_PROJECT_ID"
    
    info "Enabling required APIs..."
    gcloud services enable container.googleapis.com \
        artifactregistry.googleapis.com \
        secretmanager.googleapis.com \
        redis.googleapis.com \
        compute.googleapis.com
    
    info "GCP project setup complete"
}

function create_gke_cluster() {
    info "Checking if GKE cluster exists..."
    
    if gcloud container clusters describe "$CLUSTER_NAME" --region="$GCP_REGION" &> /dev/null; then
        warn "Cluster $CLUSTER_NAME already exists, skipping creation"
    else
        info "Creating GKE cluster: $CLUSTER_NAME"
        gcloud container clusters create "$CLUSTER_NAME" \
            --region "$GCP_REGION" \
            --num-nodes 2 \
            --machine-type n1-standard-4 \
            --enable-autoscaling \
            --min-nodes 1 \
            --max-nodes 5 \
            --enable-vertical-pod-autoscaling \
            --disk-size 50 \
            --disk-type pd-standard
        
        info "GKE cluster created successfully"
    fi
    
    info "Getting cluster credentials..."
    gcloud container clusters get-credentials "$CLUSTER_NAME" --region "$GCP_REGION"
}

function create_artifact_registry() {
    info "Checking if Artifact Registry repository exists..."
    
    if gcloud artifacts repositories describe "$ARTIFACT_REGISTRY_REPO" --location="$GCP_REGION" &> /dev/null; then
        warn "Artifact Registry repository already exists, skipping creation"
    else
        info "Creating Artifact Registry repository..."
        gcloud artifacts repositories create "$ARTIFACT_REGISTRY_REPO" \
            --repository-format=docker \
            --location="$GCP_REGION" \
            --description="Snackager Docker images"
        
        info "Artifact Registry created successfully"
    fi
    
    info "Configuring Docker authentication..."
    gcloud auth configure-docker "${GCP_REGION}-docker.pkg.dev"
}

function create_redis_instance() {
    info "Checking if Redis instance exists..."
    
    if gcloud redis instances describe "$REDIS_INSTANCE_NAME" --region="$GCP_REGION" &> /dev/null; then
        warn "Redis instance already exists, skipping creation"
    else
        info "Creating Cloud Memorystore (Redis) instance... This may take several minutes"
        gcloud redis instances create "$REDIS_INSTANCE_NAME" \
            --size=5 \
            --region="$GCP_REGION" \
            --redis-version=redis_7_0 \
            --network=default
        
        info "Redis instance created successfully"
    fi
    
    REDIS_HOST=$(gcloud redis instances describe "$REDIS_INSTANCE_NAME" \
        --region="$GCP_REGION" --format="value(host)")
    REDIS_PORT=$(gcloud redis instances describe "$REDIS_INSTANCE_NAME" \
        --region="$GCP_REGION" --format="value(port)")
    
    export REDIS_URL="redis://${REDIS_HOST}:${REDIS_PORT}"
    info "Redis URL: $REDIS_URL"
}

function create_secrets() {
    info "Creating secrets in Google Secret Manager..."
    
    # Create secrets JSON
    cat > /tmp/snackager-secrets.json <<EOF
{
  "REDIS_URL": "${REDIS_URL}",
  "AWS_ACCESS_KEY_ID": "${AWS_ACCESS_KEY_ID}",
  "AWS_SECRET_ACCESS_KEY": "${AWS_SECRET_ACCESS_KEY}",
  "GIT_SESSION_SECRET": "$(openssl rand -hex 32)"
}
EOF
    
    SECRET_NAME="production__snack__snackager__env"
    
    # Check if secret exists
    if gcloud secrets describe "$SECRET_NAME" &> /dev/null; then
        info "Secret already exists, creating new version..."
        gcloud secrets versions add "$SECRET_NAME" --data-file=/tmp/snackager-secrets.json
    else
        info "Creating new secret..."
        gcloud secrets create "$SECRET_NAME" --data-file=/tmp/snackager-secrets.json
    fi
    
    # Clean up
    rm /tmp/snackager-secrets.json
    
    info "Secrets created successfully"
}

function install_external_secrets() {
    info "Installing External Secrets Operator..."
    
    # Check if already installed
    if kubectl get namespace external-secrets-system &> /dev/null; then
        warn "External Secrets Operator namespace exists, skipping installation"
    else
        helm repo add external-secrets https://charts.external-secrets.io
        helm repo update
        
        helm install external-secrets \
            external-secrets/external-secrets \
            -n external-secrets-system \
            --create-namespace \
            --set installCRDs=true
        
        info "Waiting for External Secrets Operator to be ready..."
        kubectl wait --for=condition=ready pod \
            -l app.kubernetes.io/name=external-secrets \
            -n external-secrets-system \
            --timeout=300s
    fi
    
    info "Creating ClusterSecretStore..."
    kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: gcp-store
spec:
  provider:
    gcpsm:
      projectID: "$GCP_PROJECT_ID"
      auth:
        workloadIdentity:
          clusterLocation: $GCP_REGION
          clusterName: $CLUSTER_NAME
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets-system
EOF
    
    info "External Secrets Operator configured"
}

function build_and_push_image() {
    info "Building Docker image..."
    
    IMAGE_TAG="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/${ARTIFACT_REGISTRY_REPO}/snackager:latest"
    
    cd "$(dirname "$0")/.."
    
    docker build -f snackager/Dockerfile \
        --build-arg node_version=20.19.4 \
        --build-arg APP_VERSION="v$(date +%Y%m%d-%H%M%S)" \
        -t "$IMAGE_TAG" .
    
    info "Pushing Docker image to Artifact Registry..."
    docker push "$IMAGE_TAG"
    
    export IMAGE_TAG
    info "Image pushed: $IMAGE_TAG"
}

function create_k8s_config() {
    info "Creating Kubernetes configuration..."
    
    mkdir -p snackager/k8s/gcp-custom
    
    # Create kustomization.yaml
    cat > snackager/k8s/gcp-custom/kustomization.yaml <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: default
resources:
- ../base
- external-secret-env.yaml
configMapGenerator:
- name: snackager-config
  behavior: merge
  envs:
  - snackager.env
images:
- name: us-central1-docker.pkg.dev/exponentjs/snack/snackager
  newName: ${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/${ARTIFACT_REGISTRY_REPO}/snackager
  newTag: latest
EOF
    
    # Create snackager.env
    cat > snackager/k8s/gcp-custom/snackager.env <<EOF
IMPORT_SERVER_URL=${SNACKAGER_URL}
API_SERVER_URL=${API_SERVER_URL}
S3_BUCKET=${S3_BUCKET}
IMPORTS_S3_BUCKET=${IMPORTS_S3_BUCKET}
S3_REGION=${S3_REGION}
CLOUDFRONT_URL=${SNACKAGER_URL}
EOF
    
    # Create external secret configuration
    cat > snackager/k8s/gcp-custom/external-secret-env.yaml <<EOF
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: snackager-config
spec:
  refreshInterval: "0"
  secretStoreRef:
    kind: ClusterSecretStore
    name: gcp-store
  target:
    name: snackager-config
    creationPolicy: Owner
  dataFrom:
  - extract:
      key: production__snack__snackager__env
      version: "latest"
EOF
    
    info "Kubernetes configuration created"
}

function deploy_to_kubernetes() {
    info "Deploying snackager to Kubernetes..."
    
    kubectl apply -k snackager/k8s/gcp-custom/
    
    info "Waiting for deployment to be ready..."
    kubectl wait --for=condition=available deployment/snackager --timeout=600s
    
    info "Deployment complete!"
}

function setup_ingress() {
    info "Setting up Ingress..."
    
    # Reserve a static IP
    if gcloud compute addresses describe snackager-ip --global &> /dev/null; then
        warn "Static IP already exists"
    else
        gcloud compute addresses create snackager-ip --global
    fi
    
    STATIC_IP=$(gcloud compute addresses describe snackager-ip --global --format="value(address)")
    info "Static IP: $STATIC_IP"
    
    # Create Ingress
    kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: snackager-ingress
  annotations:
    kubernetes.io/ingress.class: "gce"
    kubernetes.io/ingress.global-static-ip-name: "snackager-ip"
spec:
  defaultBackend:
    service:
      name: snackager
      port:
        number: 80
EOF
    
    info "Ingress created with IP: $STATIC_IP"
    info "Configure your DNS to point to this IP address"
}

function verify_deployment() {
    info "Verifying deployment..."
    
    info "Pods:"
    kubectl get pods -l app=snackager
    
    info "Services:"
    kubectl get svc snackager
    
    info "Testing health endpoint..."
    kubectl port-forward svc/snackager 8080:80 &
    PF_PID=$!
    sleep 5
    
    if curl -f http://localhost:8080/status; then
        info "✓ Health check passed!"
    else
        warn "Health check failed"
    fi
    
    kill $PF_PID 2>/dev/null || true
    
    info "Deployment verification complete"
}

function main() {
    info "Starting Snackager GCP Deployment"
    echo "=================================="
    
    check_prerequisites
    validate_config
    setup_gcp_project
    create_gke_cluster
    create_artifact_registry
    create_redis_instance
    create_secrets
    install_external_secrets
    build_and_push_image
    create_k8s_config
    deploy_to_kubernetes
    setup_ingress
    verify_deployment
    
    echo ""
    info "================================================"
    info "✓ Snackager deployment completed successfully!"
    info "================================================"
    echo ""
    info "Next steps:"
    echo "  1. Point your DNS to the static IP shown above"
    echo "  2. Test your deployment: curl ${SNACKAGER_URL}/status"
    echo "  3. Bundle a package: curl '${SNACKAGER_URL}/bundle/lodash@latest?platforms=ios,android'"
    echo ""
}

# Run main function
main

