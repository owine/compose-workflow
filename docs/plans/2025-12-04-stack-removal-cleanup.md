# Stack Removal Detection and Cleanup Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Automatically detect and clean up Docker Compose stacks that have been removed from the repository before deployment.

**Architecture:** Add a new workflow step between "Store current deployment for rollback" and "Deploy All Stacks" that uses git diff to detect deleted compose.yaml files, runs docker compose down for each removed stack, and sends a Discord notification. Fail deployment if any cleanup fails.

**Tech Stack:** GitHub Actions, Bash, git diff, Docker Compose, 1Password CLI, Discord webhooks

---

## Task 1: Add detection step to workflow

**Files:**
- Modify: `.github/workflows/deploy.yml:414-416`

**Step 1: Validate current workflow structure**

Run: `yamllint --strict .github/workflows/deploy.yml`
Expected: PASS (workflow is currently valid)

**Step 2: Add new step after "Store current deployment for rollback"**

Insert after line 414 (after the backup step closes) and before line 416 (before "Deploy All Stacks"):

```yaml
      - name: Detect and cleanup removed stacks
        id: cleanup-removed
        if: steps.backup.outputs.deployment_needed == 'true'
        continue-on-error: false
        run: |
          echo "::group::Detecting removed stacks"
          # Source retry functions
          source /tmp/retry.sh

          # Get current and target SHA from backup step
          CURRENT_SHA="${{ steps.backup.outputs.previous_sha }}"
          TARGET_REF="${{ inputs.target-ref }}"

          echo "📊 Comparing commits:"
          echo "  Current: $CURRENT_SHA"
          echo "  Target:  $TARGET_REF"

          # Detect removed stacks on the server
          echo "🔍 Checking for removed stacks..."

          REMOVED_STACKS=$(ssh_retry 3 5 "ssh -o 'StrictHostKeyChecking no' deployment-server" << 'DETECT_EOF'
            cd /opt/compose

            # Fetch target ref to ensure we have it
            git fetch origin $TARGET_REF 2>/dev/null || git fetch 2>/dev/null

            # Find deleted compose.yaml files between current and target
            git diff --diff-filter=D --name-only $CURRENT_SHA $TARGET_REF 2>/dev/null | \
              grep -E '^[^/]+/compose\.yaml$' | \
              sed 's|/compose\.yaml||' || echo ""
DETECT_EOF
          )

          # Store removed stacks for later steps
          if [ -z "$REMOVED_STACKS" ]; then
            echo "✅ No stacks to remove"
            echo "removed_stacks=" >> $GITHUB_OUTPUT
            echo "has_removed_stacks=false" >> $GITHUB_OUTPUT
          else
            echo "🗑️ Found stacks to remove:"
            echo "$REMOVED_STACKS" | while read -r stack; do
              echo "  - $stack"
            done

            # Convert to JSON array for output
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

              if ! ssh_retry 3 5 "ssh -o 'StrictHostKeyChecking no' deployment-server" << CLEANUP_EOF
                cd /opt/compose/$stack

                # Check if compose.yaml exists
                if [ ! -f compose.yaml ]; then
                  echo "⚠️ compose.yaml not found for $stack - may have been manually removed"
                  exit 0
                fi

                # Run docker compose down with 1Password
                export OP_SERVICE_ACCOUNT_TOKEN="${{ secrets.OP_SERVICE_ACCOUNT_TOKEN }}"
                if op run --env-file=/opt/compose/compose.env -- docker compose -f ./compose.yaml down; then
                  echo "✅ Successfully cleaned up $stack"
                else
                  echo "❌ Failed to clean up $stack"
                  exit 1
                fi
CLEANUP_EOF
              then
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

**Step 3: Validate YAML syntax**

Run: `yamllint --strict .github/workflows/deploy.yml`
Expected: PASS (new step is valid YAML)

**Step 4: Validate with actionlint**

Run: `actionlint .github/workflows/deploy.yml`
Expected: PASS (workflow logic is valid)

**Step 5: Commit**

```bash
git add .github/workflows/deploy.yml
git commit -m "feat: add stack removal detection and cleanup step

Detect removed stacks using git diff and clean up with docker compose down
before repository update. Fail deployment if cleanup fails."
```

---

## Task 2: Add Discord notification for removed stacks

**Files:**
- Modify: `.github/workflows/deploy.yml` (after cleanup step, before Deploy All Stacks)

**Step 1: Add notification step after cleanup**

Insert after the cleanup step (new step from Task 1) and before "Deploy All Stacks":

```yaml
      - name: Notify removed stacks cleanup
        if: steps.cleanup-removed.outputs.has_removed_stacks == 'true'
        run: |
          echo "📢 Sending cleanup notification to Discord..."

          # Get webhook URL from 1Password
          WEBHOOK_URL=$(op read "${{ inputs.webhook-url }}")

          # Build removed stacks list
          REMOVED_STACKS='${{ steps.cleanup-removed.outputs.removed_stacks }}'
          STACK_LIST=$(echo "$REMOVED_STACKS" | jq -r '.[] | "- " + .')

          # Get current timestamp
          TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

          # Send Discord notification
          curl -X POST "$WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d @- << EOF
          {
            "embeds": [{
              "title": "🗑️ Stack Cleanup - ${{ inputs.repo-name }}",
              "description": "Removed stacks have been cleaned up before deployment",
              "color": 16753920,
              "fields": [
                {
                  "name": "Removed Stacks",
                  "value": "$STACK_LIST"
                },
                {
                  "name": "Target Commit",
                  "value": "\`${{ inputs.target-ref }}\`"
                },
                {
                  "name": "Previous Commit",
                  "value": "\`${{ steps.backup.outputs.previous_sha }}\`"
                }
              ],
              "timestamp": "$TIMESTAMP"
            }]
          }
          EOF

          echo "✅ Cleanup notification sent"
```

**Step 2: Validate YAML syntax**

Run: `yamllint --strict .github/workflows/deploy.yml`
Expected: PASS

**Step 3: Validate with actionlint**

Run: `actionlint .github/workflows/deploy.yml`
Expected: PASS

**Step 4: Commit**

```bash
git add .github/workflows/deploy.yml
git commit -m "feat: add Discord notification for removed stack cleanup

Send separate notification when stacks are removed, listing which stacks
were cleaned up with commit information."
```

---

## Task 3: Add job outputs for removed stacks tracking

**Files:**
- Modify: `.github/workflows/deploy.yml:105-125` (outputs section)

**Step 1: Add outputs for removed stacks**

Add after line 125 (after existing outputs in deploy job):

```yaml
      removed_stacks: ${{ steps.cleanup-removed.outputs.removed_stacks }}
      has_removed_stacks: ${{ steps.cleanup-removed.outputs.has_removed_stacks }}
```

**Step 2: Validate YAML syntax**

Run: `yamllint --strict .github/workflows/deploy.yml`
Expected: PASS

**Step 3: Validate with actionlint**

Run: `actionlint .github/workflows/deploy.yml`
Expected: PASS

**Step 4: Commit**

```bash
git add .github/workflows/deploy.yml
git commit -m "feat: expose removed stacks as job outputs

Allow downstream jobs or workflows to access information about which
stacks were removed during cleanup."
```

---

## Task 4: Handle edge case - unknown current SHA

**Files:**
- Modify: `.github/workflows/deploy.yml` (cleanup step from Task 1)

**Step 1: Add safety check for unknown SHA**

Modify the detection logic in the cleanup step to skip when CURRENT_SHA is "unknown":

Find the detection section (added in Task 1) and add this check after getting CURRENT_SHA:

```yaml
          # Skip detection if this is the first deployment
          if [ "$CURRENT_SHA" = "unknown" ]; then
            echo "ℹ️ First deployment detected - no previous stacks to remove"
            echo "removed_stacks=" >> $GITHUB_OUTPUT
            echo "has_removed_stacks=false" >> $GITHUB_OUTPUT
            exit 0
          fi
```

Insert this right after:
```yaml
          CURRENT_SHA="${{ steps.backup.outputs.previous_sha }}"
          TARGET_REF="${{ inputs.target-ref }}"
```

**Step 2: Validate YAML syntax**

Run: `yamllint --strict .github/workflows/deploy.yml`
Expected: PASS

**Step 3: Validate with actionlint**

Run: `actionlint .github/workflows/deploy.yml`
Expected: PASS

**Step 4: Commit**

```bash
git add .github/workflows/deploy.yml
git commit -m "fix: skip removal detection on first deployment

When CURRENT_SHA is 'unknown', skip stack removal detection as there
are no previous stacks to clean up."
```

---

## Task 5: Add error handling for git diff failures

**Files:**
- Modify: `.github/workflows/deploy.yml` (detection section in cleanup step)

**Step 1: Add error handling around git diff**

Modify the REMOVED_STACKS detection to handle git diff errors gracefully:

Replace the detection heredoc from Task 1 with this enhanced version:

```bash
          REMOVED_STACKS=$(ssh_retry 3 5 "ssh -o 'StrictHostKeyChecking no' deployment-server" << 'DETECT_EOF'
            set -e
            cd /opt/compose

            # Fetch target ref to ensure we have it
            if ! git fetch origin "$TARGET_REF" 2>/dev/null; then
              echo "⚠️ Failed to fetch target ref, trying general fetch..."
              if ! git fetch 2>/dev/null; then
                echo "::error::Failed to fetch repository updates"
                exit 1
              fi
            fi

            # Resolve target ref to SHA for comparison
            TARGET_SHA=$(git rev-parse "$TARGET_REF" 2>/dev/null || echo "$TARGET_REF")

            # Validate both SHAs exist
            if ! git cat-file -e "$CURRENT_SHA" 2>/dev/null; then
              echo "::error::Current SHA $CURRENT_SHA not found in repository"
              exit 1
            fi

            if ! git cat-file -e "$TARGET_SHA" 2>/dev/null; then
              echo "::error::Target SHA $TARGET_SHA not found in repository"
              exit 1
            fi

            # Find deleted compose.yaml files between current and target
            git diff --diff-filter=D --name-only "$CURRENT_SHA" "$TARGET_SHA" 2>/dev/null | \
              grep -E '^[^/]+/compose\.yaml$' | \
              sed 's|/compose\.yaml||' || echo ""
DETECT_EOF
          )
```

**Step 2: Add error check after detection**

Add after the REMOVED_STACKS assignment:

```bash
          # Check if detection succeeded
          DETECTION_EXIT=$?
          if [ $DETECTION_EXIT -ne 0 ]; then
            echo "::error::Failed to detect removed stacks (exit code: $DETECTION_EXIT)"
            exit 1
          fi
```

**Step 3: Validate YAML syntax**

Run: `yamllint --strict .github/workflows/deploy.yml`
Expected: PASS

**Step 4: Validate with actionlint**

Run: `actionlint .github/workflows/deploy.yml`
Expected: PASS

**Step 5: Commit**

```bash
git add .github/workflows/deploy.yml
git commit -m "feat: add robust error handling for git diff

Validate SHAs exist, handle fetch failures gracefully, and fail fast
if detection cannot proceed."
```

---

## Task 6: Add inline documentation

**Files:**
- Modify: `.github/workflows/deploy.yml` (cleanup step)

**Step 1: Add documentation comment before cleanup step**

Add comment block before the "Detect and cleanup removed stacks" step:

```yaml
      # STACK REMOVAL DETECTION AND CLEANUP
      # This step runs before repository update to clean up Docker containers
      # for stacks that have been completely removed from the repository.
      #
      # Process:
      # 1. Compare current deployed SHA with target SHA using git diff
      # 2. Identify deleted */compose.yaml files (one level deep only)
      # 3. Run 'docker compose down' for each removed stack
      # 4. Fail deployment if any cleanup fails (fail-safe)
      # 5. Send Discord notification listing removed stacks
      #
      # Design: docs/plans/2025-12-03-stack-removal-detection-design.md

      - name: Detect and cleanup removed stacks
```

**Step 2: Validate YAML syntax**

Run: `yamllint --strict .github/workflows/deploy.yml`
Expected: PASS

**Step 3: Commit**

```bash
git add .github/workflows/deploy.yml
git commit -m "docs: add inline documentation for stack removal cleanup

Explain the stack removal detection process and link to design document."
```

---

## Task 7: Update workflow documentation

**Files:**
- Modify: `CLAUDE.md` (Deploy Pipeline Features section)

**Step 1: Add feature to Deploy Pipeline Features list**

Find the "Deploy Pipeline Features" section and add after item 10:

```markdown
11. **Stack Removal Cleanup** - Detect deleted stacks via git diff and clean up containers before repository update
```

**Step 2: Add to Recent Improvements section**

Find "Recent Improvements" and add:

```markdown
8. **Stack Removal Detection**: Automatic cleanup of removed stacks with fail-safe operation
```

**Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document stack removal cleanup feature

Add stack removal detection to feature list and recent improvements."
```

---

## Task 8: Validate complete workflow

**Files:**
- Read: `.github/workflows/deploy.yml`

**Step 1: Run full workflow validation**

Run: `yamllint --strict .github/workflows/deploy.yml && actionlint .github/workflows/deploy.yml`
Expected: PASS on both tools

**Step 2: Verify step order**

Run: `grep -n "name:" .github/workflows/deploy.yml | grep -A2 -B2 "cleanup-removed"`
Expected: Shows cleanup step is between backup and deploy steps

**Step 3: Verify all outputs are defined**

Run: `grep "steps.cleanup-removed.outputs" .github/workflows/deploy.yml`
Expected: Shows removed_stacks and has_removed_stacks are used consistently

**Step 4: Check for syntax errors**

Run: `bash -n <(grep -A200 "name: Detect and cleanup removed stacks" .github/workflows/deploy.yml | head -100)`
Expected: No syntax errors (bash validates heredoc syntax)

**Step 5: Final commit if any fixes needed**

```bash
# Only if validation revealed issues
git add .github/workflows/deploy.yml
git commit -m "fix: resolve workflow validation issues"
```

---

## Testing Notes

### Local Testing
- Use `yamllint` and `actionlint` for static validation
- Bash heredoc syntax can be validated with `bash -n`
- JSON output can be validated with `jq`

### Integration Testing (requires deployment)
1. Create test stack in target repository
2. Deploy to ensure stack is running
3. Remove stack directory from repository
4. Trigger deployment workflow
5. Verify:
   - Stack detected as removed in logs
   - Docker compose down executed
   - Containers stopped
   - Discord notification sent
   - Deployment proceeded after cleanup

### Edge Cases to Test
- First deployment (unknown SHA) - should skip detection
- No stacks removed - should output empty and continue
- Multiple stacks removed - should clean all sequentially
- Cleanup failure - should fail deployment
- Git diff failure - should fail deployment with clear error

---

## Rollout Strategy

1. **Test in docker-piwine-office** - Smallest environment
2. **Verify notifications and logs** - Check Discord and GitHub Actions logs
3. **Test actual stack removal** - Remove a test stack and deploy
4. **Roll out to docker-piwine** - Larger environment
5. **Deploy to docker-zendc** - Production environment

---

## Success Criteria

- ✅ Workflow passes yamllint and actionlint validation
- ✅ Step executes between backup and deploy
- ✅ Git diff correctly identifies removed stacks
- ✅ Docker compose down executes for each removed stack
- ✅ Deployment fails if cleanup fails
- ✅ Discord notification sent for removed stacks
- ✅ First deployment (unknown SHA) handled gracefully
- ✅ No stacks removed case handled gracefully
- ✅ Inline documentation explains process
- ✅ CLAUDE.md updated with new feature
