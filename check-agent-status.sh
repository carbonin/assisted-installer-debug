#!/bin/bash

# Script to check Agent (host) status from extracted must-gather data

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

# Find all agent files
agent_files=$(find "$DATA_DIR/crs" -type f -path "*/agent-install.openshift.io/agents/*.yaml" 2>/dev/null | sort || true)

if [ -z "$agent_files" ]; then
    echo "No Agent resources found"
    exit 0
fi

# Process each Agent
while IFS= read -r agent; do
    if [ ! -f "$agent" ]; then
        continue
    fi

    # Extract basic information
    agent_id=$(yq eval '.metadata.name' < "$agent")
    namespace=$(yq eval '.metadata.namespace' < "$agent")
    cluster_name=$(yq eval '.spec.clusterDeploymentName.name // "unknown"' < "$agent")
    role=$(yq eval '.status.role // "unknown"' < "$agent")
    hostname=$(yq eval '.status.inventory.hostname // ""' < "$agent")

    # Get progress information
    current_stage=$(yq eval '.status.progress.currentStage // "unknown"' < "$agent")
    install_percentage=$(yq eval '.status.progress.installationPercentage // 0' < "$agent")

    # Get state information
    state=$(yq eval '.status.debugInfo.state // "unknown"' < "$agent")
    state_info=$(yq eval '.status.debugInfo.stateInfo // ""' < "$agent")

    # Determine overall status
    if [ "$current_stage" = "Done" ] && [ "$install_percentage" -eq 100 ]; then
        status="INSTALLED"
    elif [[ "$state" == *"error"* ]] || [[ "$state" == *"failed"* ]]; then
        status="FAILED"
    elif [[ "$state" == *"installing"* ]] || [[ "$current_stage" =~ ^(Installing|Rebooting|Configuring|Waiting)$ ]]; then
        status="INSTALLING"
    elif [[ "$state" == *"pending"* ]] || [[ "$state" == *"insufficient"* ]] || [[ "$state" == *"known"* ]]; then
        status="PENDING"
    else
        status="$state"
    fi

    echo "Agent: $agent_id"
    echo "  File: $agent"
    echo "  Cluster: $namespace/$cluster_name"
    echo "  Role: $role"
    if [ -n "$hostname" ] && [ "$hostname" != "null" ]; then
        echo "  Hostname: $hostname"
    fi
    echo "  Status: $status"
    echo "  Stage: $current_stage ($install_percentage%)"
    echo "  State: $state"
    if [ -n "$state_info" ] && [ "$state_info" != "null" ]; then
        echo "  State Info: $state_info"
    fi

    # For problematic agents, show additional details
    if [ "$status" = "FAILED" ] || [[ "$state" == *"pending-user-action"* ]] || [[ "$current_stage" == "Rebooting" && "$install_percentage" -lt 100 ]]; then
        yq eval '.status.conditions[] | "  Condition: " + .type + " = " + .status + " (" + .reason + ")"' < "$agent" 2>/dev/null | grep -v "null" || true

        bmh_ref=$(yq eval '.metadata.labels."agent-install.openshift.io/bmh" // ""' < "$agent")
        if [ -n "$bmh_ref" ] && [ "$bmh_ref" != "null" ]; then
            echo "  BareMetalHost: $bmh_ref"
        fi
    fi
    echo ""
done <<< "$agent_files"
