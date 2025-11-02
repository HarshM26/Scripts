#!/bin/bash

# Configuration
NAMESPACE="camera-system"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Stopping Camera System${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if namespace exists
if ! kubectl get namespace $NAMESPACE &>/dev/null; then
    echo -e "${YELLOW}Namespace '$NAMESPACE' does not exist. Nothing to stop.${NC}"
    exit 0
fi

# Show current status
echo -e "${YELLOW}Current pods in namespace '$NAMESPACE':${NC}"
kubectl get pods -n $NAMESPACE -o wide
echo ""

# Stop camera deployments
echo -e "${YELLOW}Stopping camera deployments...${NC}"
camera_count=$(kubectl get deployments -n $NAMESPACE -l app=camera-ingest --no-headers 2>/dev/null | wc -l)
if [ "$camera_count" -gt 0 ]; then
    kubectl delete deployment -n $NAMESPACE -l app=camera-ingest --ignore-not-found=true
    echo -e "${GREEN}✓ Deleted $camera_count camera deployment(s)${NC}"
else
    echo -e "${YELLOW}  No camera deployments found${NC}"
fi
echo ""

# Stop watchdog
echo -e "${YELLOW}Stopping watchdog daemonset...${NC}"
if kubectl get daemonset -n $NAMESPACE camera-watchdog &>/dev/null; then
    kubectl delete daemonset -n $NAMESPACE camera-watchdog --ignore-not-found=true
    echo -e "${GREEN}✓ Watchdog stopped${NC}"
else
    echo -e "${YELLOW}  Watchdog not found${NC}"
fi
echo ""

# Wait for pods to terminate
echo -e "${YELLOW}Waiting for pods to terminate...${NC}"
timeout=60
elapsed=0
while [ $elapsed -lt $timeout ]; do
    remaining=$(kubectl get pods -n $NAMESPACE --no-headers 2>/dev/null | wc -l)
    if [ "$remaining" -eq 0 ]; then
        echo -e "${GREEN}✓ All pods terminated${NC}"
        break
    fi
    echo "  Waiting... ($remaining pods remaining)"
    sleep 3
    elapsed=$((elapsed + 3))
done

if [ "$remaining" -gt 0 ]; then
    echo -e "${YELLOW}⚠ Some pods still terminating. Forcing deletion...${NC}"
    kubectl delete pods -n $NAMESPACE --all --force --grace-period=0 2>/dev/null
fi
echo ""

# Optionally delete storage (ask user)
read -p "Delete storage (PVC/PV)? This will remove all saved frames. (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Deleting storage...${NC}"
    kubectl delete pvc -n $NAMESPACE camera-frames-pvc --ignore-not-found=true
    kubectl delete pv camera-frames-pv --ignore-not-found=true
    echo -e "${GREEN}✓ Storage deleted${NC}"
else
    echo -e "${BLUE}Storage preserved. Frames are still available on NFS.${NC}"
fi
echo ""

# Optionally delete namespace
read -p "Delete namespace '$NAMESPACE'? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Deleting namespace...${NC}"
    kubectl delete namespace $NAMESPACE --ignore-not-found=true
    echo -e "${GREEN}✓ Namespace deleted${NC}"
else
    echo -e "${BLUE}Namespace preserved for future use.${NC}"
fi
echo ""

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✓ Camera system stopped successfully${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}To restart the system:${NC}"
echo "  ./camera_runner_k8s.sh"
echo ""
