# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a Claude Code skill for debugging Red Hat Assisted Installer failures using ACM (Advanced Cluster Management) must-gather archives. The skill provides a systematic workflow for analyzing installation failures, correlating them with exact source code versions, and identifying root causes.

## Prerequisites and Dependencies

Required tools for using this skill:
- `yq` - YAML processor for parsing Kubernetes resources
- `skopeo` - Container image inspection tool (for correlating failures with exact code versions)
- `jq` - JSON processor (for parsing container image labels)
- `git` - For cloning upstream repositories at specific commits

## Core Components

### Extraction and Analysis Scripts

**extract-assisted-data.sh** - Extracts relevant assisted installer resources from ACM must-gather archives:
```bash
./extract-assisted-data.sh <path-to-must-gather> <output-dir>
```

Creates a structured directory with:
- Custom resources organized by namespace/API group/resource type
- Pod logs from multicluster-engine namespace (assisted-service, infrastructure-operator)
- Pod logs from openshift-machine-api namespace (metal3 operators)

**check-aci-status.sh** - Quick status checker for all AgentClusterInstall resources:
```bash
./check-aci-status.sh <output-dir>
```

Provides a summary showing which clusters failed, succeeded, or have warnings.

### Debugging Workflow (SKILL.md)

The main workflow follows this pattern:
1. Extract data from must-gather archive
2. Identify failed clusters (check AgentClusterInstall status)
3. Investigate stuck hosts (check Agent resources)
4. Analyze logs (assisted-service and metal3 logs)
5. Cross-reference with exact source code versions
6. Document root cause

## Architecture and Key Concepts

### Must-Gather Data Structure

After extraction, data is organized as:
```
<output-dir>/
├── crs/
│   ├── cluster/                    # Cluster-scoped resources
│   │   └── agent-install.openshift.io/agentserviceconfigs/
│   └── <namespace>/                # Per-namespace resources
│       ├── agent-install.openshift.io/
│       │   ├── agents/             # Host/agent status (individual machines)
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
    ├── assisted-service-*/         # Main service logs
    ├── infrastructure-operator-*/  # Contains env vars with component image refs
    └── metal3-*/                   # Power management logs
```

### Resource Correlation

**Critical relationship**: The Agent CR name (e.g., `2d53bce4-8051-c30a-6fb1-43dc9fcf2993`) is the **host ID** used in assisted-service logs. Use this to correlate log entries with specific agent resources.

**Code version correlation**: The infrastructure-operator pod spec contains environment variables pointing to all component images (SERVICE_IMAGE, CONTROLLER_IMAGE, AGENT_IMAGE, etc.). Use `skopeo inspect` on these images to get the exact upstream git commit via the `upstream-ref` label.

### Component Repositories

| Component | Env Var in infrastructure-operator | Repository |
|-----------|-----------------------------------|------------|
| Assisted Service | `SERVICE_IMAGE` or `SERVICE_EL8_IMAGE` | https://github.com/openshift/assisted-service |
| Assisted Installer (Controller) | `CONTROLLER_IMAGE` or `INSTALLER_IMAGE` | https://github.com/openshift/assisted-installer |
| Assisted Installer Agent | `AGENT_IMAGE` | https://github.com/openshift/assisted-installer-agent |
| Assisted Image Service | `IMAGE_SERVICE_IMAGE` | https://github.com/openshift/assisted-image-service |

### State Machine Architecture

Assisted installer uses state machines for both clusters and hosts:
- **Cluster state machine**: `internal/cluster/statemachine.go` in assisted-service
- **Host state machine**: `internal/host/statemachine.go` in assisted-service

**Critical behavior**: If ANY host enters `HostStatusInstallingPendingUserAction` (e.g., stuck at rebooting), the entire cluster moves to `ClusterStatusInstallingPendingUserAction`. When the cluster timeout expires in this state, the entire installation fails even if other hosts are healthy.

## Common Debugging Patterns

### Finding Failed Clusters

AgentClusterInstall status indicates overall cluster health:
- `.status.conditions[] | select(.type == "Completed") | .status` - "False" means failed
- `.status.debugInfo.state` - Current state
- `.status.debugInfo.stateInfo` - Human-readable status

### Finding Stuck Hosts

Agent resources show individual host progress:
- `.status.progress.currentStage` - Should be "Done" when complete
- `.status.progress.installationPercentage` - Should be 100 when complete
- `.metadata.labels."agent-install.openshift.io/bmh"` - Links to BareMetalHost for power management

### Common Failure Modes

**Hosts stuck at "Rebooting"**:
- Agent shows: `currentStage: Rebooting`, `installationPercentage: 55%`
- Root cause: Metal3/Ironic failed to complete reboot operation
- Check: BareMetalHost `.status.provisioning.state` and metal3 logs
- Impact: Even 1 stuck host fails the entire cluster

**Workers don't join**:
- Cluster status: "Cluster is installed but some workers did not join"
- Some workers show 100% complete but cluster warns about missing workers
- Check: Network connectivity to API VIP, certificate issues

### Log Analysis

Must-gather logs may be rotated or incomplete if collected days after failure. Always check log date range first:
```bash
head -1 "$LOG_FILE"  # Log start time
tail -1 "$LOG_FILE"  # Log end time
```

Search logs using host ID (Agent CR name):
```bash
grep "$AGENT_ID" "$ASSISTED_SERVICE_LOG" | grep -E "error|reboot|installing"
```

## Code Cross-Reference Workflow

To understand why a failure occurred (not just what failed):

1. Extract component image from infrastructure-operator pod spec
2. Use `skopeo inspect "docker://$IMAGE"` to get `upstream-ref` label
3. Clone repository and checkout exact commit
4. Search for error messages, state transitions, or timeout values in code

Example:
```bash
IMAGE=$(yq eval '.spec.containers[] | select(.name == "manager") | .env[] | select(.name == "SERVICE_IMAGE") | .value' "$INFRA_OP_YAML")
UPSTREAM_REF=$(skopeo inspect "docker://$IMAGE" | jq -r '.Labels."upstream-ref"')
git clone https://github.com/openshift/assisted-service
cd assisted-service
git checkout "$UPSTREAM_REF"
grep -r "error message from logs" --include="*.go"
```

## Working with the Skill

This skill is designed to be invoked when debugging ACM must-gather archives. The SKILL.md file contains the complete step-by-step workflow. When using the skill:

1. Start by extracting the must-gather data
2. Get a high-level overview of cluster status
3. Drill down into failed clusters
4. Cross-reference with exact code versions
5. Document findings (potentially create Jira tickets using jira-cli)

The skill includes domain knowledge about:
- Typical failure patterns (timeout vs genuine failure)
- State machine transitions
- Power management issues
- Log correlation techniques
