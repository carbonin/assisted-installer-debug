#!/bin/bash

set -euo pipefail

# Script to extract ACM must-gather resources to a new directory for analysis

usage() {
    echo "Usage: $0 <source-dir> <dest-dir>"
    echo "  source-dir: Path to the ACM must-gather archive root"
    echo "  dest-dir: Path to output directory (will be created)"
    exit 1
}

# Check arguments
if [ $# -ne 2 ]; then
    usage
fi

SOURCE_DIR="$1"
DEST_DIR="$2"

# Validate source directory exists
if [ ! -d "$SOURCE_DIR" ]; then
    echo "Error: Source directory '$SOURCE_DIR' does not exist"
    exit 1
fi

# Create destination directory structure
echo "Creating destination directory: $DEST_DIR"
mkdir -p "$DEST_DIR/crs"
mkdir -p "$DEST_DIR/assisted-pods"

# Track namespaces that have agentclusterinstalls (for hive.openshift.io processing)
NAMESPACES_WITH_ACI=$(mktemp)
# Track namespaces that have infraenvs (for metal3.io processing)
NAMESPACES_WITH_INFRAENV=$(mktemp)
trap "rm -f $NAMESPACES_WITH_ACI $NAMESPACES_WITH_INFRAENV" EXIT

# Find and process agent-install.openshift.io directories
echo "Processing agent-install.openshift.io resources..."
while IFS= read -r dir; do
    # Determine if this is cluster-scoped or namespaced
    if echo "$dir" | grep -q "cluster-scoped-resources"; then
        scope="cluster-scoped"
        namespace="cluster"
    else
        # Extract namespace from path
        namespace=$(echo "$dir" | sed -n 's|.*/namespaces/\([^/]*\)/.*|\1|p')
        scope="namespaced"
    fi

    echo "  Found: $dir (scope: $scope, namespace: $namespace)"

    # Process each resource type subdirectory
    find "$dir" -mindepth 1 -maxdepth 1 -type d | while IFS= read -r resource_dir; do
        resource_type=$(basename "$resource_dir")
        dest_subdir="$DEST_DIR/crs/${namespace}/agent-install.openshift.io/${resource_type}"

        # Create destination subdirectory
        mkdir -p "$dest_subdir"

        # Copy YAML files
        yaml_count=$(find "$resource_dir" -maxdepth 1 -name "*.yaml" | wc -l)
        if [ "$yaml_count" -gt 0 ]; then
            cp "$resource_dir"/*.yaml "$dest_subdir/" 2>/dev/null || true
            echo "    Copied $yaml_count $resource_type files to crs/${namespace}/agent-install.openshift.io/${resource_type}/"

            # Track namespaces with infraenvs for metal3.io processing
            if [ "$resource_type" = "infraenvs" ] && [ "$namespace" != "cluster" ]; then
                echo "$namespace" >> "$NAMESPACES_WITH_INFRAENV"
            fi
        fi
    done
done < <(find "$SOURCE_DIR" -type d -name "agent-install.openshift.io")

# Find and process extensions.hive.openshift.io directories
echo "Processing extensions.hive.openshift.io resources..."
while IFS= read -r dir; do
    # Determine if this is cluster-scoped or namespaced
    if echo "$dir" | grep -q "cluster-scoped-resources"; then
        scope="cluster-scoped"
        namespace="cluster"
    else
        # Extract namespace from path
        namespace=$(echo "$dir" | sed -n 's|.*/namespaces/\([^/]*\)/.*|\1|p')
        scope="namespaced"
    fi

    echo "  Found: $dir (scope: $scope, namespace: $namespace)"

    # Process each resource type subdirectory
    find "$dir" -mindepth 1 -maxdepth 1 -type d | while IFS= read -r resource_dir; do
        resource_type=$(basename "$resource_dir")
        dest_subdir="$DEST_DIR/crs/${namespace}/extensions.hive.openshift.io/${resource_type}"

        # Create destination subdirectory
        mkdir -p "$dest_subdir"

        # Copy YAML files
        yaml_count=$(find "$resource_dir" -maxdepth 1 -name "*.yaml" | wc -l)
        if [ "$yaml_count" -gt 0 ]; then
            cp "$resource_dir"/*.yaml "$dest_subdir/" 2>/dev/null || true
            echo "    Copied $yaml_count $resource_type files to crs/${namespace}/extensions.hive.openshift.io/${resource_type}/"

            # Track namespaces with agentclusterinstalls for hive.openshift.io processing
            if [ "$resource_type" = "agentclusterinstalls" ] && [ "$namespace" != "cluster" ]; then
                echo "$namespace" >> "$NAMESPACES_WITH_ACI"
            fi
        fi
    done
done < <(find "$SOURCE_DIR" -type d -name "extensions.hive.openshift.io")

# Find and process hive.openshift.io directories for namespaces with agentclusterinstalls
if [ -s "$NAMESPACES_WITH_ACI" ]; then
    echo "Processing hive.openshift.io resources for namespaces with agentclusterinstalls..."
    sort -u "$NAMESPACES_WITH_ACI" | while IFS= read -r namespace; do
        # Find hive.openshift.io directory for this namespace
        hive_dir=$(find "$SOURCE_DIR" -type d -path "*/namespaces/${namespace}/hive.openshift.io" 2>/dev/null | head -1)

        if [ -n "$hive_dir" ] && [ -d "$hive_dir" ]; then
            echo "  Found: $hive_dir (namespace: $namespace)"

            # Process each resource type subdirectory
            find "$hive_dir" -mindepth 1 -maxdepth 1 -type d | while IFS= read -r resource_dir; do
                resource_type=$(basename "$resource_dir")
                dest_subdir="$DEST_DIR/crs/${namespace}/hive.openshift.io/${resource_type}"

                # Create destination subdirectory
                mkdir -p "$dest_subdir"

                # Copy YAML files
                yaml_count=$(find "$resource_dir" -maxdepth 1 -name "*.yaml" | wc -l)
                if [ "$yaml_count" -gt 0 ]; then
                    cp "$resource_dir"/*.yaml "$dest_subdir/" 2>/dev/null || true
                    echo "    Copied $yaml_count $resource_type files to crs/${namespace}/hive.openshift.io/${resource_type}/"
                fi
            done
        fi
    done
fi

# Find and process metal3.io directories for namespaces with infraenvs
if [ -s "$NAMESPACES_WITH_INFRAENV" ]; then
    echo "Processing metal3.io resources for namespaces with infraenvs..."
    sort -u "$NAMESPACES_WITH_INFRAENV" | while IFS= read -r namespace; do
        # Find metal3.io directory for this namespace
        metal3_dir=$(find "$SOURCE_DIR" -type d -path "*/namespaces/${namespace}/metal3.io" 2>/dev/null | head -1)

        if [ -n "$metal3_dir" ] && [ -d "$metal3_dir" ]; then
            echo "  Found: $metal3_dir (namespace: $namespace)"

            # Process each resource type subdirectory
            find "$metal3_dir" -mindepth 1 -maxdepth 1 -type d | while IFS= read -r resource_dir; do
                resource_type=$(basename "$resource_dir")
                dest_subdir="$DEST_DIR/crs/${namespace}/metal3.io/${resource_type}"

                # Create destination subdirectory
                mkdir -p "$dest_subdir"

                # Copy YAML files
                yaml_count=$(find "$resource_dir" -maxdepth 1 -name "*.yaml" | wc -l)
                if [ "$yaml_count" -gt 0 ]; then
                    cp "$resource_dir"/*.yaml "$dest_subdir/" 2>/dev/null || true
                    echo "    Copied $yaml_count $resource_type files to crs/${namespace}/metal3.io/${resource_type}/"
                fi
            done
        fi
    done
fi

# Find and process assisted-service pod directories from multicluster-engine namespace
echo "Processing assisted-service pods from multicluster-engine namespace..."
mce_pods_dir=$(find "$SOURCE_DIR" -type d -path "*/namespaces/multicluster-engine/pods" 2>/dev/null | head -1)

if [ -n "$mce_pods_dir" ] && [ -d "$mce_pods_dir" ]; then
    # Pod patterns to extract
    pod_patterns=(
        "agentinstalladmission-*"
        "assisted-image-service-*"
        "assisted-service-*"
        "infrastructure-operator-*"
    )

    pods_copied=0
    for pattern in "${pod_patterns[@]}"; do
        # Find matching pod directories
        while IFS= read -r pod_dir; do
            if [ -d "$pod_dir" ]; then
                pod_name=$(basename "$pod_dir")
                echo "  Copying pod: $pod_name"
                cp -r "$pod_dir" "$DEST_DIR/assisted-pods/"
                pods_copied=$((pods_copied + 1))
            fi
        done < <(find "$mce_pods_dir" -maxdepth 1 -type d -name "$pattern" 2>/dev/null)
    done

    if [ "$pods_copied" -gt 0 ]; then
        echo "  Copied $pods_copied pod directories to assisted-pods/"
    else
        echo "  No matching pods found"
    fi
else
    echo "  multicluster-engine/pods directory not found"
fi

# Find and process metal3 pod directories from openshift-machine-api namespace
echo "Processing metal3 pods from openshift-machine-api namespace..."
machine_api_pods_dir=$(find "$SOURCE_DIR" -type d -path "*/namespaces/openshift-machine-api/pods" 2>/dev/null | head -1)

if [ -n "$machine_api_pods_dir" ] && [ -d "$machine_api_pods_dir" ]; then
    # Pod pattern to extract (metal3-* covers all metal3 pods including metal3-baremetal-operator-*)
    pod_patterns=(
        "metal3-*"
    )

    pods_copied=0
    for pattern in "${pod_patterns[@]}"; do
        # Find matching pod directories
        while IFS= read -r pod_dir; do
            if [ -d "$pod_dir" ]; then
                pod_name=$(basename "$pod_dir")
                echo "  Copying pod: $pod_name"
                cp -r "$pod_dir" "$DEST_DIR/assisted-pods/"
                pods_copied=$((pods_copied + 1))
            fi
        done < <(find "$machine_api_pods_dir" -maxdepth 1 -type d -name "$pattern" 2>/dev/null)
    done

    if [ "$pods_copied" -gt 0 ]; then
        echo "  Copied $pods_copied pod directories to assisted-pods/"
    else
        echo "  No matching pods found"
    fi
else
    echo "  openshift-machine-api/pods directory not found"
fi

echo ""
echo "Extraction complete!"
# Count total files in destination
total_files=$(find "$DEST_DIR/crs" -type f -name "*.yaml" | wc -l)
echo "Total files copied: $total_files"
echo "Destination: $DEST_DIR"
echo ""
echo "Directory structure:"
echo "  $DEST_DIR/"
echo "    ├── crs/  (custom resources organized by namespace, API group, and resource type)"
echo "    └── assisted-pods/  (pod directories from multicluster-engine namespace)"
