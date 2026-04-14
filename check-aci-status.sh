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

echo "Checking AgentClusterInstall status..."
echo ""

# Find all agentclusterinstall files
aci_files=$(find "$DATA_DIR/crs" -type f -path "*/agentclusterinstalls/*.yaml" | sort)

if [ -z "$aci_files" ]; then
    echo "No AgentClusterInstall resources found"
    exit 0
fi

failed_count=0
warning_count=0
success_count=0

# Process each ACI
while IFS= read -r aci; do
    namespace=$(basename $(dirname $(dirname $(dirname "$aci"))))
    cluster_name=$(basename "$aci" .yaml)

    # Get Completed condition
    completed_status=$(yq eval '.status.conditions[] | select(.type == "Completed") | .status' "$aci" 2>/dev/null || echo "Unknown")
    completed_reason=$(yq eval '.status.conditions[] | select(.type == "Completed") | .reason' "$aci" 2>/dev/null || echo "Unknown")
    completed_message=$(yq eval '.status.conditions[] | select(.type == "Completed") | .message' "$aci" 2>/dev/null || echo "Unknown")
    state=$(yq eval '.status.debugInfo.state' "$aci" 2>/dev/null || echo "unknown")
    state_info=$(yq eval '.status.debugInfo.stateInfo' "$aci" 2>/dev/null || echo "unknown")

    # Determine overall status
    if [ "$completed_status" = "False" ]; then
        status_icon="❌ FAILED"
        ((failed_count++))
    elif [ "$completed_status" = "True" ] && echo "$completed_message" | grep -qi "but some workers"; then
        status_icon="⚠️  WARNING"
        ((warning_count++))
    elif [ "$completed_status" = "True" ]; then
        status_icon="✅ SUCCESS"
        ((success_count++))
    else
        status_icon="❓ UNKNOWN"
    fi

    echo "Cluster: $namespace/$cluster_name"
    echo "  Status: $status_icon"
    echo "  State: $state"
    echo "  Message: $state_info"
    echo ""
done <<< "$aci_files"

echo "Summary:"
echo "  Total clusters: $((failed_count + warning_count + success_count))"
echo "  ❌ Failed: $failed_count"
echo "  ⚠️  Warnings: $warning_count"
echo "  ✅ Success: $success_count"
echo ""

if [ $failed_count -gt 0 ]; then
    echo "Failed clusters require investigation. Focus on:"
    while IFS= read -r aci; do
        completed_status=$(yq eval '.status.conditions[] | select(.type == "Completed") | .status' "$aci" 2>/dev/null || echo "Unknown")
        if [ "$completed_status" = "False" ]; then
            namespace=$(basename $(dirname $(dirname $(dirname "$aci"))))
            cluster_name=$(basename "$aci" .yaml)
            echo "  - $namespace/$cluster_name"
        fi
    done <<< "$aci_files"
fi
