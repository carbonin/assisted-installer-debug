---
name: debug-must-gather
description: Debug customer issues with assisted installer using ACM must-gather archives
trigger: When user mentions ACM must-gather, assisted installer failures, cluster installation issues, debugging installation problems, or analyzing agent/host errors
---

# Debug Assisted Installer Must-Gather

This skill helps debug customer issues with the assisted installer by analyzing ACM must-gather archives.

## Overview

When investigating customer issues with assisted installer deployments managed by ACM (Advanced Cluster Management), the must-gather archive contains critical logs and resource snapshots needed for debugging.

## Prerequisites

- ACM must-gather archive (typically a .tar.gz file)
- Familiarity with assisted installer architecture
- Access to relevant Jira for tracking issues

## Typical Issues Investigated

This skill helps debug:
- **Installation failures**: Cluster install timeouts, hosts stuck at specific stages
- **Host/agent issues**: Hosts not booting, stuck at rebooting, validation failures
- **Power management problems**: BMC/Ironic failures to reboot or power hosts
- **Network issues**: API VIP unreachable, worker nodes not joining cluster
- **Timeout analysis**: Understanding why installations time out vs. genuine failures

## Debugging Workflow

### 1. Extract and Locate Must-Gather

First, extract the relevant assisted installer data from the ACM must-gather archive:

```bash
# Use the extraction script to pull out relevant resources
./extract-assisted-data.sh <path-to-must-gather> <output-dir>

# Example:
./extract-assisted-data.sh ~/Downloads/acm-must-gather ./path-to-data
```

This script will:
- Extract agent-install.openshift.io resources (Agents, InfraEnvs, NMStateConfigs)
- Extract extensions.hive.openshift.io resources (AgentClusterInstalls)
- Extract hive.openshift.io resources (ClusterDeployments)
- Extract metal3.io resources (BareMetalHosts, PreprovisioningImages)
- Copy assisted-service pod logs from multicluster-engine namespace
- Copy metal3 pod logs from openshift-machine-api namespace

See the "Common Log Locations" section below for the complete extracted directory structure.

### 2. Identify the Problem Scope

After extracting the data, check all AgentClusterInstall resources for failures:

```bash
# Quick manual check
./check-aci-status.sh ./path-to-data

# Or check manually
for aci in ./path-to-data/crs/*/extensions.hive.openshift.io/agentclusterinstalls/*.yaml; do
  echo "=== $(basename $(dirname $(dirname $(dirname $aci))))"
  yq eval '.status.conditions[] | select(.type == "Completed")' "$aci"
  yq eval '.status.debugInfo.stateInfo' "$aci"
  echo ""
done
```

**Key things to check in AgentClusterInstall:**
- `.status.conditions[] | select(.type == "Completed")` - Look for `status: "False"` (failed) or warnings in message
- `.status.debugInfo.state` - Current state (error, adding-hosts, etc.)
- `.status.debugInfo.stateInfo` - Human-readable status message

**Common failure patterns:**
- "timed out while pending user action" - Hosts not booting from ISO
- "some workers did not join" - Worker node issues after control plane success
- Validation errors - Host requirements not met

### 3. Investigate Failed Cluster Details

Once you've identified a failed cluster, dig deeper into the agent status:

```bash
# Set the namespace of the failed cluster
NAMESPACE="<failed-cluster-namespace>"

# Check which agents didn't complete
for agent in ./path-to-data/crs/$NAMESPACE/agent-install.openshift.io/agents/*.yaml; do
  name=$(yq eval '.metadata.name' "$agent")
  role=$(yq eval '.spec.role' "$agent")
  current_stage=$(yq eval '.status.progress.currentStage' "$agent")
  install_pct=$(yq eval '.status.progress.installationPercentage' "$agent")
  progress_info=$(yq eval '.status.progress.progressInfo' "$agent")

  if [ "$current_stage" != "Done" ] || [ "$install_pct" != "100" ]; then
    echo "❌ $name ($role): $current_stage ($install_pct%) - $progress_info"
  fi
done

# Get details for stuck hosts
for agent in ./path-to-data/crs/$NAMESPACE/agent-install.openshift.io/agents/*.yaml; do
  current_stage=$(yq eval '.status.progress.currentStage' "$agent")
  if [ "$current_stage" != "Done" ]; then
    hostname=$(yq eval '.status.inventory.hostname' "$agent")
    bmh=$(yq eval '.metadata.labels."agent-install.openshift.io/bmh"' "$agent")
    agent_id=$(yq eval '.metadata.name' "$agent")
    echo "Stuck host: $hostname (BMH: $bmh, Agent: $agent_id)"
  fi
done
```

### 4. Analyze Assisted-Service Logs

Check the assisted-service logs for error details:

```bash
# Locate assisted-service logs
AS_LOG=$(find ./path-to-data/assisted-pods -path "*/assisted-service/*/current.log" -type f)

# Check log date range first (logs may be rotated)
echo "Log start:" && head -1 "$AS_LOG"
echo "Log end:" && tail -1 "$AS_LOG"

# Get cluster ID from AgentClusterInstall
CLUSTER_ID=$(yq eval '.spec.clusterMetadata.infraID' ./path-to-data/crs/$NAMESPACE/extensions.hive.openshift.io/agentclusterinstalls/*.yaml)

# Search for cluster/host events
grep "$CLUSTER_ID" "$AS_LOG" | grep -E "error|fail|timeout" | tail -50
grep "<stuck-host-id>" "$AS_LOG" | grep -E "error|reboot|installing" | head -30
```

**Note**: The Agent CR name (e.g., `2d53bce4-8051-c30a-6fb1-43dc9fcf2993`) is the **host ID** used in assisted-service logs. Use this to correlate log entries with specific agent resources.

**Note**: Must-gather logs may not cover the full failure timeline if collected days after the incident.

### 5. Check BareMetalHost Status (for metal3/power issues)

When hosts are stuck at rebooting or have power-related issues:

```bash
# Get BareMetalHost name from stuck agent
AGENT_FILE="./path-to-data/crs/$NAMESPACE/agent-install.openshift.io/agents/<stuck-agent-id>.yaml"
BMH_NAME=$(yq eval '.metadata.labels."agent-install.openshift.io/bmh"' "$AGENT_FILE")

# Find and check the BareMetalHost
BMH_FILE=$(find ./path-to-data/crs/$NAMESPACE/metal3.io/baremetalhosts/ -name "$BMH_NAME.yaml")

echo "=== BareMetalHost: $BMH_NAME ==="
echo "Provisioning State:"
yq eval '.status.provisioning.state' "$BMH_FILE"

echo "Power State:"
yq eval '.status.poweredOn' "$BMH_FILE"

echo "Error Message:"
yq eval '.status.errorMessage' "$BMH_FILE"

echo "Last Updated:"
yq eval '.status.lastUpdated' "$BMH_FILE"
```

### 6. Cross-Reference with Code

To understand **why** a failure happened (not just **what** failed), you need to examine the exact code version running in the must-gather.

#### Get component images and upstream refs

All component images are available in the infrastructure-operator environment variables:

```bash
# 1. Find the infrastructure-operator pod YAML
INFRA_OP_YAML=$(find ./path-to-data/assisted-pods -name "infrastructure-operator-*.yaml" -type f)

# 2. Extract the image for the component you're debugging (example: SERVICE_IMAGE)
IMAGE=$(yq eval '.spec.containers[] | select(.name == "manager") | .env[] | select(.name == "SERVICE_IMAGE") | .value' "$INFRA_OP_YAML")

# 3. Use skopeo to get the upstream repo and commit
skopeo inspect "docker://$IMAGE" | jq -r '.Labels | "Repo: \(.["upstream-url"])\nCommit: \(.["upstream-ref"])"'

# 4. Clone and checkout the code
UPSTREAM_REF=$(skopeo inspect "docker://$IMAGE" | jq -r '.Labels."upstream-ref"')
git clone https://github.com/openshift/assisted-service assisted-service-code
cd assisted-service-code
git checkout "$UPSTREAM_REF"
git log -1 --oneline
```

#### Component Reference Table

| Component | Env Var in infrastructure-operator | Repository |
|-----------|-----------------------------------|------------|
| Assisted Service | `SERVICE_IMAGE` or `SERVICE_EL8_IMAGE` | https://github.com/openshift/assisted-service |
| Assisted Installer (Controller) | `CONTROLLER_IMAGE` or `INSTALLER_IMAGE` | https://github.com/openshift/assisted-installer |
| Assisted Installer Agent | `AGENT_IMAGE` | https://github.com/openshift/assisted-installer-agent |
| Assisted Image Service | `IMAGE_SERVICE_IMAGE` | https://github.com/openshift/assisted-image-service |

**Note**: Env vars in the same row point to the same codebase at the same commit.

#### Investigate the code

Now you can search the code to understand the logic behind the failure:

```bash
# Search for error messages from the must-gather
grep -r "error message text" --include="*.go"

# Find state machine transitions
# For cluster state: internal/cluster/statemachine.go
# For host state: internal/host/statemachine.go

# Find timeout values
grep -r "timeout" --include="*.go" internal/cluster/common.go internal/host/common.go
```

**Example Investigation**: Why does 1 stuck worker cause entire cluster to fail?

1. Find where the error message is defined:
   ```bash
   grep -r "pending user action.*manual.*boot" --include="*.go"
   # Found: internal/cluster/common.go
   ```

2. Trace the state transitions:
   - `internal/host/statemachine.go` line ~868: Host stuck at "Rebooting" + timeout → `HostStatusInstallingPendingUserAction`
   - `internal/cluster/transition.go` line ~450: Function `IsInstallingPendingUserAction` - if **ANY** host has this status → cluster moves to `ClusterStatusInstallingPendingUserAction`
   - `internal/cluster/statemachine.go` line ~306: Cluster in `InstallingPendingUserAction` + timeout → Error state

3. **Root cause**: Even 1 host stuck at rebooting can fail the entire cluster because the cluster state depends on ALL hosts being healthy.

### 7. Document Findings

## Common Log Locations

### Extracted Directory Structure
```
<output-dir>/
├── crs/
│   ├── cluster/                    # Cluster-scoped resources
│   │   └── agent-install.openshift.io/
│   │       └── agentserviceconfigs/
│   └── <namespace>/                # Per-namespace resources
│       ├── agent-install.openshift.io/
│       │   ├── agents/             # Host/agent status
│       │   ├── infraenvs/          # Infrastructure environment config
│       │   └── nmstateconfigs/     # Network configuration
│       ├── extensions.hive.openshift.io/
│       │   └── agentclusterinstalls/  # Cluster installation status
│       ├── hive.openshift.io/
│       │   └── clusterdeployments/
│       └── metal3.io/
│           ├── baremetalhosts/     # BMC/power management
│           └── preprovisioningimages/
└── assisted-pods/
    ├── assisted-service-*/
    │   └── assisted-service/
    │       └── assisted-service/logs/current.log  # Main service logs
    ├── assisted-image-service-*/
    ├── metal3-baremetal-operator-*/
    │   └── metal3-baremetal-operator/
    │       └── metal3-baremetal-operator/logs/current.log
    └── metal3-*/
```

### Key Files for Debugging

- **Cluster status**: `crs/<namespace>/extensions.hive.openshift.io/agentclusterinstalls/*.yaml`
- **Host/agent status**: `crs/<namespace>/agent-install.openshift.io/agents/*.yaml`
- **Power management**: `crs/<namespace>/metal3.io/baremetalhosts/*.yaml`
- **Service logs**: `assisted-pods/assisted-service-*/assisted-service/assisted-service/logs/current.log`
- **Metal3 logs**: `assisted-pods/metal3-baremetal-operator-*/metal3-baremetal-operator/*/logs/current.log`

## Common Failure Patterns

### 1. Hosts Stuck at "Rebooting" Stage
**Symptoms:**
- Agent progress: `currentStage: Rebooting`, `installationPercentage: 55%`
- Progress info: "Ironic will reboot the node shortly"
- Host status eventually: `HostStatusInstallingPendingUserAction`
- Cluster status: Times out with "pending user action (a manual booting from installation disk)"

**Root Cause:**
- Metal3/Ironic failed to complete reboot operation
- Host didn't power cycle or didn't boot from installation disk
- BMC connectivity/credential issues

**Why it fails the cluster:**
Even 1 host stuck at rebooting causes the entire cluster to fail:
1. Host timeout → `HostStatusInstallingPendingUserAction`
2. Any host in this state → cluster moves to `ClusterStatusInstallingPendingUserAction`
3. Cluster timeout → Error state

**What to check:**
- BareMetalHost `.status.provisioning.state` and `.status.errorMessage`
- BareMetalHost `.status.poweredOn` (should cycle through false/true)
- metal3-baremetal-operator logs for power management errors
- BMC credentials and connectivity

### 2. Workers Don't Join After Installation
**Symptoms:**
- Cluster status: "Cluster is installed but some workers did not join"
- Some worker agents show 100% complete but cluster warns about missing workers

**What to check:**
- Node status in the installed cluster (if accessible)
- Certificate issues
- Network connectivity to API VIP from workers

### 3. Installation Timeout with Mixed Host States
**Symptoms:**
- Some hosts complete (100%, Done)
- Other hosts stuck at various stages
- Cluster times out

**What to check:**
- Find incomplete hosts and their specific stages
- Check if it's a host-specific issue vs systemic problem
- Look at validation failures in stuck hosts

## Useful Commands and Queries

### Quick Status Check
```bash
# Check all clusters and their status
for aci in ./path-to-data/crs/*/extensions.hive.openshift.io/agentclusterinstalls/*.yaml; do
  ns=$(basename $(dirname $(dirname $(dirname "$aci"))))
  status=$(yq eval '.status.conditions[] | select(.type == "Completed") | .status' "$aci")
  state=$(yq eval '.status.debugInfo.state' "$aci")
  echo "$ns: Status=$status, State=$state"
done
```

### Find Incomplete Hosts
```bash
NAMESPACE="<namespace>"

for agent in ./path-to-data/crs/$NAMESPACE/agent-install.openshift.io/agents/*.yaml; do
  stage=$(yq eval '.status.progress.currentStage' "$agent")
  pct=$(yq eval '.status.progress.installationPercentage' "$agent")

  if [ "$stage" != "Done" ] || [ "$pct" != "100" ]; then
    name=$(yq eval '.metadata.name' "$agent")
    hostname=$(yq eval '.status.inventory.hostname' "$agent")
    role=$(yq eval '.spec.role' "$agent")
    info=$(yq eval '.status.progress.progressInfo' "$agent")
    echo "$hostname ($role): $stage ($pct%) - $info"
  fi
done
```

### Analyze Stage Transitions
```bash
# For a specific agent, see when it got stuck
AGENT_ID="<agent-id>"

grep "$AGENT_ID" ./path-to-data/assisted-pods/assisted-service-*/assisted-service/assisted-service/logs/current.log | \
  grep -E "UpdateHostInstallProgress|UpdateStage|stage.*->.*stage" | tail -50
```

## Tips and Tricks

1. **Must-gather timing**: Logs may be rotated or incomplete if must-gather was taken days after the failure. Always check the log date range first.

2. **Use exact commit for code correlation**: The upstream-ref label ensures you're looking at the exact code that was running, not latest master.

3. **BareMetalHost last updated time**: Compare with agent stage times to see if power operations are stuck.

4. **Cluster-wide vs host-specific**: Always determine if a failure is systemic (affects all/many hosts) or isolated (one host with unique issue).

5. **Helper scripts**: Create reusable analysis scripts (like `check-aci-status.sh` and `extract-assisted-data.sh`) to speed up future investigations.
