#!/bin/bash

# ========= CONFIG =========
# Camera configurations: "RTSP_URL|FRAME_INTERVAL|MAX_FRAMES"
CAMERAS=(
    "rtsp://10.65.21.153:8554/wireless|1|30"
    # Add more cameras here: "rtsp://another-camera|1|30"
)

# Kubernetes settings
NAMESPACE="camera-system"
IMAGE_NAME="docker.io/library/camera-cpp-ingest:latest"

# Local storage paths on each node
NODE1_STORAGE_PATH="/mnt/camera_frames"
NODE2_STORAGE_PATH="/mnt/camera_frames"

# Node names for High Availability
PREFERRED_NODE="node1"
BACKUP_NODE="node2"

# Directory for manifests
MANIFEST_DIR="./k8s_manifests"
mkdir -p "$MANIFEST_DIR"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'
# ==========================

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Camera System - Auto-Failover Watchdog${NC}"
echo -e "${BLUE}Primary Node: $PREFERRED_NODE${NC}"
echo -e "${BLUE}Backup Node:  $BACKUP_NODE${NC}"
echo -e "${BLUE}Storage Mode: Local (per-node)${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check kubectl
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}✗ kubectl not found!${NC}"
    exit 1
fi

# Check cluster
echo -e "${YELLOW}Checking Kubernetes cluster...${NC}"
if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}✗ Cannot connect to cluster!${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Cluster connected${NC}"
echo ""

# Show nodes
echo -e "${YELLOW}Available nodes:${NC}"
kubectl get nodes -o wide
echo ""

# Check nodes exist
if ! kubectl get node $PREFERRED_NODE &>/dev/null; then
    echo -e "${RED}✗ Node '$PREFERRED_NODE' not found!${NC}"
    exit 1
fi
if ! kubectl get node $BACKUP_NODE &>/dev/null; then
    echo -e "${RED}✗ Node '$BACKUP_NODE' not found!${NC}"
    exit 1
fi

# Cleanup function
cleanup() {
    echo ""
    echo -e "${YELLOW}Stopping all cameras...${NC}"
    kubectl delete deployment -n $NAMESPACE -l app=camera-ingest --ignore-not-found=true
    kubectl delete daemonset -n $NAMESPACE camera-watchdog --ignore-not-found=true
    echo -e "${GREEN}✓ All cameras stopped${NC}"
    exit 0
}

trap cleanup SIGINT SIGTERM

# Create namespace
echo -e "${YELLOW}Creating namespace '$NAMESPACE'...${NC}"
kubectl create namespace $NAMESPACE 2>/dev/null && \
    echo -e "${GREEN}✓ Namespace created${NC}" || \
    echo -e "${GREEN}✓ Namespace exists${NC}"
echo ""

# Setup local storage on nodes
echo -e "${YELLOW}Setting up local storage on nodes...${NC}"
echo -e "${BLUE}Creating storage directories:${NC}"
echo -e "  Node1: $NODE1_STORAGE_PATH"
echo -e "  Node2: $NODE2_STORAGE_PATH"
echo ""

# Create storage directories on both nodes
for node in $PREFERRED_NODE $BACKUP_NODE; do
    echo -e "${YELLOW}Configuring storage on $node...${NC}"
    
    kubectl run storage-setup-$node --image=busybox --restart=Never -n $NAMESPACE \
        --overrides="{
          \"spec\": {
            \"nodeName\": \"$node\",
            \"hostNetwork\": true,
            \"containers\": [{
              \"name\": \"setup\",
              \"image\": \"busybox\",
              \"command\": [\"sh\", \"-c\", \"mkdir -p /host/mnt/camera_frames && chmod 777 /host/mnt/camera_frames && echo 'Storage ready on $node'\"],
              \"volumeMounts\": [{
                \"name\": \"host\",
                \"mountPath\": \"/host\"
              }]
            }],
            \"volumes\": [{
              \"name\": \"host\",
              \"hostPath\": {
                \"path\": \"/\",
                \"type\": \"Directory\"
              }
            }],
            \"restartPolicy\": \"Never\"
          }
        }" --wait=true 2>/dev/null
    
    kubectl wait --for=condition=completed pod/storage-setup-$node -n $NAMESPACE --timeout=30s 2>/dev/null
    kubectl logs storage-setup-$node -n $NAMESPACE 2>/dev/null
    kubectl delete pod storage-setup-$node -n $NAMESPACE --ignore-not-found=true 2>/dev/null
    
    echo -e "${GREEN}✓ Storage configured on $node${NC}"
done
echo ""

# Deploy IMPROVED watchdog with better detection
echo -e "${YELLOW}Deploying intelligent ring buffer watchdog...${NC}"

cat > "$MANIFEST_DIR/watchdog.yaml" <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: camera-watchdog
  namespace: $NAMESPACE
spec:
  selector:
    matchLabels:
      app: camera-watchdog
  template:
    metadata:
      labels:
        app: camera-watchdog
    spec:
      hostNetwork: true
      serviceAccountName: camera-watchdog-sa
      containers:
      - name: watchdog
        image: alpine/k8s:1.28.0
        command:
        - sh
        - -c
        - |
          apk add --no-cache findutils coreutils
          
          echo "========================================="
          echo "🐕 Intelligent Watchdog Starting"
          echo "Node: \$(hostname)"
          echo "Storage: $NODE1_STORAGE_PATH"
          echo "Namespace: $NAMESPACE"
          echo "========================================="
          
          # Max frames per camera
          get_max_frames() {
            case "\$1" in
EOF

# Add camera-specific limits
for i in "${!CAMERAS[@]}"; do
    IFS='|' read -r rtsp_url frame_interval max_frames <<< "${CAMERAS[$i]}"
    camera_name="camera$(printf "%02d" $i)"
    cat >> "$MANIFEST_DIR/watchdog.yaml" <<EOF
              $camera_name) echo "$max_frames" ;;
EOF
done

cat >> "$MANIFEST_DIR/watchdog.yaml" <<'EOF'
              *) echo "30" ;;
            esac
          }
          
          MY_NODE=$(hostname)
          echo "✓ Watchdog initialized on: $MY_NODE"
          echo ""
          
          while true; do
            # Method 1: Check via Kubernetes API (MOST RELIABLE)
            CAMERA_PODS_ON_NODE=$(kubectl get pods -n $NAMESPACE \
              -l app=camera-ingest \
              --field-selector spec.nodeName=$MY_NODE,status.phase=Running \
              --no-headers 2>/dev/null | wc -l)
            
            # Method 2: Check for recent file writes (BACKUP)
            RECENT_FILES=0
            for camera_dir in /data/camera*/; do
              if [ -d "$camera_dir" ]; then
                recent=$(find "$camera_dir" -name "*.jpg" -mmin -1 2>/dev/null | wc -l)
                if [ "$recent" -gt 0 ]; then
                  RECENT_FILES=$((RECENT_FILES + 1))
                fi
              fi
            done
            
            # Activate if EITHER condition is true
            if [ "$CAMERA_PODS_ON_NODE" -gt 0 ] || [ "$RECENT_FILES" -gt 0 ]; then
              # ACTIVE MODE - Clean up old frames
              for camera_dir in /data/camera*/; do
                if [ -d "$camera_dir" ]; then
                  camera=$(basename "$camera_dir")
                  max_frames=$(get_max_frames "$camera")
                  
                  current=$(find "$camera_dir" -maxdepth 1 -name "*.jpg" -type f 2>/dev/null | wc -l)
                  to_delete=$((current - max_frames))
                  
                  if [ "$to_delete" -gt 0 ]; then
                    echo "[$(date '+%H:%M:%S')] 🟢 ACTIVE [$MY_NODE] [$camera] Cleaning $to_delete frames ($current/$max_frames)"
                    find "$camera_dir" -maxdepth 1 -name "*.jpg" -type f -printf '%T+ %p\n' 2>/dev/null | \
                      sort | head -n "$to_delete" | cut -d' ' -f2- | xargs rm -f 2>/dev/null
                  elif [ "$current" -gt 0 ]; then
                    echo "[$(date '+%H:%M:%S')] 🟢 ACTIVE [$MY_NODE] [$camera] Buffer OK: $current/$max_frames"
                  fi
                fi
              done
            else
              # STANDBY MODE
              echo "[$(date '+%H:%M:%S')] ⚪ STANDBY [$MY_NODE] No cameras active (Pods:$CAMERA_PODS_ON_NODE, Files:$RECENT_FILES)"
            fi
            
            sleep 3
          done
        volumeMounts:
        - name: local-storage
          mountPath: /data
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "100m"
      volumes:
      - name: local-storage
        hostPath:
          path: $NODE1_STORAGE_PATH
          type: DirectoryOrCreate
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: camera-watchdog-sa
  namespace: $NAMESPACE
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: camera-watchdog-role
  namespace: $NAMESPACE
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: camera-watchdog-binding
  namespace: $NAMESPACE
subjects:
- kind: ServiceAccount
  name: camera-watchdog-sa
  namespace: $NAMESPACE
roleRef:
  kind: Role
  name: camera-watchdog-role
  apiGroup: rbac.authorization.k8s.io
EOF

kubectl apply -f "$MANIFEST_DIR/watchdog.yaml"
echo -e "${GREEN}✓ Intelligent watchdog deployed on all nodes${NC}"
echo ""

# Deploy cameras with node affinity and local storage
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Deploying ${#CAMERAS[@]} camera(s)${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

for i in "${!CAMERAS[@]}"; do
    IFS='|' read -r rtsp_url frame_interval max_frames <<< "${CAMERAS[$i]}"
    
    camera_name="camera$(printf "%02d" $i)"
    deployment_name="camera-ingest-$(printf "%02d" $i)"
    
    echo -e "${GREEN}[$i] Camera: $camera_name${NC}"
    echo -e "    RTSP: $rtsp_url"
    echo -e "    Interval: ${frame_interval}s | Buffer: $max_frames frames"
    echo -e "    Storage: Local hostPath on active node"
    
    cat > "$MANIFEST_DIR/${deployment_name}.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $deployment_name
  namespace: $NAMESPACE
  labels:
    app: camera-ingest
    camera: $camera_name
spec:
  replicas: 1
  selector:
    matchLabels:
      app: camera-ingest
      camera: $camera_name
  template:
    metadata:
      labels:
        app: camera-ingest
        camera: $camera_name
    spec:
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            preference:
              matchExpressions:
              - key: kubernetes.io/hostname
                operator: In
                values:
                - $PREFERRED_NODE
          - weight: 50
            preference:
              matchExpressions:
              - key: kubernetes.io/hostname
                operator: In
                values:
                - $BACKUP_NODE
      containers:
      - name: camera-ingest
        image: $IMAGE_NAME
        imagePullPolicy: Never
        env:
        - name: RTSP_URL
          value: "$rtsp_url"
        - name: OUTPUT_DIR
          value: "/app/frames"
        - name: FRAME_INTERVAL
          value: "$frame_interval"
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        volumeMounts:
        - name: local-storage
          mountPath: /app/frames
          subPath: $camera_name
        resources:
          requests:
            memory: "512Mi"
            cpu: "500m"
          limits:
            memory: "2Gi"
            cpu: "2000m"
        livenessProbe:
          exec:
            command:
            - sh
            - -c
            - 'find /app/frames -name "*.jpg" -mmin -2 | grep -q . || exit 1'
          initialDelaySeconds: 60
          periodSeconds: 30
          failureThreshold: 3
      volumes:
      - name: local-storage
        hostPath:
          path: $NODE1_STORAGE_PATH
          type: DirectoryOrCreate
      restartPolicy: Always
EOF
    
    kubectl apply -f "$MANIFEST_DIR/${deployment_name}.yaml"
    echo -e "    ${GREEN}✓ Deployed${NC}"
    echo ""
    sleep 1
done

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Deployment Complete!${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

echo -e "${YELLOW}Waiting for pods to start...${NC}"
sleep 10

echo ""
echo -e "${YELLOW}Current Pod Distribution:${NC}"
kubectl get pods -n $NAMESPACE -o wide

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✓ Auto-Failover System Active${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Primary Node: $PREFERRED_NODE${NC}"
echo -e "${GREEN}  Backup Node:  $BACKUP_NODE${NC}"
echo -e "${GREEN}  Watchdog: Auto-activates on node with cameras${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

echo -e "${BLUE}🔍 How Auto-Failover Works:${NC}"
echo ""
echo -e "${YELLOW}Normal Operation (node1):${NC}"
echo "  • Camera pods run on node1"
echo "  • Watchdog on node1: 🟢 ACTIVE (cleaning frames)"
echo "  • Watchdog on node2: ⚪ STANDBY (sleeping)"
echo ""
echo -e "${YELLOW}When node1 fails:${NC}"
echo "  • K8s automatically moves camera pods to node2"
echo "  • Watchdog on node2 detects pods via K8s API"
echo "  • Watchdog on node2: 🟢 ACTIVE (auto-starts cleaning)"
echo "  • Watchdog on node1: ⚪ STANDBY (if node recovers)"
echo ""
echo -e "${GREEN}✓ Zero manual intervention needed!${NC}"
echo ""

echo -e "${BLUE}📋 Useful Commands:${NC}"
echo ""
echo -e "${YELLOW}Watch watchdog status:${NC}"
echo "  kubectl logs -f -n $NAMESPACE -l app=camera-watchdog"
echo ""
echo -e "${YELLOW}Check which node is active:${NC}"
echo "  kubectl get pods -n $NAMESPACE -o wide"
echo ""
echo -e "${YELLOW}Test failover:${NC}"
echo "  # Drain node1 (simulates failure)"
echo "  kubectl drain $PREFERRED_NODE --ignore-daemonsets --delete-emptydir-data"
echo ""
echo "  # Watch pods move to node2 and watchdog auto-activate"
echo "  kubectl get pods -n $NAMESPACE -o wide -w"
echo ""
echo "  # Verify watchdog on node2 is now ACTIVE"
echo "  kubectl logs -n $NAMESPACE -l app=camera-watchdog --tail=20"
echo ""
echo "  # Restore node1"
echo "  kubectl uncordon $PREFERRED_NODE"
echo ""
echo -e "${YELLOW}Press Ctrl+C to stop all cameras${NC}"
echo ""

# Monitor loop
echo -e "${BLUE}🔍 Monitoring System...${NC}"
echo ""
while true; do
    sleep 10
    
    running=$(kubectl get pods -n $NAMESPACE -l app=camera-ingest --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    total=${#CAMERAS[@]}
    
    if [ "$running" -eq "$total" ]; then
        echo -e "${GREEN}✓ [$(date '+%H:%M:%S')] All cameras running ($running/$total)${NC}"
    else
        echo -e "${YELLOW}⚠ [$(date '+%H:%M:%S')] Status: $running/$total cameras running${NC}"
    fi
    
    # Show which node is active
    active_node=$(kubectl get pods -n $NAMESPACE -l app=camera-ingest -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)
    if [ -n "$active_node" ]; then
        echo -e "    Active Node: ${GREEN}$active_node${NC}"
        if [ "$active_node" = "$PREFERRED_NODE" ]; then
            echo -e "    Data Location: ${GREEN}$active_node:$NODE1_STORAGE_PATH${NC}"
            echo -e "    Watchdog Status: node1=🟢ACTIVE, node2=⚪STANDBY"
        else
            echo -e "    Data Location: ${GREEN}$active_node:$NODE2_STORAGE_PATH${NC}"
            echo -e "    Watchdog Status: node1=⚪STANDBY, node2=🟢ACTIVE"
        fi
    fi
    echo ""
done