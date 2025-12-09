#!/bin/bash
# Test script for enhanced stack removal detection
# Tests all three detection methods independently

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "🧪 Testing Enhanced Stack Removal Detection"
echo "=========================================="
echo ""

# Test 1: Git diff detection
test_gitdiff_detection() {
  echo -e "${YELLOW}Test 1: Git diff detection${NC}"

  # This test requires a git repository with commits
  # Create temporary test repo
  TEST_DIR=$(mktemp -d)
  cd "$TEST_DIR"

  git init
  mkdir stack1 stack2
  echo "version: '3.8'" > stack1/compose.yaml
  echo "version: '3.8'" > stack2/compose.yaml
  git add .
  git commit -m "Initial commit"
  COMMIT1=$(git rev-parse HEAD)

  # Remove stack1
  rm -rf stack1
  git add .
  git commit -m "Remove stack1"
  COMMIT2=$(git rev-parse HEAD)

  # Test detection
  RESULT=$(git diff --diff-filter=D --name-only "$COMMIT1" "$COMMIT2" | grep -E '^[^/]+/compose\.yaml$' | sed 's|/compose\.yaml||' || echo "")

  if [ "$RESULT" = "stack1" ]; then
    echo -e "${GREEN}✓ Git diff detection works${NC}"
    cd - > /dev/null
    rm -rf "$TEST_DIR"
    return 0
  else
    echo -e "${RED}✗ Git diff detection failed. Expected 'stack1', got '$RESULT'${NC}"
    cd - > /dev/null
    rm -rf "$TEST_DIR"
    return 1
  fi
}

# Test 2: Tree comparison detection
test_tree_detection() {
  echo -e "${YELLOW}Test 2: Tree comparison detection${NC}"

  # Create temporary test repo
  TEST_DIR=$(mktemp -d)
  cd "$TEST_DIR"

  git init
  mkdir stack1 stack2
  echo "version: '3.8'" > stack1/compose.yaml
  echo "version: '3.8'" > stack2/compose.yaml
  git add .
  git commit -m "Initial commit"

  # Add stack3 to filesystem but not to git
  mkdir stack3
  echo "version: '3.8'" > stack3/compose.yaml

  # Get commit tree
  COMMIT_DIRS=$(git ls-tree --name-only HEAD | sort)
  # Get filesystem dirs
  SERVER_DIRS=$(find . -maxdepth 1 -mindepth 1 -type d ! -name '.git' -exec basename {} \; | sort)

  # Find missing in commit
  MISSING=$(comm -13 <(echo "$COMMIT_DIRS") <(echo "$SERVER_DIRS"))

  # Filter for compose.yaml
  RESULT=""
  for dir in $MISSING; do
    if [ -f "$dir/compose.yaml" ]; then
      RESULT="$dir"
    fi
  done

  if [ "$RESULT" = "stack3" ]; then
    echo -e "${GREEN}✓ Tree comparison detection works${NC}"
    cd - > /dev/null
    rm -rf "$TEST_DIR"
    return 0
  else
    echo -e "${RED}✗ Tree comparison detection failed. Expected 'stack3', got '$RESULT'${NC}"
    cd - > /dev/null
    rm -rf "$TEST_DIR"
    return 1
  fi
}

# Test 3: Discovery analysis detection
test_discovery_detection() {
  echo -e "${YELLOW}Test 3: Discovery analysis detection${NC}"

  # Mock JSON from tj-actions/changed-files
  DELETED_JSON='["stack1/compose.yaml", "stack2/.env", "stack3/compose.yaml", "README.md"]'

  # Test parsing
  RESULT=$(echo "$DELETED_JSON" | jq -r '.[]' | grep -E '^[^/]+/compose\.yaml$' | sed 's|/compose\.yaml||' || echo "")
  EXPECTED="stack1
stack3"

  if [ "$RESULT" = "$EXPECTED" ]; then
    echo -e "${GREEN}✓ Discovery analysis detection works${NC}"
    return 0
  else
    echo -e "${RED}✗ Discovery analysis detection failed${NC}"
    echo "Expected:"
    echo "$EXPECTED"
    echo "Got:"
    echo "$RESULT"
    return 1
  fi
}

# Test 4: Aggregation with deduplication
test_aggregation() {
  echo -e "${YELLOW}Test 4: Aggregation with deduplication${NC}"

  GITDIFF="stack1
stack2"
  TREE="stack2
stack3"
  DISCOVERY="stack1
stack4"

  # Aggregate
  RESULT=$({
    echo "$GITDIFF"
    echo "$TREE"
    echo "$DISCOVERY"
  } | grep -v '^$' | sort -u)

  EXPECTED="stack1
stack2
stack3
stack4"

  if [ "$RESULT" = "$EXPECTED" ]; then
    echo -e "${GREEN}✓ Aggregation works correctly${NC}"
    return 0
  else
    echo -e "${RED}✗ Aggregation failed${NC}"
    echo "Expected:"
    echo "$EXPECTED"
    echo "Got:"
    echo "$RESULT"
    return 1
  fi
}

# Test 5: Empty input handling
test_empty_handling() {
  echo -e "${YELLOW}Test 5: Empty input handling${NC}"

  GITDIFF=""
  TREE=""
  DISCOVERY=""

  RESULT=$({
    echo "$GITDIFF"
    echo "$TREE"
    echo "$DISCOVERY"
  } | grep -v '^$' | sort -u || echo "")

  if [ -z "$RESULT" ]; then
    echo -e "${GREEN}✓ Empty input handling works${NC}"
    return 0
  else
    echo -e "${RED}✗ Empty input handling failed. Expected empty, got '$RESULT'${NC}"
    return 1
  fi
}

# Run all tests
FAILED=0

test_gitdiff_detection || FAILED=$((FAILED + 1))
echo ""

test_tree_detection || FAILED=$((FAILED + 1))
echo ""

test_discovery_detection || FAILED=$((FAILED + 1))
echo ""

test_aggregation || FAILED=$((FAILED + 1))
echo ""

test_empty_handling || FAILED=$((FAILED + 1))
echo ""

# Summary
echo "=========================================="
if [ $FAILED -eq 0 ]; then
  echo -e "${GREEN}✓ All tests passed!${NC}"
  exit 0
else
  echo -e "${RED}✗ $FAILED test(s) failed${NC}"
  exit 1
fi
