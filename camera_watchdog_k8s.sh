#!/bin/bash

# ========= CONFIG =========
NAMESPACE="camera-system"
NODE1_STORAGE_PATH="/mnt/camera_frames"
NODE2_STORAGE_PATH="/mnt/camera_frames"
PREFERRED_NODE="node1"
BACKUP_NODE="node2"
MANIFEST_DIR="./k8s_manifests"
mkdir -p "$MANIFEST_DIR"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'
# ==========================

echo -e "${GREEN}Deploying FIXED Watchdog (Frame Cleaner)${NC}"
echo -e "${YELLOW}This version properly detects which node has cameras${NC}"
echo ""

# Validation
if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}✗ Cannot connect to cluster${NC}"
    exit 1
fi

# Cleanup handler
cleanup() {
    echo -e "\n${YELLOW}Stopping watchdog...${NC}"
    kubectl delete daemonset -n $NAMESPACE camera-watchdog --ignore-not-found=true
    echo -e "${GREEN}✓ Watchdog stopped${NC}"
    exit 0
}
trap cleanup SIGINT SIGTERM

# Create namespace if needed
kubectl create namespace $NAMESPACE 2>/dev/null

# Create RBAC first
cat > "$MANIFEST_DIR/watchdog-rbac.yaml" <<EOF
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
  verbs: ["get", "list", "watch"]
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

kubectl apply -f "$MANIFEST_DIR/watchdog-rbac.yaml"

# Deploy FIXED WATCHDOG with better detection
cat > "$MANIFEST_DIR/watchdog-fixed.yaml" <<EOF
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
          set -e
          apk add --no-cache findutils coreutils bash curl
          
          MY_NODE=\$(hostname)
          ACTIVE=false
          CHECK_COUNTER=0
          MAX_FRAMES=30
          
          echo "╔════════════════════════════════════════╗"
          echo "║ 🐕 Watchdog Starting"
          echo "║ Node: \$MY_NODE"
          echo "║ Storage: /data/"
          echo "║ Max frames per camera: \$MAX_FRAMES"
          echo "╚════════════════════════════════════════╝"
          echo ""
          
          while true; do
            CHECK_COUNTER=\$((CHECK_COUNTER + 1))
            
            # === CRITICAL FIX: Only check K8s API ===
            # Check if ANY camera pods are running on THIS specific node
            CAMERA_PODS=\$(kubectl get pods -n $NAMESPACE \\
              -l app=camera-ingest \\
              --field-selector spec.nodeName=\$MY_NODE,status.phase=Running \\
              --no-headers 2>/dev/null | wc -l)
            
            # Show status every 20 checks (20 seconds)
            if [ \$((CHECK_COUNTER % 20)) -eq 0 ]; then
              if [ "\$CAMERA_PODS" -gt 0 ]; then
                echo "[$(date '+%H:%M:%S')] [\$MY_NODE] 🟢 ACTIVE - \$CAMERA_PODS camera(s) running on this node"
              else
                echo "[$(date '+%H:%M:%S')] [\$MY_NODE] ⚪ STANDBY - No cameras on this node"
              fi
            fi
            
            # Only activate if cameras are ACTUALLY running on this node
            if [ "\$CAMERA_PODS" -gt 0 ]; then
              # ACTIVATE
              if [ "\$ACTIVE" = false ]; then
                echo ""
                echo "╔════════════════════════════════════════╗"
                echo "║ 🟢 WATCHDOG ACTIVATED"
                echo "║ Node: \$MY_NODE"
                echo "║ Camera pods detected: \$CAMERA_PODS"
                echo "╚════════════════════════════════════════╝"
                echo ""
                ACTIVE=true
              fi
              
              # Clean frames in all camera directories
              for camera_dir in /data/camera*/; do
                if [ -d "\$camera_dir" ]; then
                  camera=\$(basename "\$camera_dir")
                  
                  # Count JPG files
                  current=\$(find "\$camera_dir" -maxdepth 1 -name "*.jpg" -type f 2>/dev/null | wc -l)
                  
                  if [ "\$current" -gt "\$MAX_FRAMES" ]; then
                    to_delete=\$((current - MAX_FRAMES))
                    echo "[$(date '+%H:%M:%S')] [\$MY_NODE] 🧹 [\$camera] Cleaning: \$current/\$MAX_FRAMES | Deleting \$to_delete oldest"
                    
                    # Delete oldest files by timestamp
                    find "\$camera_dir" -maxdepth 1 -name "*.jpg" -type f -printf '%T+ %p\n' 2>/dev/null | \\
                      sort | head -n "\$to_delete" | cut -d' ' -f2- | xargs rm -f 2>/dev/null
                    
                    # Verify
                    new_count=\$(find "\$camera_dir" -maxdepth 1 -name "*.jpg" -type f 2>/dev/null | wc -l)
                    echo "[$(date '+%H:%M:%S')] [\$MY_NODE]     ✓ [\$camera] Remaining: \$new_count frames"
                  elif [ "\$current" -gt 0 ]; then
                    # Only log every 60 seconds if buffer is OK
                    if [ \$((CHECK_COUNTER % 60)) -eq 0 ]; then
                      echo "[$(date '+%H:%M:%S')] [\$MY_NODE] ✓ [\$camera] Buffer OK: \$current/\$MAX_FRAMES"
                    fi
                  fi
                fi
              done
            else
              # DEACTIVATE
              if [ "\$ACTIVE" = true ]; then
                echo ""
                echo "╔════════════════════════════════════════╗"
                echo "║ ⚪ WATCHDOG DEACTIVATED"
                echo "║ Node: \$MY_NODE"
                echo "║ Reason: No camera pods on this node"
                echo "╚════════════════════════════════════════╝"
                echo ""
                ACTIVE=false
              fi
            fi
            
            sleep 1
          done
        volumeMounts:
        - name: storage
          mountPath: /data
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "100m"
      volumes:
      - name: storage
        hostPath:
          path: $NODE1_STORAGE_PATH
          type: DirectoryOrCreate
EOF

kubectl apply -f "$MANIFEST_DIR/watchdog-fixed.yaml"

echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ FIXED Watchdog Deployed${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""

sleep 5

echo -e "${YELLOW}Watchdog Pods:${NC}"
kubectl get pods -n $NAMESPACE -l app=camera-watchdog -o wide

echo ""
echo -e "${BLUE}Key Fixes:${NC}"
echo "  ✓ Only uses K8s API to detect cameras (removed file-based detection)"
echo "  ✓ Checks spec.nodeName to ensure cameras are on THIS node"
echo "  ✓ Activates ONLY when pods are actually running locally"
echo "  ✓ Better logging to show which node is active"
echo ""
echo -e "${GREEN}Expected Behavior:${NC}"
echo "  • When cameras on node1: node1=🟢ACTIVE, node2=⚪STANDBY"
echo "  • When cameras on node2: node1=⚪STANDBY, node2=🟢ACTIVE"
echo "  • Only the active node cleans frames"
echo ""
echo -e "${YELLOW}Watch logs from BOTH nodes:${NC}"
echo "  kubectl logs -f -n $NAMESPACE -l app=camera-watchdog --prefix=true --all-containers=true"
echo ""
echo -e "${YELLOW}Test failover:${NC}"
echo "  # Move cameras to node2"
echo "  kubectl drain node1 --ignore-daemonsets --delete-emptydir-data"
echo ""
echo "  # Watch pods move"
echo "  kubectl get pods -n $NAMESPACE -o wide -w"
echo ""
echo -e "${RED}Press Ctrl+C to stop${NC}"
echo ""

# Monitor watchdog logs
echo -e "${GREEN}Streaming watchdog logs from all nodes...${NC}"
echo ""
kubectl logs -f -n $NAMESPACE -l app=camera-watchdog --prefix=true --all-containers=true --tail=20