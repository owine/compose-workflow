# Enhanced Stack Removal Detection Design

**Date**: 2025-12-06
**Status**: Proposed
**Supersedes**: 2025-12-03-stack-removal-detection-design.md

## Overview

This design enhances the existing stack removal detection system by adding two additional detection methods to catch edge cases where stacks were removed in previous commits that never deployed (e.g., due to lint failures). The enhanced system uses three independent detection methods with union-based aggregation for maximum coverage.

## Problem Statement

The current stack removal detection (implemented in 2025-12-03) uses `git diff` to compare the current deployed SHA with the target SHA. This approach has a limitation:

**Edge Case**: If a stack was removed in a previous commit that was never deployed (due to lint failure, failed deployment, etc.), the git diff between the current deployed SHA and the new target SHA will not detect the removal, because both commits already lack the stack.

**Example Scenario**:
1. Deployed SHA is `abc123` with stacks: `[portainer, dozzle, services]`
2. Commit `def456` removes `services` stack but fails linting
3. Commit `ghi789` (target) fixes the lint issue
4. Git diff between `abc123` (deployed) and `ghi789` (target) shows no `services` removal
5. `services` stack remains on server as orphaned containers

## Solution: Three-Method Detection with Union Aggregation

### Architecture

**Three Independent Detection Methods:**

1. **Git Diff Detection** (existing, refactored)
   - Compares current deployed SHA vs target SHA
   - Detects removals in the current deployment
   - Runs on deployment server via SSH

2. **Tree Comparison Detection** (new)
   - Compares target commit tree structure vs server filesystem
   - Detects stacks present on server but missing from target commit
   - Catches removals from previous undeployed commits
   - Runs on deployment server via SSH

3. **Discovery Analysis Detection** (new)
   - Analyzes changed files from `tj-actions/changed-files` action
   - Validates removal detection from GitHub's perspective
   - Provides robust change detection with edge case handling
   - Runs on deployment server (analyzes GitHub runner output)

**Aggregation Strategy:**
- **Union approach**: Remove stacks found by ANY detection method
- **Deduplication**: Merge all three lists and remove duplicates
- **Fail-safe**: If ANY detection method fails, fail the entire deployment

### Function Design

#### Function 1: `detect_removed_stacks_gitdiff()`

**Purpose**: Detect stacks removed between two git commits (existing logic, refactored)

**Inputs**:
- `$1`: current_sha (deployed commit)
- `$2`: target_ref (target commit to deploy)

**Logic**:
```bash
detect_removed_stacks_gitdiff() {
  local current_sha="$1"
  local target_ref="$2"

  # Execute on server via SSH heredoc
  cd /opt/compose
  git fetch origin "$target_ref"
  TARGET_SHA=$(git rev-parse "$target_ref")

  # Find deleted compose.yaml files
  git diff --diff-filter=D --name-only "$current_sha" "$TARGET_SHA" | \
    grep -E '^[^/]+/compose\.yaml$' | \
    sed 's|/compose\.yaml||'
}
```

**Output**: Newline-separated stack names (e.g., `portainer\nservices`)

**Error Handling**: Exit 1 on git errors, SHA validation failures

#### Function 2: `detect_removed_stacks_tree()` (NEW)

**Purpose**: Detect stacks on server filesystem missing from target commit tree

**Inputs**:
- `$1`: target_ref (target commit to deploy)

**Logic**:
```bash
detect_removed_stacks_tree() {
  local target_ref="$1"

  # Execute on server via SSH heredoc
  cd /opt/compose
  git fetch origin "$target_ref"
  TARGET_SHA=$(git rev-parse "$target_ref")

  # Get directories in target commit (one level deep)
  COMMIT_DIRS=$(git ls-tree --name-only "$TARGET_SHA" | sort)

  # Get directories on server filesystem
  SERVER_DIRS=$(find /opt/compose -maxdepth 1 -mindepth 1 -type d -exec basename {} \; | sort)

  # Find dirs on server but not in commit
  MISSING_IN_COMMIT=$(comm -13 <(echo "$COMMIT_DIRS") <(echo "$SERVER_DIRS"))

  # Filter for directories with compose.yaml files
  for dir in $MISSING_IN_COMMIT; do
    if [ -f "/opt/compose/$dir/compose.yaml" ]; then
      echo "$dir"
    fi
  done
}
```

**Output**: Newline-separated stack names

**Error Handling**: Exit 1 on git errors, filesystem access failures

#### Function 3: `detect_removed_stacks_discovery()` (NEW)

**Purpose**: Analyze deleted files from tj-actions/changed-files output

**Inputs**:
- `$1`: deleted_files_json (JSON array from tj-actions/changed-files)

**Logic**:
```bash
detect_removed_stacks_discovery() {
  local deleted_files_json="$1"

  # Parse JSON array and filter for compose.yaml deletions
  echo "$deleted_files_json" | jq -r '.[]' | \
    grep -E '^[^/]+/compose\.yaml$' | \
    sed 's|/compose\.yaml||'
}
```

**Output**: Newline-separated stack names

**Error Handling**: Exit 1 on JSON parse errors, jq failures

#### Function 4: `aggregate_removed_stacks()`

**Purpose**: Merge and deduplicate results from all three detection methods

**Inputs**:
- `$1`: gitdiff_stacks (newline-separated list)
- `$2`: tree_stacks (newline-separated list)
- `$3`: discovery_stacks (newline-separated list)

**Logic**:
```bash
aggregate_removed_stacks() {
  local gitdiff_stacks="$1"
  local tree_stacks="$2"
  local discovery_stacks="$3"

  # Concatenate all three lists
  {
    echo "$gitdiff_stacks"
    echo "$tree_stacks"
    echo "$discovery_stacks"
  } | \
    grep -v '^$' | \
    sort -u | \
    grep -E '^[a-zA-Z0-9_-]+$'  # Validate safe characters
}
```

**Output**: Deduplicated newline-separated stack names

**Error Handling**: Returns empty string (not error) if all inputs are empty

## Integration Points

### Changes to `discover-stacks` Step

Add `tj-actions/changed-files@v47` action to capture changed files:

```yaml
- name: Get changed files
  id: changed-files
  uses: tj-actions/changed-files@v47
  with:
    json: true
    sha: ${{ steps.backup.outputs.previous_sha }}
    base_sha: ${{ inputs.target-ref }}

- name: Output changed files for removal detection
  run: |
    echo "deleted_files=${{ steps.changed-files.outputs.deleted_files }}" >> "$GITHUB_OUTPUT"
```

**Outputs**:
- `deleted_files`: JSON array of deleted files between deployed and target commits

### Changes to `cleanup-removed` Step

Update main execution logic to run all three detection methods:

```yaml
- name: Detect and clean up removed stacks
  id: cleanup-removed
  run: |
    # Read deleted files from discover-stacks step
    DELETED_FILES='${{ steps.discover-stacks.outputs.deleted_files }}'

    # Run all three detection methods (via SSH on server)
    GITDIFF_STACKS=$(detect_removed_stacks_gitdiff "$CURRENT_SHA" "$TARGET_REF") || GITDIFF_EXIT=$?
    TREE_STACKS=$(detect_removed_stacks_tree "$TARGET_REF") || TREE_EXIT=$?
    DISCOVERY_STACKS=$(detect_removed_stacks_discovery "$DELETED_FILES") || DISCOVERY_EXIT=$?

    # Fail deployment if any detection method failed
    if [ "${GITDIFF_EXIT:-0}" -ne 0 ]; then
      echo "::error::Git diff detection failed (exit code: $GITDIFF_EXIT)"
      exit 1
    fi
    if [ "${TREE_EXIT:-0}" -ne 0 ]; then
      echo "::error::Tree comparison detection failed (exit code: $TREE_EXIT)"
      exit 1
    fi
    if [ "${DISCOVERY_EXIT:-0}" -ne 0 ]; then
      echo "::error::Discovery analysis detection failed (exit code: $DISCOVERY_EXIT)"
      exit 1
    fi

    # Aggregate results (union of all three methods)
    REMOVED_STACKS=$(aggregate_removed_stacks "$GITDIFF_STACKS" "$TREE_STACKS" "$DISCOVERY_STACKS")

    # Continue with cleanup as before...
```

## Data Flow

```
1. discover-stacks step (GitHub runner)
   ├─ tj-actions/changed-files@v47
   │  ↓ outputs: deleted_files (JSON array)
   └─ discover stacks to deploy

2. cleanup-removed step (reads discover-stacks outputs)
   ↓ executes detection on deployment server via SSH

3. Three detection methods (all on server)
   ├─ detect_removed_stacks_gitdiff()     → list A
   ├─ detect_removed_stacks_tree()        → list B
   └─ detect_removed_stacks_discovery()   → list C
   ↓ execute via SSH heredoc

4. aggregate_removed_stacks(A, B, C)
   ↓ merge, deduplicate, validate

5. For each removed stack
   ↓ cleanup_stack() via docker compose down

6. Discord notification with removed stacks
```

## Error Handling

### Detection Failures

**Strategy**: Fail the entire deployment if ANY detection method encounters an error

**Rationale**:
- Conservative approach prevents partial/incomplete cleanups
- Ensures all detection methods are working correctly
- Prevents edge cases where one method fails silently

**Implementation**:
- Each detection function returns exit code (0 = success, 1 = error)
- Main execution captures exit codes for all three methods
- If any exit code ≠ 0, log which method failed and exit 1
- Do NOT proceed with partial results

### Edge Cases

1. **First deployment** (no previous SHA)
   - Skip all detection methods
   - Output: `removed_stacks=`, `has_removed_stacks=false`

2. **Empty detection** (no removals found)
   - All three methods return empty lists
   - Aggregation returns empty string
   - Skip cleanup, proceed with deployment

3. **Stack renamed** (deleted + added)
   - Detection flags as removed
   - Cleanup attempts `docker compose down`
   - If compose.yaml doesn't exist, cleanup fails
   - Deployment fails (fail-safe prevents accidental removal of renamed stacks)

4. **Filesystem vs git mismatch**
   - Tree comparison detects mismatch
   - Git diff may not detect (depends on commits)
   - Union approach ensures cleanup happens

## Testing Strategy

### Unit Testing

Create `scripts/testing/test-removal-detection.sh` with test scenarios:

```bash
#!/bin/bash
# Test individual detection functions

test_gitdiff_detection() {
  # Create test commits with stack removals
  # Verify gitdiff detection outputs correct stacks
}

test_tree_detection() {
  # Create filesystem directories without corresponding commits
  # Verify tree detection outputs orphaned stacks
}

test_discovery_detection() {
  # Mock tj-actions/changed-files JSON output
  # Verify discovery detection parses correctly
}

test_aggregation() {
  # Test with known inputs from all three methods
  # Verify deduplication and sorting
}

test_error_handling() {
  # Simulate git failures, filesystem access errors
  # Verify exit codes propagate correctly
}
```

### Integration Testing

Test complete workflow with real scenarios:

1. **Normal removal**: Stack deleted in current commit
2. **Undeployed removal**: Stack deleted 3 commits ago, never deployed
3. **Multiple removals**: Stacks deleted across different commits
4. **No removals**: All detection methods return empty
5. **Detection failure**: Simulate git error, verify deployment fails

### Test Scenarios Coverage

| Scenario | Git Diff | Tree Compare | Discovery | Expected Result |
|----------|----------|--------------|-----------|-----------------|
| Stack removed in current commit | ✓ Detects | ✓ Detects | ✓ Detects | Stack cleaned |
| Stack removed in undeployed commit | ✗ Misses | ✓ Detects | ✗ Misses | Stack cleaned (tree catches it) |
| Multiple stacks, various commits | ✓ Some | ✓ All | ✓ Some | All stacks cleaned (union) |
| Stack renamed | ✓ Detects deletion | ✓ Detects old | ✓ Detects deletion | Cleanup fails safely |
| No removals | ✗ Nothing | ✗ Nothing | ✗ Nothing | Skip cleanup |
| Git error on server | ✗ Fails | N/A | N/A | Deployment fails |

## Benefits

1. **Comprehensive Coverage**: Three detection methods catch different edge cases
2. **Fail-Safe Operation**: Any detection failure stops deployment
3. **Union Approach**: Maximizes cleanup coverage (remove anything flagged by any method)
4. **Backward Compatible**: Existing git diff logic preserved, enhanced with new methods
5. **Independent Testing**: Each detection method testable in isolation
6. **Easier Debugging**: Clear logging shows which method detected which stacks
7. **Robust Change Detection**: tj-actions/changed-files handles GitHub edge cases
8. **Server Validation**: Server-side git diff validates from deployment perspective

## Migration Path

1. **Phase 1**: Implement new detection functions alongside existing logic
2. **Phase 2**: Add tj-actions/changed-files to discover-stacks step
3. **Phase 3**: Update cleanup-removed step to use aggregation
4. **Phase 4**: Deploy to test repository (docker-piwine-office)
5. **Phase 5**: Monitor for one week, validate detection accuracy
6. **Phase 6**: Roll out to production repositories (docker-piwine, docker-zendc)

## Future Enhancements

1. **Dry-run mode**: Flag `--dry-run` to show what would be removed without cleanup
2. **Manual override**: Input parameter to skip removal detection if needed
3. **Cleanup metrics**: Track how often each detection method finds stacks
4. **Notification enhancement**: Show which detection method found each stack

## References

- Original design: `2025-12-03-stack-removal-detection-design.md`
- Cleanup implementation: `2025-12-04-stack-removal-cleanup.md`
- tj-actions/changed-files: https://github.com/tj-actions/changed-files
- Git diff documentation: https://git-scm.com/docs/git-diff
- Git ls-tree documentation: https://git-scm.com/docs/git-ls-tree
