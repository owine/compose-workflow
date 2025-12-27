# Deployment Script Extraction - Implementation Guide

## Status: Phase 6 Complete ✅ - REFACTOR FINISHED

- Phase 1: Foundation library created and committed (b2effaa, 41a80ed)
- Phase 2: Health check extraction complete (f6ae6d1, c60ce75) - EXPRESSION LIMIT FIXED ✅
- Phase 3: Deployment extraction complete (63871ac, 72cd05f) - Further workflow simplification ✅
- Phase 4: Stack removal detection complete (15a1cc0, 7b3e28e) - Modular detection and cleanup ✅
- Phase 5: Rollback extraction complete (70ae188, d124d60) - Workflow now 851 lines (67% reduction) ✅
- Phase 6: Cleanup and validation complete - Workflow now 783 lines (69% reduction) ✅

## Problem Statement

The deploy workflow `.github/workflows/deploy.yml` exceeds GitHub Actions expression length limit:
- Health check heredoc: **24,812 characters** (limit: 21,000)
- Workflow is 2,548 lines and hard to maintain
- All logic is inline in workflow file

## Solution

Extract large inline scripts to separate files in `scripts/deployment/`. Scripts run on GitHub Actions runner and make SSH calls to remote server as needed.

---

## Completed: Phase 1 - Library Infrastructure ✅

Created foundation libraries:

### `scripts/deployment/lib/ssh-helpers.sh`
- `retry()`: General retry with exponential backoff
- `ssh_retry()`: SSH-specific retry with error handling
- `ssh_exec()`: Simple SSH execution wrapper

### `scripts/deployment/lib/common.sh`
- `log_info()`, `log_success()`, `log_error()`, `log_warning()`: Colored logging
- `set_github_output()`: Set GitHub Actions outputs
- `validate_stack_name()`, `validate_sha()`, `validate_op_reference()`: Input validation
- `format_list()`, `require_var()`: Helper utilities

---

## Remaining Phases

### Phase 2: Extract Health Check Script (PRIORITY)

**Goal**: Reduce heredoc from 24,812 → under 1,000 chars

**Steps**:

1. **Create `scripts/deployment/health-check.sh`**
   - Extract lines 1249-1713 from deploy.yml
   - Add shebang and set -euo pipefail
   - Source libraries:
     ```bash
     SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
     source "$SCRIPT_DIR/lib/ssh-helpers.sh"
     source "$SCRIPT_DIR/lib/common.sh"
     ```
   - Add argument parsing (use getopts):
     - `--stacks`: Space-separated stack names
     - `--has-dockge`: true/false
     - `--ssh-user`: SSH username
     - `--ssh-host`: SSH hostname
     - `--op-token`: 1Password service account token
     - `--health-timeout`: Overall timeout (default: 180)
     - `--command-timeout`: Command timeout (default: 15)
   - Keep entire remote heredoc inline (move from workflow to script)
   - Execute via `ssh_retry 3 5 "ssh ... /bin/bash -s $STACKS \"$HAS_DOCKGE\"" << 'EOF'`
   - Parse output and write structured results to stdout
   - Make executable: `chmod +x scripts/deployment/health-check.sh`

2. **Update workflow step "Health Check All Services"** (line ~1232)
   - Replace entire heredoc with:
     ```yaml
     - name: Health Check All Services
       id: health
       if: steps.backup.outputs.deployment_needed == 'true' && steps.deploy.outcome == 'success'
       run: |
         ./scripts/deployment/health-check.sh \
           --stacks "${{ join(fromJSON(inputs.stacks), ' ') }}" \
           --has-dockge "${{ inputs.has-dockge }}" \
           --ssh-user "${{ secrets.SSH_USER }}" \
           --ssh-host "${{ secrets.SSH_HOST }}" \
           --op-token "${{ secrets.OP_SERVICE_ACCOUNT_TOKEN }}" \
           --health-timeout "${{ inputs.health-check-timeout }}" \
           --command-timeout "${{ inputs.health-check-command-timeout }}"
     ```
   - Script outputs variables that are captured and set as GitHub outputs

3. **Test health check works correctly**
   - Validate stack-specific service counting
   - Verify Docker health status parsing (healthy/starting/unhealthy)
   - Test Dockge health check if enabled

---

### Phase 3: Extract Deployment Script

**Goal**: Simplify deployment step

1. **Create `scripts/deployment/deploy-stacks.sh`**
   - Extract lines 892-1230 from deploy.yml
   - Arguments: --stacks, --has-dockge, --target-ref, --compose-args, --ssh-user, --ssh-host, --op-token, timeouts
   - Keep deployment heredoc (parallel execution logic)
   - Output: DEPLOY_STATUS=success|failure

2. **Update workflow step "Deploy Changes"** (line ~870)
   - Replace heredoc with script call
   - Pass all parameters
   - Capture output

---

### Phase 4: Extract Stack Removal Detection

**Goal**: Simplify removal detection step

1. **Create `scripts/deployment/detect-removed-stacks.sh`**
   - Extract lines 492-828 from deploy.yml
   - Three detection methods (gitdiff, tree, discovery)
   - Arguments: --current-sha, --target-ref, --deleted-files, --ssh-user, --ssh-host, --op-token
   - Output: REMOVED_STACKS="stack1 stack2", HAS_REMOVED_STACKS=true|false

2. **Create `scripts/deployment/cleanup-stack.sh`** (helper)
   - Single stack cleanup
   - Arguments: stack-name, --ssh-user, --ssh-host, --op-token
   - Called by detect-removed-stacks.sh in loop

3. **Update workflow step "Detect and clean up removed stacks"**

---

### Phase 5: Extract Rollback Script

1. **Create `scripts/deployment/rollback-stacks.sh`**
   - Extract lines 1750-2186 from deploy.yml
   - Arguments: --previous-sha, --has-dockge, --compose-args, --critical-services, --ssh-user, --ssh-host, --op-token
   - Output: ROLLBACK_STATUS, DISCOVERED_ROLLBACK_STACKS

2. **Update workflow step "Rollback on Health Check Failure"**

3. **Update "Verify Rollback Health" step**
   - Can reuse health-check.sh with different context

---

### Phase 6: Cleanup and Validation

1. **Remove retry.sh creation step** (lines 243-311)
   - All scripts now source lib/ssh-helpers.sh

2. **Validate workflow syntax**
   ```bash
   actionlint .github/workflows/deploy.yml
   ```

3. **Check expression limits**
   - Verify all heredocs < 21,000 chars
   - Workflow should be ~600-800 lines (down from 2,548)

4. **Test end-to-end**
   - Deploy to test environment
   - Verify health checks work
   - Test rollback scenario
   - Test stack removal

5. **Update documentation**
   - Update CLAUDE.md with script structure
   - Document script usage

---

## Script Template

Here's the basic structure for each deployment script:

```bash
#!/usr/bin/env bash
# Script Name: <name>.sh
# Purpose: <description>
# Usage: ./<name>.sh --arg1 value1 --arg2 value2

set -euo pipefail

# Get script directory and source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/ssh-helpers.sh"
source "$SCRIPT_DIR/lib/common.sh"

# Default values
SSH_USER=""
SSH_HOST=""
OP_TOKEN=""
# ... other defaults

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --ssh-user)
      SSH_USER="$2"
      shift 2
      ;;
    --ssh-host)
      SSH_HOST="$2"
      shift 2
      ;;
    --op-token)
      OP_TOKEN="$2"
      shift 2
      ;;
    *)
      log_error "Unknown argument: $1"
      exit 1
      ;;
  esac
done

# Validate required arguments
require_var SSH_USER || exit 1
require_var SSH_HOST || exit 1
require_var OP_TOKEN || exit 1

# Main logic
log_info "Starting <operation>..."

# Execute remote script via SSH
RESULT=$(ssh_retry 3 5 "ssh -o \"StrictHostKeyChecking no\" $SSH_USER@$SSH_HOST /bin/bash -s" << 'EOF'
  set -e

  # Remote script logic here
  export OP_SERVICE_ACCOUNT_TOKEN="$OP_TOKEN_FROM_ENV"

  # ... do work ...

  # Output structured results
  echo "STATUS=success"
  echo "RESULT=value"
EOF
)

# Parse results
eval "$RESULT"

# Output for GitHub Actions
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "status=$STATUS" >> "$GITHUB_OUTPUT"
  echo "result=$RESULT" >> "$GITHUB_OUTPUT"
fi

# Also output to stdout for workflow capture
echo "STATUS=$STATUS"
echo "RESULT=$RESULT"

log_success "Operation completed successfully"
exit 0
```

---

## Testing Strategy

### Local Testing
```bash
# Make scripts executable
chmod +x scripts/deployment/*.sh

# Test with mock SSH (optional)
SSH_USER=test SSH_HOST=test ./scripts/deployment/health-check.sh \
  --stacks "stack1 stack2" \
  --has-dockge true \
  --op-token "test-token"
```

### Integration Testing
1. Create test branch
2. Update workflow to use scripts
3. Deploy to test environment (docker-piwine-office)
4. Monitor Discord notifications
5. Verify all functionality works

---

## Key Considerations

### Secret Handling
- Secrets passed via command-line args (secure on runner)
- Remote execution injects secrets via heredoc environment
- Never log secrets or write to files

### Error Handling
- Scripts exit non-zero on error
- Workflow handles errors appropriately
- Rollback triggers on health check failure

### Backward Compatibility
- All workflow inputs/outputs unchanged
- Calling repositories require no changes
- Behavior identical to current implementation

---

## Final Impact

### Before Refactor
- Workflow: 2,548 lines, 122,564 bytes
- Health check heredoc: 24,812 chars ❌ EXCEEDS LIMIT
- Maintainability: Low (all inline)
- All logic embedded in workflow

### After Phase 6 (Final State) ✅
- Workflow: **783 lines** ✅ **69% REDUCTION**
- Largest heredoc: <100 chars ✅ WELL UNDER LIMIT
- Maintainability: **High** (modular scripts)
- Reusability: Scripts can be used elsewhere
- Testability: Scripts testable independently
- Code organization: Clean separation of concerns

### Modular Scripts Created
1. `lib/ssh-helpers.sh` - Retry mechanisms (68 lines)
2. `lib/common.sh` - Utilities and validation (86 lines)
3. `health-check.sh` - Health verification (584 lines)
4. `deploy-stacks.sh` - Deployment orchestration (690 lines)
5. `detect-removed-stacks.sh` - Stack removal detection (328 lines)
6. `cleanup-stack.sh` - Individual stack cleanup (87 lines)
7. `rollback-stacks.sh` - Rollback automation (495 lines)

---

## Quick Start for Next Session

To continue this refactor:

1. **Start with health check** (highest priority, biggest impact):
   ```bash
   # Create the script
   touch scripts/deployment/health-check.sh
   chmod +x scripts/deployment/health-check.sh

   # Copy lines 1249-1713 from deploy.yml
   # Add argument parsing
   # Source libraries
   # Test locally
   ```

2. **Update workflow** to call script instead of inline heredoc

3. **Test** with real deployment

4. **Repeat** for other scripts (deploy, rollback, detection)

---

## Checklist

- [x] Phase 1: Library infrastructure
- [x] Phase 2: Health check extraction ✅ **EXPRESSION LIMIT FIXED**
- [x] Phase 3: Deployment extraction ✅ **WORKFLOW SIMPLIFIED**
- [x] Phase 4: Stack removal extraction ✅ **MODULAR DETECTION**
- [x] Phase 5: Rollback extraction ✅ **ROLLBACK MODULARIZED**
- [x] Phase 6: Cleanup and validation ✅ **REFACTOR COMPLETE**

---

## References

- **Plan Agent Output**: See `agentId: a1b1095` for full implementation plan
- **Current Workflow**: `.github/workflows/deploy.yml` (line 1214 exceeds limit)
- **Foundation Commit**: `b2effaa` (Phase 1 complete)
- **Problem Commit**: `761015b` (health check verification added, exceeded limit)

---

## Need Help?

If you get stuck:
1. Review the Plan agent output (comprehensive design doc)
2. Look at existing inline scripts in deploy.yml
3. Follow the script template above
4. Test incrementally (one script at a time)
5. Use `actionlint` to validate workflow syntax

The refactor is systematic and can be done incrementally. Start with health check (biggest win), then move to others.
