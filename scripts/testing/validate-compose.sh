#!/usr/bin/env bash
set -euo pipefail

# Docker Compose validation script for local testing
# Validates compose files before deployment

# shellcheck disable=SC2034 # SCRIPT_DIR reserved for future use in script path operations
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
Usage: $0 [OPTIONS] DIRECTORY

Validate Docker Compose files in a directory structure

ARGUMENTS:
    DIRECTORY               Path to directory containing compose stacks

OPTIONS:
    -s, --stack STACK       Validate specific stack only
    -c, --config-only       Only validate compose config, skip YAML lint
    -v, --verbose           Verbose output
    -h, --help              Show this help message

EXAMPLES:
    # Validate all stacks in directory
    $0 /path/to/docker-repo

    # Validate specific stack
    $0 --stack dozzle /path/to/docker-repo

    # Quick config validation only
    $0 --config-only /path/to/docker-repo
EOF
}

validate_yaml() {
    local file="$1"
    local config_file="${2:-}"
    
    if command -v yamllint &> /dev/null; then
        if [ -n "$config_file" ] && [ -f "$config_file" ]; then
            if yamllint --config-file "$config_file" "$file" 2>/dev/null; then
                log_info "✅ YAML syntax valid: $(basename "$file")"
                return 0
            else
                log_error "❌ YAML syntax errors in: $(basename "$file")"
                yamllint --config-file "$config_file" "$file" || true
                return 1
            fi
        else
            if yamllint "$file" 2>/dev/null; then
                log_info "✅ YAML syntax valid: $(basename "$file")"
                return 0
            else
                log_error "❌ YAML syntax errors in: $(basename "$file")"
                yamllint "$file" || true
                return 1
            fi
        fi
    else
        log_warn "yamllint not available - skipping YAML validation"
        return 0
    fi
}

validate_compose_config() {
    local compose_file="$1"
    local stack_name="$2"
    
    if command -v docker &> /dev/null; then
        log_info "🐳 Validating Docker Compose config for $stack_name..."
        
        if docker compose -f "$compose_file" config >/dev/null 2>&1; then
            log_info "✅ Docker Compose config valid: $stack_name"
            return 0
        else
            log_error "❌ Docker Compose config errors in: $stack_name"
            echo "Error details:"
            docker compose -f "$compose_file" config 2>&1 || true
            return 1
        fi
    else
        log_warn "Docker not available - skipping compose config validation"
        return 0
    fi
}

check_compose_security() {
    local compose_file="$1"
    local stack_name="$2"
    
    log_info "🔒 Checking security best practices for $stack_name..."
    
    local warnings=0
    
    # Check for privileged containers
    if grep -q "privileged.*true" "$compose_file" 2>/dev/null; then
        log_warn "⚠️ Privileged containers detected in $stack_name"
        warnings=$((warnings + 1))
    fi
    
    # Check for host network mode
    if grep -q "network_mode.*host" "$compose_file" 2>/dev/null; then
        log_warn "⚠️ Host network mode detected in $stack_name"
        warnings=$((warnings + 1))
    fi
    
    # Check for bind mounts to sensitive directories
    if grep -E "/:/|/etc:|/var/run/docker.sock" "$compose_file" 2>/dev/null; then
        log_warn "⚠️ Potentially sensitive bind mounts detected in $stack_name"
        warnings=$((warnings + 1))
    fi
    
    # Check for latest tags
    if grep -q ":latest" "$compose_file" 2>/dev/null; then
        log_warn "⚠️ 'latest' image tags detected in $stack_name (consider pinning versions)"
        warnings=$((warnings + 1))
    fi
    
    # Check for hardcoded secrets
    if grep -iE "(password|secret|key|token).*:" "$compose_file" | grep -v "file:" | grep -v "_FILE" 2>/dev/null; then
        log_warn "⚠️ Potential hardcoded secrets detected in $stack_name"
        warnings=$((warnings + 1))
    fi
    
    if [ $warnings -eq 0 ]; then
        log_info "✅ No obvious security issues found in $stack_name"
    else
        log_warn "⚠️ $warnings potential security issues found in $stack_name"
    fi
    
    return 0
}

validate_stack() {
    local stack_dir="$1"
    local stack_name="$2"
    local config_only="$3"
    local yamllint_config="$4"
    
    log_header "Validating Stack: $stack_name"
    
    local compose_file=""
    local errors=0
    
    # Find compose file
    if [ -f "$stack_dir/compose.yaml" ]; then
        compose_file="$stack_dir/compose.yaml"
    elif [ -f "$stack_dir/compose.yml" ]; then
        compose_file="$stack_dir/compose.yml"
    elif [ -f "$stack_dir/docker-compose.yaml" ]; then
        compose_file="$stack_dir/docker-compose.yaml"
    elif [ -f "$stack_dir/docker-compose.yml" ]; then
        compose_file="$stack_dir/docker-compose.yml"
    else
        log_error "❌ No compose file found in $stack_dir"
        return 1
    fi
    
    log_info "📁 Found compose file: $(basename "$compose_file")"
    
    # YAML validation
    if [ "$config_only" != "true" ]; then
        if ! validate_yaml "$compose_file" "$yamllint_config"; then
            errors=$((errors + 1))
        fi
    fi
    
    # Docker Compose config validation
    if ! validate_compose_config "$compose_file" "$stack_name"; then
        errors=$((errors + 1))
    fi
    
    # Security checks
    check_compose_security "$compose_file" "$stack_name"
    
    if [ $errors -eq 0 ]; then
        log_info "✅ Stack $stack_name validation passed"
        return 0
    else
        log_error "❌ Stack $stack_name validation failed with $errors error(s)"
        return 1
    fi
}

main() {
    local directory=""
    local specific_stack=""
    local config_only="false"
    local verbose="false"
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -s|--stack)
                specific_stack="$2"
                shift 2
                ;;
            -c|--config-only)
                config_only="true"
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
            -*)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
            *)
                directory="$1"
                shift
                ;;
        esac
    done
    
    # Validate arguments
    if [ -z "$directory" ]; then
        log_error "Directory argument is required"
        usage
        exit 1
    fi
    
    if [ ! -d "$directory" ]; then
        log_error "Directory does not exist: $directory"
        exit 1
    fi
    
    log_header "Docker Compose Validation"
    echo "Directory: $directory"
    echo "Specific stack: ${specific_stack:-all}"
    echo "Config only: $config_only"
    echo ""
    
    # Look for yamllint config
    local yamllint_config=""
    if [ -f "$directory/.yamllint" ]; then
        yamllint_config="$directory/.yamllint"
        log_info "📋 Found yamllint config: .yamllint"
    elif [ -f "$directory/.yamllint.yml" ]; then
        yamllint_config="$directory/.yamllint.yml"
        log_info "📋 Found yamllint config: .yamllint.yml"
    fi
    
    local total_stacks=0
    local failed_stacks=0
    local validated_stacks=()
    
    # Find and validate stacks
    for stack_dir in "$directory"/*; do
        if [ -d "$stack_dir" ]; then
            stack_name=$(basename "$stack_dir")
            
            # Skip if specific stack requested and this isn't it
            if [ -n "$specific_stack" ] && [ "$stack_name" != "$specific_stack" ]; then
                continue
            fi
            
            # Check if it contains a compose file
            has_compose=false
            for file in "$stack_dir"/*.yml "$stack_dir"/*.yaml; do
                [ -f "$file" ] && [[ $(basename "$file") =~ (compose|docker-compose) ]] && has_compose=true && break
            done

            if [ "$has_compose" = "true" ]; then
                total_stacks=$((total_stacks + 1))
                validated_stacks+=("$stack_name")
                
                if ! validate_stack "$stack_dir" "$stack_name" "$config_only" "$yamllint_config"; then
                    failed_stacks=$((failed_stacks + 1))
                fi
                echo ""
            fi
        fi
    done
    
    # Summary
    log_header "Validation Summary"
    echo "Total stacks validated: $total_stacks"
    echo "Validated stacks: ${validated_stacks[*]}"
    echo "Failed validations: $failed_stacks"
    
    if [ $failed_stacks -eq 0 ]; then
        log_info "🎉 All validations passed!"
        exit 0
    else
        log_error "❌ $failed_stacks stack(s) failed validation"
        exit 1
    fi
}

# Only run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi