# Local Testing Scripts

This directory contains scripts for local testing and validation of Docker Compose workflows.

## Scripts

### `test-workflow.sh`

Main testing script that simulates GitHub Actions workflows locally.

**Usage:**
```bash
# Test lint workflow with validation
./test-workflow.sh --workflow lint --stacks '["dozzle", "portainer"]' --repo docker-test --dry-run

# Test deploy workflow (simulation)
./test-workflow.sh --workflow deploy --stacks '["services"]' --repo docker-test --dry-run

# Validate inputs with invalid data to test validation
./test-workflow.sh --workflow lint --stacks '["invalid stack!"]' --repo test --dry-run
```

**Features:**
- Input validation testing (matches workflow validation)
- Workflow simulation in dry-run mode
- Dependency checking
- Colored output for easy reading

### `validate-compose.sh`

Docker Compose file validation and security checking script.

**Usage:**
```bash
# Validate all stacks in a repository
./validate-compose.sh /path/to/docker-repo

# Validate specific stack
./validate-compose.sh --stack dozzle /path/to/docker-repo

# Quick config validation only (skip YAML linting)
./validate-compose.sh --config-only /path/to/docker-repo
```

**Features:**
- YAML syntax validation with yamllint
- Docker Compose configuration validation
- Security best practices checking
- Support for yamllint configuration files

## Setup

1. Make scripts executable:
```bash
chmod +x scripts/testing/*.sh
```

2. Install dependencies:
```bash
# Required
brew install jq git docker

# Optional (for enhanced validation)
pip install yamllint
```

## Examples

### Test Input Validation

```bash
# Test with valid inputs
./test-workflow.sh --workflow lint --stacks '["dozzle", "portainer"]' --repo docker-test --dry-run

# Test with invalid stack name (should fail)
./test-workflow.sh --workflow lint --stacks '["invalid stack!"]' --repo test --dry-run

# Test with invalid JSON (should fail)
./test-workflow.sh --workflow lint --stacks 'invalid-json' --repo test --dry-run
```

### Validate Docker Compose Files

```bash
# Validate all stacks in a repository
./validate-compose.sh ../docker-piwine

# Validate specific stack with verbose output
./validate-compose.sh --stack dozzle --verbose ../docker-piwine

# Quick validation without YAML linting
./validate-compose.sh --config-only ../docker-zendc
```

### Security Checks

The validation script automatically checks for common security issues:

- Privileged containers
- Host network mode
- Sensitive bind mounts
- Latest image tags (recommends pinning)
- Potential hardcoded secrets

## Integration with Development

### Pre-commit Validation

Add to your development workflow:

```bash
# Validate before committing
./scripts/testing/validate-compose.sh .

# Test workflow inputs before pushing
./scripts/testing/test-workflow.sh --workflow lint --stacks '["your", "stacks"]' --repo your-repo --dry-run
```

### CI/CD Testing

Use these scripts in CI pipelines for additional validation:

```yaml
- name: Local validation
  run: |
    ./scripts/testing/validate-compose.sh .
    ./scripts/testing/test-workflow.sh --workflow lint --stacks '${{ inputs.stacks }}' --repo test --dry-run
```

## Troubleshooting

### Common Issues

1. **Missing dependencies**: Install jq, git, docker, and yamllint
2. **Permission denied**: Run `chmod +x scripts/testing/*.sh`
3. **YAML validation fails**: Check your `.yamllint` configuration
4. **Compose validation fails**: Verify your compose file syntax

### Debug Mode

Run scripts with `set -x` for detailed debugging:

```bash
bash -x scripts/testing/test-workflow.sh --workflow lint --stacks '["test"]' --repo test --dry-run
```