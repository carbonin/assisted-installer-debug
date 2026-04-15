#!/bin/bash

# Script to check AgentClusterInstall status from extracted must-gather data

set -euo pipefail

usage() {
    echo "Usage: $0 <data-dir>"
    echo "  data-dir: Path to extracted must-gather data (output from extract-assisted-data.sh)"
    exit 1
}

if [ $# -ne 1 ]; then
    usage
fi

DATA_DIR="$1"

if [ ! -d "$DATA_DIR" ]; then
    echo "Error: Directory '$DATA_DIR' does not exist"
    exit 1
fi

# Find all agentclusterinstall files
aci_files=$(find "$DATA_DIR/crs" -type f -path "*/extensions.hive.openshift.io/agentclusterinstalls/*.yaml" 2>/dev/null | sort || true)

if [ -z "$aci_files" ]; then
    echo "No AgentClusterInstall resources found"
    exit 0
fi

# Process each ACI
while IFS= read -r aci; do
    if [ ! -f "$aci" ]; then
        continue
    fi

    # Extract basic information
    cluster_name=$(yq eval '.spec.clusterDeploymentRef.name // .metadata.name' < "$aci")
    namespace=$(yq eval '.metadata.namespace' < "$aci")
    version=$(yq eval '.spec.imageSetRef.name // "unknown"' < "$aci")

    # Get status conditions
    failed_status=$(yq eval '.status.conditions[] | select(.type == "Failed") | .status' < "$aci" 2>/dev/null || echo "")
    failed_reason=$(yq eval '.status.conditions[] | select(.type == "Failed") | .reason' < "$aci" 2>/dev/null || echo "")
    failed_message=$(yq eval '.status.conditions[] | select(.type == "Failed") | .message' < "$aci" 2>/dev/null || echo "")

    completed_status=$(yq eval '.status.conditions[] | select(.type == "Completed") | .status' < "$aci" 2>/dev/null || echo "")
    completed_message=$(yq eval '.status.conditions[] | select(.type == "Completed") | .message' < "$aci" 2>/dev/null || echo "")

    state=$(yq eval '.status.debugInfo.state // "unknown"' < "$aci")
    state_info=$(yq eval '.status.debugInfo.stateInfo // ""' < "$aci")

    # Determine overall status
    if [ "$failed_status" = "True" ]; then
        status="FAILED"
    elif [ "$completed_status" = "True" ] && echo "$completed_message" | grep -qi "but some workers"; then
        status="WARNING"
    elif [ "$completed_status" = "True" ]; then
        status="SUCCESS"
    else
        status="IN_PROGRESS"
    fi

    echo "Cluster: $namespace/$cluster_name"
    echo "  File: $aci"
    echo "  Version: $version"
    echo "  Status: $status"
    echo "  State: $state"
    if [ -n "$state_info" ] && [ "$state_info" != "null" ]; then
        echo "  State Info: $state_info"
    fi

    # For failed or problematic clusters, show additional details
    if [ "$failed_status" = "True" ] || [[ "$state" == *"error"* ]] || [[ "$state" == *"pending-user-action"* ]]; then
        if [ -n "$failed_reason" ] && [ "$failed_reason" != "null" ]; then
            echo "  Failed Reason: $failed_reason"
        fi
        if [ -n "$failed_message" ] && [ "$failed_message" != "null" ]; then
            echo "  Failed Message: $failed_message"
        fi
        echo "  Conditions:"
        yq eval '.status.conditions[] | "    " + .type + ": " + .status + " (" + .reason + ")"' < "$aci" 2>/dev/null | grep -v "null" || echo "    none"
    fi
    echo ""
done <<< "$aci_files"
