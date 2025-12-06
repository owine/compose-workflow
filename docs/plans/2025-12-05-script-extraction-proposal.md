# Stack Removal Script Extraction Proposal

**Date:** 2025-12-05
**Status:** Proposal
**Related:** docs/plans/2025-12-03-stack-removal-detection-design.md

## Purpose

Improve code readability and maintainability of the stack removal detection and cleanup implementation by restructuring how detection and cleanup scripts are organized within the workflow.

## Background

The current implementation (PR #24) embeds two large bash scripts inline within `.github/workflows/deploy.yml`:

- **DETECT_SCRIPT** (~35 lines): Detects removed stacks via git diff
- **CLEANUP_SCRIPT** (~28 lines): Executes docker compose down for each removed stack

**Code Review Feedback**: Multiple reviewers noted that extracting these scripts would improve readability and maintainability.

**Constraint**: Earlier user feedback stated "I do not want any external scripts"

## Problem Statement

The current implementation works correctly but has readability challenges:

1. **Large YAML File**: Workflow file contains significant embedded bash logic
2. **Limited Syntax Support**: Bash scripts embedded in YAML lack full syntax highlighting
3. **Testing Difficulty**: Scripts cannot be independently tested without extracting them
4. **Code Review**: Large heredoc blocks make PR reviews harder to navigate

## Proposed Approaches

### Approach 1: External Script Files (Alternative)

**Structure**:

```text
.github/
├── scripts/
│   └── stack-removal/
│       ├── detect.sh       # Detection logic
│       └── cleanup.sh      # Cleanup logic
└── workflows/
    └── deploy.yml
```

**Pros**: Maximum code organization, independent testing, best developer experience

**Cons**: Conflicts with "I do not want any external scripts" constraint

**Recommendation**: Consider this approach if readability benefits outweigh the external scripts constraint.

---

### Approach 2: Improved Inline Structure (Primary Recommendation)

**Structure**: Keep scripts in workflow file but organize using bash functions

**Implementation Pattern**:

```yaml
- name: Detect and cleanup removed stacks
  run: |
    # Source retry functions
    source /tmp/retry.sh

    # === DETECTION FUNCTION ===
    detect_removed_stacks() {
      local current_sha="$1"
      local target_ref="$2"

      local detect_script
      read -r -d '' detect_script <<'DETECT_EOF' || true
        set -e
        CURRENT_SHA="$1"
        TARGET_REF="$2"

        cd /opt/compose

        # Fetch and validate refs
        if ! git fetch origin "$TARGET_REF" 2>/dev/null; then
          if ! git fetch 2>/dev/null; then
            echo "::error::Failed to fetch repository updates"
            exit 1
          fi
        fi

        TARGET_SHA=$(git rev-parse "$TARGET_REF" 2>/dev/null || echo "$TARGET_REF")

        if ! git cat-file -e "$CURRENT_SHA" 2>/dev/null; then
          echo "::error::Current SHA $CURRENT_SHA not found in repository"
          exit 1
        fi

        if ! git cat-file -e "$TARGET_SHA" 2>/dev/null; then
          echo "::error::Target SHA $TARGET_SHA not found in repository"
          exit 1
        fi

        # Find deleted compose.yaml files
        git diff --diff-filter=D --name-only "$CURRENT_SHA" "$TARGET_SHA" 2>/dev/null | \
          grep -E '^[^/]+/compose\.yaml$' | \
          sed 's|/compose\.yaml||' || echo ""
DETECT_EOF

      echo "$detect_script" | ssh_retry 3 5 "ssh -o \"StrictHostKeyChecking no\" deployment-server /bin/bash -s \"$current_sha\" \"$target_ref\""
    }

    # === CLEANUP FUNCTION ===
    cleanup_stack() {
      local stack="$1"
      local op_token="$2"

      local cleanup_script
      read -r -d '' cleanup_script <<'CLEANUP_EOF' || true
        STACK="$1"
        OP_TOKEN="$2"

        if [ ! -d "/opt/compose/$STACK" ]; then
          echo "⚠️ Stack directory not found for $STACK - already fully removed"
          exit 0
        fi

        cd "/opt/compose/$STACK"

        if [ ! -f compose.yaml ]; then
          echo "⚠️ compose.yaml not found for $STACK - may have been manually removed"
          exit 0
        fi

        export OP_SERVICE_ACCOUNT_TOKEN="$OP_TOKEN"
        if op run --env-file=/opt/compose/compose.env -- docker compose -f ./compose.yaml down; then
          echo "✅ Successfully cleaned up $STACK"
        else
          echo "❌ Failed to clean up $STACK"
          exit 1
        fi
CLEANUP_EOF

      echo "$cleanup_script" | ssh_retry 3 5 "ssh -o \"StrictHostKeyChecking no\" deployment-server /bin/bash -s \"$stack\" \"$op_token\""
    }

    # === MAIN EXECUTION ===
    echo "::group::Detecting removed stacks"

    CURRENT_SHA="${{ steps.backup.outputs.previous_sha }}"
    TARGET_REF="${{ inputs.target-ref }}"

    # Skip detection if first deployment
    if [ "$CURRENT_SHA" = "unknown" ]; then
      echo "ℹ️ First deployment detected - no previous stacks to remove"
      echo "removed_stacks=" >> $GITHUB_OUTPUT
      echo "has_removed_stacks=false" >> $GITHUB_OUTPUT
      echo "::endgroup::"
      exit 0
    fi

    echo "📊 Comparing commits:"
    echo "  Current: $CURRENT_SHA"
    echo "  Target:  $TARGET_REF"
    echo "🔍 Checking for removed stacks..."

    # Execute detection
    REMOVED_STACKS=$(detect_removed_stacks "$CURRENT_SHA" "$TARGET_REF")
    DETECTION_EXIT=$?

    if [ $DETECTION_EXIT -ne 0 ]; then
      echo "::error::Failed to detect removed stacks (exit code: $DETECTION_EXIT)"
      exit 1
    fi

    # Process results
    if [ -z "$REMOVED_STACKS" ]; then
      echo "✅ No stacks to remove"
      echo "removed_stacks=" >> $GITHUB_OUTPUT
      echo "has_removed_stacks=false" >> $GITHUB_OUTPUT
    else
      echo "🗑️ Found stacks to remove:"
      echo "$REMOVED_STACKS" | while read -r stack; do
        echo "  - $stack"
      done

      REMOVED_JSON=$(echo "$REMOVED_STACKS" | jq -R -s -c 'split("\n") | map(select(length > 0))')
      echo "removed_stacks=$REMOVED_JSON" >> $GITHUB_OUTPUT
      echo "has_removed_stacks=true" >> $GITHUB_OUTPUT

      # Cleanup each removed stack
      echo ""
      echo "::group::Cleaning up removed stacks"

      CLEANUP_FAILED=false
      while IFS= read -r stack; do
        [ -z "$stack" ] && continue

        echo "🧹 Cleaning up stack: $stack"

        if ! cleanup_stack "$stack" "${{ secrets.OP_SERVICE_ACCOUNT_TOKEN }}"; then
          echo "💥 Cleanup failed for stack: $stack"
          CLEANUP_FAILED=true
          break
        fi
      done <<< "$REMOVED_STACKS"

      echo "::endgroup::"

      if [ "$CLEANUP_FAILED" = "true" ]; then
        echo "::error::Stack cleanup failed - stopping deployment"
        exit 1
      fi

      echo "✅ All removed stacks cleaned successfully"
    fi
    echo "::endgroup::"
```

**Pros**:

- ✅ Respects "no external scripts" constraint
- ✅ Improved organization with functions
- ✅ Clear separation of detection and cleanup logic
- ✅ Main execution flow easier to follow
- ✅ Minimal architectural change

**Cons**:

- Still embedded in YAML (limited syntax highlighting)
- Workflow file remains large
- Scripts still cannot be independently tested without extraction

**Recommendation**: This is the **primary recommended approach** as it balances readability improvements with existing constraints.

---

## Implementation Plan (Approach 2)

### Task 1: Refactor detection logic into function

**Files**: `.github/workflows/deploy.yml`

**Changes**:

1. Extract DETECT_SCRIPT building into `detect_removed_stacks()` function
2. Function takes `current_sha` and `target_ref` as parameters
3. Returns removed stacks list to stdout
4. Maintains exact same logic as current implementation

**Validation**:

```bash
yamllint --strict .github/workflows/deploy.yml
actionlint .github/workflows/deploy.yml
```

### Task 2: Refactor cleanup logic into function

**Files**: `.github/workflows/deploy.yml`

**Changes**:

1. Extract CLEANUP_SCRIPT building into `cleanup_stack()` function
2. Function takes `stack` and `op_token` as parameters
3. Returns success/failure via exit code
4. Maintains exact same logic as current implementation

**Validation**:

```bash
yamllint --strict .github/workflows/deploy.yml
actionlint .github/workflows/deploy.yml
```

### Task 3: Refactor main execution flow

**Files**: `.github/workflows/deploy.yml`

**Changes**:

1. Extract main execution logic into clear sequential steps
2. Call `detect_removed_stacks()` function
3. Call `cleanup_stack()` function for each removed stack
4. Maintain all output variables and error handling

**Validation**:

```bash
yamllint --strict .github/workflows/deploy.yml
actionlint .github/workflows/deploy.yml
```

### Task 4: Add function documentation

**Files**: `.github/workflows/deploy.yml`

**Changes**:

1. Add comment block before each function explaining purpose
2. Document input parameters and output format
3. Reference design document

### Task 5: Validate complete refactoring

**Files**: `.github/workflows/deploy.yml`

**Validation**:

```bash
# Full workflow validation
yamllint --strict .github/workflows/deploy.yml
actionlint .github/workflows/deploy.yml

# Verify step order unchanged
grep -n "name:" .github/workflows/deploy.yml | grep -A2 -B2 "cleanup-removed"

# Verify outputs defined
grep "steps.cleanup-removed.outputs" .github/workflows/deploy.yml
```

---

## Alternative Implementation Plan (Approach 1)

If choosing external scripts instead:

### Task 1: Create script directory structure

```bash
mkdir -p .github/scripts/stack-removal
```

### Task 2: Extract detection script

**File**: `.github/scripts/stack-removal/detect.sh`

```bash
#!/usr/bin/env bash
set -e

# Stack Removal Detection Script
# Purpose: Identify removed compose.yaml files via git diff
# Usage: detect.sh <current_sha> <target_ref>

CURRENT_SHA="$1"
TARGET_REF="$2"

cd /opt/compose

# Fetch and validate refs
if ! git fetch origin "$TARGET_REF" 2>/dev/null; then
  if ! git fetch 2>/dev/null; then
    echo "::error::Failed to fetch repository updates"
    exit 1
  fi
fi

TARGET_SHA=$(git rev-parse "$TARGET_REF" 2>/dev/null || echo "$TARGET_REF")

if ! git cat-file -e "$CURRENT_SHA" 2>/dev/null; then
  echo "::error::Current SHA $CURRENT_SHA not found in repository"
  exit 1
fi

if ! git cat-file -e "$TARGET_SHA" 2>/dev/null; then
  echo "::error::Target SHA $TARGET_SHA not found in repository"
  exit 1
fi

# Find deleted compose.yaml files
git diff --diff-filter=D --name-only "$CURRENT_SHA" "$TARGET_SHA" 2>/dev/null | \
  grep -E '^[^/]+/compose\.yaml$' | \
  sed 's|/compose\.yaml||' || echo ""
```

### Task 3: Extract cleanup script

**File**: `.github/scripts/stack-removal/cleanup.sh`

```bash
#!/usr/bin/env bash
set -e

# Stack Removal Cleanup Script
# Purpose: Execute docker compose down for removed stack
# Usage: cleanup.sh <stack_name>
# Requires: OP_SERVICE_ACCOUNT_TOKEN environment variable

STACK="$1"

if [ ! -d "/opt/compose/$STACK" ]; then
  echo "⚠️ Stack directory not found for $STACK - already fully removed"
  exit 0
fi

cd "/opt/compose/$STACK"

if [ ! -f compose.yaml ]; then
  echo "⚠️ compose.yaml not found for $STACK - may have been manually removed"
  exit 0
fi

if op run --env-file=/opt/compose/compose.env -- docker compose -f ./compose.yaml down; then
  echo "✅ Successfully cleaned up $STACK"
else
  echo "❌ Failed to clean up $STACK"
  exit 1
fi
```

### Task 4: Update workflow to use external scripts

**File**: `.github/workflows/deploy.yml`

Replace inline script building with:

```yaml
# Execute detection script via ssh_retry
REMOVED_STACKS=$(cat .github/scripts/stack-removal/detect.sh | \
  ssh_retry 3 5 "ssh -o \"StrictHostKeyChecking no\" deployment-server /bin/bash -s \"$CURRENT_SHA\" \"$TARGET_REF\"")

# Execute cleanup script for each stack
export OP_SERVICE_ACCOUNT_TOKEN="${{ secrets.OP_SERVICE_ACCOUNT_TOKEN }}"
if ! cat .github/scripts/stack-removal/cleanup.sh | \
  ssh_retry 3 5 "ssh -o \"StrictHostKeyChecking no\" deployment-server /bin/bash -s \"$stack\""; then
  # error handling
fi
```

### Task 5: Add script testing

**Files**:

- `.github/scripts/stack-removal/test-detect.sh`
- `.github/scripts/stack-removal/test-cleanup.sh`

Create test scripts that can validate the external scripts locally.

---

## Security Considerations

Both approaches maintain the same security model:

1. **Secret Handling**: OP_SERVICE_ACCOUNT_TOKEN passed via environment variable (Approach 2) or exported before script execution (Approach 1)
2. **Input Validation**: Git SHAs validated via `git cat-file -e`
3. **Path Traversal Prevention**: `grep -E '^[^/]+/compose\.yaml$'` pattern limits to single-level directories
4. **Command Injection**: All variables used in heredocs with proper EOF quoting
5. **Fail-Safe**: All scripts exit on error, deployment stops on any failure

## Testing Strategy

### Approach 2 (Inline Functions)

- Workflow validation: `yamllint`, `actionlint`
- Integration testing: Deploy to test environment (docker-piwine-office)
- Edge cases: First deployment, no stacks removed, multiple stacks removed

### Approach 1 (External Scripts)

- Script validation: `shellcheck .github/scripts/stack-removal/*.sh`
- Unit testing: Test scripts locally with mock git repos
- Workflow validation: `yamllint`, `actionlint`
- Integration testing: Full deployment to test environment

## Recommendation

**Primary**: Implement **Approach 2** (Improved Inline Structure)

- Respects existing constraints
- Improves readability with minimal change
- Maintains unified code review in workflow file

**Alternative**: Consider **Approach 1** (External Scripts) if:

- Readability and testability benefits outweigh the "no external scripts" constraint
- Future plans to reuse scripts across workflows
- Team prefers shellcheck validation of standalone scripts

## Next Steps

1. **Decision**: Choose Approach 1 or Approach 2
2. **Implementation**: Follow task plan for chosen approach
3. **Validation**: Run yamllint, actionlint, and (optionally) shellcheck
4. **Testing**: Deploy to docker-piwine-office for integration testing
5. **Rollout**: Apply to production environments if successful

## Questions for Consideration

1. Does the readability improvement of external scripts justify adding separate files?
2. Is there value in being able to run shellcheck on standalone scripts?
3. Are there plans to reuse this logic in other workflows?
4. What is the team's preference for workflow organization?
