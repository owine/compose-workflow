# Stack Removal Detection and Cleanup

**Date:** 2025-12-03
**Status:** Approved
**Target:** compose-workflow deploy.yml

## Purpose

Automatically detect when Docker Compose stacks are completely removed from a repository and execute `docker compose down` to clean up running containers before the repository is updated on the deployment server.

## Problem Statement

When a stack directory (e.g., `dozzle/`) is deleted from a repository, the current deployment workflow only updates the repository with `git pull`. This leaves the deleted stack's containers running on the server with no way to manage or stop them through the normal deployment process. Operators must manually SSH to the server and run `docker compose down` in the removed stack directory.

## Requirements

1. **Automatic Detection**: Identify when stack directories are removed between deployments
2. **Clean Shutdown**: Execute `docker compose down` for removed stacks before updating repository
3. **1Password Integration**: Use `op run` to inject secrets, matching existing deployment pattern
4. **Fail-Safe Operation**: Stop entire deployment if cleanup fails for any stack
5. **Visibility**: Send separate Discord notification listing removed stacks
6. **Minimal Complexity**: Leverage existing deploy job infrastructure (SSH, variables, connections)

## Design Overview

### Architecture Decision

**Chosen Approach:** Enhance the deploy job in `compose-workflow/.github/workflows/deploy.yml`

**Rationale:**
- Deploy job already establishes SSH connection
- Current deployed SHA already captured in deploy job
- Git diff can run directly on server where both commits exist
- Cleanup must happen before `git pull` (while compose.yaml files still exist)
- Avoids adding complexity to discover-stacks job
- Reuses existing error handling and notification infrastructure

### Workflow Sequence

```
1. Deploy Job Start
   ├─ SSH to server (existing)
   ├─ Capture current SHA (existing)
   └─ Setup SSH multiplexing (existing)

2. NEW: Stack Removal Detection
   ├─ Fetch target ref on server
   ├─ Run git diff --diff-filter=D
   ├─ Filter for deleted */compose.yaml files
   └─ Build array of removed stacks

3. NEW: Cleanup Removed Stacks
   ├─ For each removed stack:
   │  ├─ docker compose down (via op run)
   │  └─ Exit on failure
   └─ Send Discord notification

4. Continue Normal Deployment (existing)
   ├─ Update repository (git pull)
   ├─ Deploy stacks
   ├─ Health checks
   └─ Final notification
```

## Implementation Details

### Detection Logic

**Location:** Deploy job, after SSH connection established, before "Update repository" step

**Script:**
```bash
# Current SHA already captured in variable: CURRENT_SHA

# Fetch and detect removed stacks on server
REMOVED_STACKS=$(ssh -o StrictHostKeyChecking=no $SSH_USER@$SSH_HOST << 'EOF'
  cd ~/docker/$REPO_NAME
  git fetch origin $TARGET_REF

  # Find deleted compose.yaml files between commits
  git diff --diff-filter=D --name-only $CURRENT_SHA $TARGET_REF | \
    grep -E '^[^/]+/compose\.yaml$' | \
    sed 's|/compose\.yaml||'
EOF
)

# Convert to array for processing
mapfile -t REMOVED_STACKS_ARRAY < <(echo "$REMOVED_STACKS")
```

**Git Diff Parameters:**
- `--diff-filter=D`: Only show deleted files
- `--name-only`: Output filenames only (no diff content)
- `$CURRENT_SHA $TARGET_REF`: Compare currently deployed vs incoming commit
- `grep -E '^[^/]+/compose\.yaml$'`: Match only top-level stack directories
- `sed 's|/compose\.yaml||'`: Extract stack name

**Output Example:**
```
dozzle
portainer
```

### Cleanup Execution

**Logic:**
```bash
# Only proceed if stacks were removed
if [ ${#REMOVED_STACKS_ARRAY[@]} -gt 0 ]; then
  echo "Found ${#REMOVED_STACKS_ARRAY[@]} stacks to remove"

  # Clean each stack sequentially
  for stack in "${REMOVED_STACKS_ARRAY[@]}"; do
    echo "Cleaning up removed stack: $stack"

    ssh -o StrictHostKeyChecking=no $SSH_USER@$SSH_HOST << EOF
      cd ~/docker/$REPO_NAME/$stack

      # Run docker compose down with 1Password secrets
      if op run --env-file="./.env" -- docker compose -f ./compose.yaml down; then
        echo "Successfully cleaned up $stack"
      else
        echo "ERROR: Failed to clean up $stack"
        exit 1
      fi
EOF

    # Check SSH command result
    if [ $? -ne 0 ]; then
      echo "Cleanup failed for $stack - stopping deployment"
      exit 1
    fi
  done
else
  echo "No stacks to remove"
fi
```

**Error Handling:**
- Sequential execution (one stack at a time)
- Immediate exit on first failure
- Deployment stops if cleanup fails
- Clear error messages indicate which stack failed

**Edge Cases Handled:**
- No stacks removed: Script outputs "No stacks to remove" and continues
- Stack directory missing: SSH cd fails, caught by error handling
- .env file missing: `op run` fails, caught by error handling
- docker compose down fails: Captured and exits with error
- Multiple stacks removed: Processes all sequentially

### Discord Notification

**Trigger:** After successful cleanup of one or more stacks

**Implementation:**
```bash
if [ ${#REMOVED_STACKS_ARRAY[@]} -gt 0 ]; then
  # Build list for notification
  REMOVED_STACKS_LIST=""
  for stack in "${REMOVED_STACKS_ARRAY[@]}"; do
    REMOVED_STACKS_LIST="${REMOVED_STACKS_LIST}- ${stack}\n"
  done

  # Get webhook URL from 1Password
  WEBHOOK_URL=$(op read "$WEBHOOK_URL_REF")

  # Send notification
  curl -X POST "$WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d @- << EOF
{
  "embeds": [{
    "title": "🗑️ Stack Cleanup - $REPO_NAME",
    "description": "Removed stacks have been cleaned up",
    "color": 16753920,
    "fields": [
      {
        "name": "Removed Stacks",
        "value": "$REMOVED_STACKS_LIST"
      },
      {
        "name": "Commit",
        "value": "$TARGET_REF"
      }
    ],
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  }]
}
EOF
fi
```

**Notification Details:**
- **Timing:** Sent immediately after cleanup, before deployment notification
- **Color:** Orange (16753920) to distinguish from success/failure notifications
- **Content:** Lists all removed stacks and target commit
- **Conditional:** Only sent if stacks were actually removed

## Security Considerations

1. **Input Validation**: Stack names from git diff are directly from git (trusted source)
2. **Path Traversal**: Grep pattern `^[^/]+/compose\.yaml$` prevents nested/complex paths
3. **Command Injection**: All variables used in heredocs with proper EOF quoting
4. **Secret Handling**: Uses `op run` pattern matching existing deployment security
5. **Fail-Safe**: Deployment stops on any cleanup failure (prevents orphaned state)

## Testing Strategy

### Manual Testing
1. Create test stack in docker-piwine
2. Deploy to ensure stack is running
3. Delete stack directory and commit
4. Trigger deployment
5. Verify:
   - Stack detected as removed
   - `docker compose down` executed
   - Discord notification sent
   - Containers stopped
   - Deployment proceeded after cleanup

### Edge Case Testing
1. **No stacks removed:** Deploy with no deletions → normal deployment
2. **Multiple stacks removed:** Delete 2+ stacks → all cleaned sequentially
3. **Cleanup failure:** Simulate docker compose down failure → deployment stops
4. **Missing .env:** Remove .env file → cleanup fails gracefully
5. **First deployment:** Deploy to empty server → no crashes on missing SHA

## Rollout Plan

1. **Implement in compose-workflow:** Add detection and cleanup logic to deploy.yml
2. **Test in docker-piwine-office:** Smallest environment, lowest risk
3. **Monitor:** Verify notifications, check for issues
4. **Roll out to docker-piwine:** Larger environment with more stacks
5. **Deploy to docker-zendc:** Production data center environment

## Success Metrics

- Zero manual SSH interventions to clean up removed stacks
- All removed stack cleanups successful (no orphaned containers)
- Clear Discord notifications showing what was cleaned
- No false positives (detecting stacks that weren't actually removed)
- Deployment failures if cleanup fails (fail-safe working)

## Future Enhancements

Potential improvements not included in initial implementation:

1. **Cleanup report:** Include list of stopped containers in notification
2. **Volume cleanup:** Option to remove volumes with `docker compose down -v`
3. **Dry-run mode:** Detect removed stacks without executing cleanup
4. **Parallel cleanup:** Clean multiple stacks simultaneously (if safe)
5. **Partial failure handling:** Continue deployment if cleanup fails but log warning

## References

- Existing deploy.yml workflow
- Current stack deployment patterns
- 1Password integration with `op run`
- SSH multiplexing configuration
- Discord webhook notification format
