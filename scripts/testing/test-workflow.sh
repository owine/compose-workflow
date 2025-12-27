#!/usr/bin/env bash
set -euo pipefail

# Local testing script for Docker Compose workflows
# This script simulates the GitHub Actions workflow locally for testing

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034 # REPO_ROOT reserved for future use in local testing
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}ℹ️  $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

log_header() {
    echo -e "${BLUE}=== $1 ===${NC}"
}

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Local testing script for Docker Compose workflows

OPTIONS:
    -w, --workflow TYPE     Workflow type to test (lint|deploy)
    -s, --stacks STACKS     JSON array of stack names (e.g., '["stack1", "stack2"]')
    -r, --repo REPO         Repository name for testing
    -t, --target-ref REF    Target git reference (default: current HEAD)
    -d, --dry-run           Dry run mode - validate only, don't execute
    -v, --verbose           Verbose output
    -h, --help              Show this help message

EXAMPLES:
    # Test lint workflow
    $0 --workflow lint --stacks '["dozzle", "portainer"]' --repo docker-test

    # Test deploy workflow (dry run)
    $0 --workflow deploy --stacks '["services"]' --repo docker-test --dry-run

    # Validate inputs only
    $0 --workflow lint --stacks '["invalid stack!"]' --repo test --dry-run
EOF
}

validate_inputs() {
    local stacks="$1"
    local repo="$2"
    local target_ref="$3"
    local webhook_url="${4:-op://test/test/test}"
    
    log_header "Input Validation Tests"
    
    # Test JSON validation
    echo "Testing stacks JSON validation..."
    if echo "$stacks" | jq -r '.[]' >/dev/null 2>&1; then
        log_info "✅ Stacks JSON is valid"
    else
        log_error "❌ Invalid stacks JSON format: $stacks"
        return 1
    fi
    
    # Test stack names
    echo "Testing stack name validation..."
    echo "$stacks" | jq -r '.[]' | while read -r stack; do
        if [[ ! "$stack" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            log_error "❌ Invalid stack name: $stack"
            exit 1
        fi
        if [ ${#stack} -gt 50 ]; then
            log_error "❌ Stack name too long: $stack (max 50 characters)"
            exit 1
        fi
        log_info "✅ Stack name valid: $stack"
    done
    
    # Test target-ref
    echo "Testing target-ref validation..."
    if [[ ! "$target_ref" =~ ^[a-fA-F0-9]{7,40}$|^[a-zA-Z0-9_/-]+$ ]]; then
        log_error "❌ Invalid target-ref format: $target_ref"
        return 1
    else
        log_info "✅ Target-ref valid: $target_ref"
    fi
    
    # Test webhook URL
    echo "Testing webhook URL validation..."
    if [[ ! "$webhook_url" =~ ^op://[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+$ ]]; then
        log_error "❌ Invalid webhook URL format: $webhook_url"
        return 1
    else
        log_info "✅ Webhook URL valid: $webhook_url"
    fi
    
    # Test repo name
    echo "Testing repo name validation..."
    if [[ ! "$repo" =~ ^[a-zA-Z0-9_-]+$ ]] || [ ${#repo} -gt 100 ]; then
        log_error "❌ Invalid repo name: $repo"
        return 1
    else
        log_info "✅ Repo name valid: $repo"
    fi
    
    log_info "🎉 All input validations passed!"
    return 0
}

test_lint_workflow() {
    local stacks="$1"
    local repo="$2"
    local target_ref="$3"
    local dry_run="$4"
    
    log_header "Testing Lint Workflow"
    
    if [ "$dry_run" = "true" ]; then
        log_info "🧪 Dry run mode - simulating lint workflow"
        
        echo "Would test the following stacks:"
        echo "$stacks" | jq -r '.[] | "  - " + .'
        
        echo "Simulating YAML validation..."
        echo "$stacks" | jq -r '.[]' | while read -r stack; do
            log_info "📋 Would validate YAML for stack: $stack"
        done
        
        echo "Simulating Docker Compose validation..."
        echo "$stacks" | jq -r '.[]' | while read -r stack; do
            log_info "🐳 Would validate Docker Compose for stack: $stack"
        done
        
        log_info "✅ Lint workflow simulation completed"
    else
        log_warn "⚠️ Live lint testing not implemented yet"
        log_info "Use --dry-run for validation testing"
    fi
}

test_deploy_workflow() {
    local stacks="$1"
    local repo="$2"
    local target_ref="$3"
    local dry_run="$4"
    
    log_header "Testing Deploy Workflow"
    
    if [ "$dry_run" = "true" ]; then
        log_info "🧪 Dry run mode - simulating deploy workflow"
        
        echo "Would deploy the following stacks:"
        echo "$stacks" | jq -r '.[] | "  - " + .'
        
        echo "Simulating deployment steps..."
        log_info "📋 Would validate deployment prerequisites"
        log_info "🚀 Would deploy stacks in parallel"
        log_info "🔍 Would perform health checks"
        log_info "🧹 Would cleanup unused images"
        
        log_info "✅ Deploy workflow simulation completed"
    else
        log_warn "⚠️ Live deploy testing requires SSH access to deployment server"
        log_info "Use --dry-run for validation testing"
    fi
}

check_dependencies() {
    log_header "Checking Dependencies"
    
    local missing_deps=()
    
    # Check for required tools
    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi
    
    if ! command -v git &> /dev/null; then
        missing_deps+=("git")
    fi
    
    if ! command -v yamllint &> /dev/null; then
        log_warn "yamllint not found - install with: pip install yamllint"
    fi
    
    if ! command -v docker &> /dev/null; then
        log_warn "docker not found - some tests may be limited"
    fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        return 1
    else
        log_info "✅ All required dependencies found"
        return 0
    fi
}

main() {
    local workflow=""
    local stacks=""
    local repo=""
    local target_ref=""
    local dry_run="false"
    local verbose="false"
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -w|--workflow)
                workflow="$2"
                shift 2
                ;;
            -s|--stacks)
                stacks="$2"
                shift 2
                ;;
            -r|--repo)
                repo="$2"
                shift 2
                ;;
            -t|--target-ref)
                target_ref="$2"
                shift 2
                ;;
            -d|--dry-run)
                dry_run="true"
                shift
                ;;
            -v|--verbose)
                # shellcheck disable=SC2034 # verbose reserved for future verbose logging implementation
                verbose="true"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    # Set default values
    target_ref="${target_ref:-$(git rev-parse HEAD)}"
    
    # Validate required arguments
    if [ -z "$workflow" ] || [ -z "$stacks" ] || [ -z "$repo" ]; then
        log_error "Missing required arguments"
        usage
        exit 1
    fi
    
    if [ "$workflow" != "lint" ] && [ "$workflow" != "deploy" ]; then
        log_error "Invalid workflow type: $workflow (must be 'lint' or 'deploy')"
        exit 1
    fi
    
    log_header "Local Workflow Testing"
    echo "Workflow: $workflow"
    echo "Stacks: $stacks"
    echo "Repository: $repo"
    echo "Target Ref: $target_ref"
    echo "Dry Run: $dry_run"
    echo ""
    
    # Check dependencies
    if ! check_dependencies; then
        exit 1
    fi
    
    # Validate inputs
    if ! validate_inputs "$stacks" "$repo" "$target_ref"; then
        exit 1
    fi
    
    # Run workflow-specific tests
    case $workflow in
        lint)
            test_lint_workflow "$stacks" "$repo" "$target_ref" "$dry_run"
            ;;
        deploy)
            test_deploy_workflow "$stacks" "$repo" "$target_ref" "$dry_run"
            ;;
    esac
    
    log_info "🎉 Local testing completed successfully!"
}

# Only run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi