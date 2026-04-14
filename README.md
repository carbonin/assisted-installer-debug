# Assisted Installer Must-Gather Debug Skill

A Claude Code skill for debugging customer issues with Red Hat's Assisted Installer using ACM must-gather archives.

## Overview

This skill helps identify and investigate installation failures in assisted installer deployments managed by ACM (Advanced Cluster Management). It provides a systematic workflow for analyzing must-gather archives, correlating failures with source code, and understanding root causes.

## Contents

- **SKILL.md** - Complete debugging workflow documentation
- **extract-assisted-data.sh** - Extracts relevant assisted installer resources from ACM must-gather archives
- **check-aci-status.sh** - Quick status checker for all AgentClusterInstalls

## Quick Start

### 1. Extract Data from Must-Gather

```bash
./extract-assisted-data.sh <path-to-must-gather> <output-dir>
```

This creates a structured directory with:
- Custom resources (AgentClusterInstalls, Agents, BareMetalHosts, etc.)
- Pod logs from assisted-service and metal3 operators

### 2. Check Cluster Status

```bash
./check-aci-status.sh <output-dir>
```

Provides a summary of all cluster installations and highlights failures.

### 3. Debug with Claude Code

Use the SKILL.md workflow to:
- Identify failed clusters and stuck hosts
- Analyze logs and resource states
- Cross-reference with exact source code versions
- Understand the root cause

## Prerequisites

- `yq` - YAML processor
- `skopeo` - Container image inspection (for code correlation)
- `jq` - JSON processor (for parsing image labels)
- `git` - For cloning upstream repositories

## Common Issues Debugged

- Installation timeouts
- Hosts stuck at specific stages (e.g., "Rebooting")
- Power management/BMC failures
- Network connectivity issues
- Worker nodes not joining cluster

## Example Workflow

```bash
# Extract the must-gather
./extract-assisted-data.sh ~/Downloads/must-gather.tar.gz ./debug-data

# Check status
./check-aci-status.sh ./debug-data

# Output shows sympod01 cluster failed
# Follow SKILL.md to investigate:
# - Check agent status
# - Find stuck hosts
# - Analyze logs
# - Cross-reference with code
```

## Development

This skill was developed through a real debugging session, documenting the process of investigating a cluster installation failure where 3 workers stuck at "Rebooting" caused the entire 90-worker cluster to timeout.
