# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Centralized Docker Compose Workflow Management

This repository contains **reusable GitHub Actions workflows** that provide centralized CI/CD automation for Docker Compose environments. The goal is to eliminate code duplication while maintaining environment-specific configurations.

### Repository Purpose

**compose-workflow** serves as a centralized workflow hub providing reusable CI/CD workflows for Docker Compose deployments across multiple repositories.

### Workflow Architecture

This repository provides two main reusable workflows:

#### 1. Lint Workflow (`/.github/workflows/lint.yml`)
- **Purpose**: Validates Docker Compose files and detects secrets
- **Features**: 
  - GitGuardian scanning for secret detection (push events only)
  - YAML linting with yamllint
  - Docker Compose validation
  - Parallel execution of all validation tasks
  - Discord notifications with detailed status
- **Key Input Parameters**: 
  - `stacks`: JSON array of stack names to lint
  - `webhook-url`: 1Password reference to Discord webhook
  - `repo-name`: Repository name for notifications
  - `target-repository`: Target repository to checkout
  - `target-ref`: Git reference to checkout (default: main)
  - Various GitHub event parameters for context

#### 2. Deploy Workflow (`/.github/workflows/deploy.yml`)
- **Purpose**: Handles deployment, health checks, rollback, and cleanup with comprehensive monitoring
- **Features**:
  - Input validation and sanitization for security
  - Enhanced error handling with retry logic and exponential backoff
  - Parallel stack deployment with detailed logging
  - Stack-specific health checking with accurate service counts
  - Automatic rollback on failure with SHA tracking
  - Docker image cleanup after successful deployment
  - SSH connection optimization with multiplexing
  - Tailscale integration with cached state
  - Rich Discord notifications with deployment metrics
  - **Enhanced Stack Removal Detection**: Three-method detection system
    - Git diff: Commit comparison (existing)
    - Tree comparison: Filesystem vs commit tree (catches undeployed removals)
    - Discovery analysis: tj-actions/changed-files validation
  - Union-based aggregation with fail-safe error handling
- **Key Input Parameters**:
  - `stacks`: JSON array of stack names to deploy
  - `webhook-url`: 1Password reference to Discord webhook  
  - `repo-name`: Repository name for notifications
  - `target-ref`: Git reference to deploy (SHA or branch/tag)
  - `has-dockge`: Boolean for Dockge deployment
  - `force-deploy`: Force deployment even if at target commit
  - `args`: Additional docker compose up arguments

### Recent Improvements

1. **Input Validation & Sanitization**: Comprehensive validation of all workflow inputs to prevent injection attacks
2. **Enhanced Error Handling**: Retry logic with exponential backoff for network operations
3. **Local Testing Capabilities**: Scripts for testing workflows locally (`scripts/testing/`)
4. **Enhanced Health Checks**: Dynamic retry logic with stack-specific service counting
5. **Caching Strategies**: Optimized caching for Tailscale state and deployment tools
6. **SSH Optimization**: Connection multiplexing and retry mechanisms
7. **Parallel Execution**: All lint jobs (GitGuardian, YAML lint) run concurrently
8. **Stack Removal Detection**: Automatic cleanup of removed stacks with fail-safe operation
9. **Dockge Workflow Integration**: Dockge deployment handled at workflow level for cleaner separation of concerns

### Benefits of Centralization

1. **Reduced Duplication**: Single workflow definitions shared across repositories
2. **Consistent Behavior**: Standardized deployment patterns and error handling  
3. **Centralized Maintenance**: Updates apply to all environments simultaneously
4. **Enhanced Reliability**: Automatic rollback, health checking, comprehensive monitoring
5. **Security Integration**: GitGuardian scanning, 1Password secret management, Tailscale networking
6. **Performance Optimization**: Parallel execution, caching, SSH multiplexing

## Workflow Configuration

### Required Secrets

Calling repositories must have the following secrets configured:

- `OP_SERVICE_ACCOUNT_TOKEN` - 1Password service account token for secret management
- `SSH_USER` - SSH username for deployment server
- `SSH_HOST` - SSH hostname for deployment server

### Permissions Note for Private Repositories

**Important**: Private repositories have limitations with certain GitHub Actions permissions. Container security scanning features have been removed from the lint workflow as private repositories cannot use the `security-events: write` permission required for SARIF uploads.

For private repositories, the workflows focus on:
- GitGuardian secret detection
- YAML syntax validation
- Docker Compose configuration validation
- Deployment automation with health checks

### Repository Structure Requirements

For the workflows to function properly, calling repositories must have:

```
├── .yamllint                    # yamllint configuration
├── compose.env                  # Environment file with 1Password references
├── stack1/
│   └── compose.yaml            # Docker Compose file
├── stack2/
│   └── compose.yaml            # Docker Compose file
└── stack3/
    └── compose.yaml            # Docker Compose file
```

### Discord Webhook Configuration

Webhook URLs should be stored in 1Password with references like:
- `op://Docker/discord-github-notifications/webhook_url`

Example Discord notification configuration:
```yaml
webhook-url: "op://Docker/discord-github-notifications/environment_webhook_url"
```

### Modular Linting Scripts

The lint workflow uses modular bash scripts in `scripts/linting/` for all validation operations:

#### Library Files (`scripts/linting/lib/`)
- **env-helpers.sh** - Environment file generation for validation
  - `create_temp_env()` - Creates temporary .env files with realistic placeholders
  - Eliminates environment variable warnings during Docker Compose validation
- **common.sh** - Logging and utilities
  - Colored logging functions (`log_info`, `log_success`, `log_error`, `log_warning`)
  - Validation functions (`validate_stack_name`, `require_var`)
  - Formatting helpers (`format_list`, `print_separator`, `print_subseparator`)
  - GitHub Actions output helpers (`set_github_output`)

#### Linting Scripts
- **validate-stack.sh** - Stack validation (172 lines)
  - Parallel execution of YAML linting and Docker Compose validation
  - Comprehensive error reporting with fix suggestions
  - Temporary file management and cleanup
  - Exit code-based failure detection

- **lint-summary.sh** - Summary generation (239 lines)
  - Aggregates results from GitGuardian, actionlint, and stack validation
  - Reproduces validation errors with detailed context
  - Generates comprehensive final status report
  - Determines overall workflow success/failure

#### Script Benefits
- **Modularity**: Each script has a single, well-defined purpose
- **Reusability**: Scripts can be called from other workflows or locally
- **Testability**: Scripts can be tested independently of the workflow
- **Maintainability**: Easier to update and debug than inline heredocs
- **Code Deduplication**: Eliminates 80 lines of duplicated create_temp_env function
- **Workflow Reduction**: lint.yml reduced from 666 → 308 lines (54% reduction)

### Modular Deployment Scripts

The deploy workflow uses modular bash scripts in `scripts/deployment/` for all major operations:

#### Library Files (`scripts/deployment/lib/`)
- **ssh-helpers.sh** - Retry mechanisms with exponential backoff
  - `retry()` - General command retry with configurable attempts and delays
  - `ssh_retry()` - SSH-specific retry with error code handling
  - `ssh_exec()` - Simple SSH execution wrapper
- **common.sh** - Logging, validation, and utilities
  - Colored logging functions (`log_info`, `log_success`, `log_error`, `log_warning`)
  - Input validation (`validate_stack_name`, `validate_sha`, `validate_op_reference`)
  - GitHub Actions output helpers (`set_github_output`)
  - Utility functions (`format_list`, `require_var`)

#### Deployment Scripts

- **deploy-dockge.sh** - Dockge container management deployment (110 lines)
  - Dedicated script for Dockge deployment operations
  - Called as separate workflow step before stack deployment
  - Configurable image pull and startup timeouts
  - Used for both initial deployment and rollback scenarios

- **deploy-stacks.sh** - Stack deployment orchestration (~425 lines)
  - Parallel stack deployment with background processes
  - Exit code file-based error detection
  - Comprehensive logging with stack-specific output
  - Git operations with configurable timeouts
  - Image pull and service startup with retry logic
  - Pre-deployment validation for all stacks
  - **Note**: No longer handles Dockge deployment (moved to workflow level)

- **rollback-stacks.sh** - Rollback automation (~425 lines)
  - SHA validation and git operations
  - Dynamic stack discovery from previous commit
  - Parallel rollback execution with PID tracking
  - Critical service failure detection
  - Comprehensive error reporting
  - **Note**: No longer handles Dockge rollback (moved to workflow level)

- **health-check.sh** - Service health verification (~590 lines)
  - Stack-specific service counting with accurate compose file detection
  - Dynamic retry logic based on critical service failures
  - Comprehensive health status reporting (healthy/degraded/failed stacks)
  - Docker health status parsing (healthy/starting/unhealthy containers)
  - Dockge health integration when enabled
  - Escaped parameter handling to prevent shell glob expansion

- **detect-removed-stacks.sh** - Stack removal detection (328 lines)
  - Three-method detection system (git diff, tree comparison, discovery analysis)
  - Union-based aggregation with fail-safe error handling
  - Automatic cleanup of removed stacks
  - Null-delimited output for special character support

- **cleanup-stack.sh** - Individual stack cleanup (87 lines)
  - Single stack removal helper
  - 1Password integration for environment variables
  - Graceful handling of missing stacks

#### Script Benefits
- **Modularity**: Each script has a single, well-defined purpose
- **Reusability**: Scripts can be called from other workflows or locally
- **Testability**: Scripts can be tested independently of the workflow
- **Maintainability**: Easier to update and debug than inline heredocs
- **Expression Limits**: Eliminated GitHub Actions 21,000 character heredoc limit issues

## Development Commands

### Workflow Development

```bash
# Test workflow syntax
actionlint .github/workflows/lint.yml
actionlint .github/workflows/deploy.yml

# Validate workflow YAML formatting
yamllint --strict .github/workflows/lint.yml
yamllint --strict .github/workflows/deploy.yml

# Test workflows locally
./scripts/testing/test-workflow.sh
./scripts/testing/validate-compose.sh
```

### Testing Workflows

The repository includes testing scripts in `scripts/testing/`:
- `test-workflow.sh` - Test workflow inputs and validation
- `validate-compose.sh` - Validate Docker Compose files

### Deployment Validation

```bash
# Validate Docker Compose configurations in calling repositories
yamllint --strict --config-file .yamllint stack/compose.yaml
docker compose -f stack/compose.yaml config
```

## Workflow Features

### Lint Pipeline Features

The lint workflow (`lint.yml`) provides:

1. **Parallel Execution** - GitGuardian and YAML linting run simultaneously
2. **GitGuardian Scanning** - Secret detection with 1Password integration (push events only)
3. **YAML Linting** - Validates compose file formatting using yamllint  
4. **Docker Compose Config** - Validates syntax and configuration
5. **Matrix Strategy** - Tests each stack independently
6. **Discord Notifications** - Reports results with detailed status information
7. **Multi-repository Support** - Can checkout and lint any target repository

### Deploy Pipeline Features  

The deploy workflow (`deploy.yml`) provides:

1. **Input Validation** - Comprehensive validation of all inputs for security
2. **Smart Deployment** - Skips if already at target commit (unless forced)
3. **Retry Mechanisms** - Automatic retry with exponential backoff for SSH operations
4. **Parallel Stack Deployment** - Deploy all stacks concurrently with detailed logging
5. **Stack-Specific Health Checks** - Accurate per-stack service counting and status
6. **Automatic Rollback** - Roll back to previous commit on failure
7. **Docker Image Cleanup** - Remove unused images after successful deployment
8. **SSH Optimization** - Connection multiplexing for better performance
9. **Caching** - Optimized caching for Tailscale and deployment tools
10. **Rich Discord Notifications** - Comprehensive deployment status with health metrics
11. **Stack Removal Cleanup** - Detect deleted stacks via git diff and clean up containers before repository update
12. **Critical Stack Auto-Detection** - Automatically detect critical infrastructure stacks from compose file labels

### Critical Stack Detection

The deploy workflow can automatically detect critical stacks that should trigger early deployment failure if they become unhealthy. This eliminates the need to manually maintain a list of critical stacks in each repository's workflow configuration.

#### Label Convention

Mark stacks as critical by adding labels to any service in the stack's `compose.yaml`:

```yaml
services:
  traefik:
    image: traefik:v3.2@sha256:...
    labels:
      # Mark this stack as critical infrastructure
      com.compose.tier: infrastructure
      # OR use explicit critical flag
      com.compose.critical: true
      # ... other labels
```

**Supported Labels:**
- `com.compose.tier: infrastructure` - Marks stack as infrastructure tier (recommended)
- `com.compose.critical: true` - Explicit critical flag (alternative)

#### Usage in Workflows

Auto-detection is **enabled by default** in all deployments:

```yaml
jobs:
  deploy:
    uses: owine/compose-workflow/.github/workflows/deploy.yml@main
    secrets: inherit
    with:
      stacks: '["swag", "portainer", "dozzle", "services"]'
      # auto-detect-critical: true  ← Default behavior (can omit)
```

To use manual critical services list instead:

```yaml
with:
  stacks: '["stack1", "stack2", "stack3"]'
  auto-detect-critical: false
  critical-services: '["stack1", "stack2"]'  # Manual override
```

**How auto-detection works:**
1. Detection step runs before deployment (automatic)
2. Scans each stack's `compose.yaml` for `com.compose.tier: infrastructure` labels
3. Builds JSON array of critical stacks
4. Passes to health check and rollback steps
5. Deployment fails fast if any critical stack is unhealthy

**Label Convention:**
Use `com.compose.tier: infrastructure` on individual services (not entire stacks):
- Syntax: `com.compose.tier: infrastructure` (colon syntax for YAML keys)
- Alternative: `- com.compose.tier=infrastructure` (equals syntax for arrays)

**Examples of critical services:**
- **Reverse Proxies**: `swag`, `traefik` - All external access depends on these
- **Container Management**: `portainer`, `dockge` - Required for manual intervention
- **Authentication**: `authelia` - SSO gateway for protected services
- **Monitoring**: `dozzle`, `beszel`, `uptime-kuma`, `smokeping` - Operational visibility
- **Critical Apps**: `librarymanager` - Mission-critical applications

## Security Integration

### Secret Management

The workflows integrate with 1Password for secure secret management:

- All secrets use 1Password references (`op://Vault/Item/field`)  
- GitGuardian scanning prevents accidental secret commits
- Service account tokens provide CI/CD access to secrets
- Secrets are loaded at runtime, never stored in repositories

### Input Security

- Comprehensive input validation prevents injection attacks
- Stack names validated against safe character sets
- Target refs validated for proper format
- Webhook URLs validated for 1Password format
- Repository names sanitized

### Network Security

- **Tailscale Integration** - Secure zero-trust networking for deployment connections
- **SSH Key Management** - Secure SSH connections with retry logic
- **1Password Integration** - Centralized secret management with vault isolation
- **Connection Multiplexing** - Optimized SSH connections with ControlMaster

## Cache Configuration

### Tailscale Cache
- **Key**: `tailscale-${{ runner.os }}-${{ github.repository_owner }}-${{ github.run_number }}`
- **Paths**: `~/.cache/tailscale`, `/var/lib/tailscale`
- **Restore Keys**: Hierarchical fallback for cache hits

### Deployment Tools Cache
- **Key**: `deploy-tools-${{ runner.os }}-v1`
- **Paths**: `~/.cache/pip`, `~/.cache/docker`, `~/.ssh`
- **Version**: Simple version-based key for reliability

## Workflow Maintenance

### Updating Workflows

When updating the reusable workflows in this repository:

1. **Test workflow syntax** - Use `actionlint` to validate workflow files
2. **Run local tests** - Use testing scripts in `scripts/testing/`
3. **Update documentation** - Reflect changes in `README.md` and `CLAUDE.md`
4. **Version workflows** - Consider using tags for major workflow changes
5. **Test with target repositories** - Verify changes work across calling repositories

### Version Management

- Target repositories reference workflows using `@main` for latest features
- For stability, repositories can pin to specific versions like `@v1.0.0`
- Breaking changes should be versioned and communicated to calling repositories

### Adding New Features

When adding new features to the workflows:

1. **Add input parameters** - Define new inputs in workflow files
2. **Validate inputs** - Add validation logic for security
3. **Update parameter documentation** - Document new parameters in README.md
4. **Test thoroughly** - Verify new features work across different repository configurations
5. **Maintain backward compatibility** - Ensure existing implementations continue to work

## Repository Structure

This repository contains:

```
├── .github/
│   └── workflows/
│       ├── lint.yml              # Reusable lint workflow (308 lines, 54% reduction)
│       └── deploy.yml            # Reusable deploy workflow (783 lines, 69% reduction)
├── scripts/
│   ├── linting/                  # Modular linting scripts
│   │   ├── lib/
│   │   │   ├── env-helpers.sh   # Environment file generation (73 lines)
│   │   │   └── common.sh        # Utilities and logging (78 lines)
│   │   ├── validate-stack.sh    # Stack validation (172 lines)
│   │   ├── lint-summary.sh      # Summary generation (239 lines)
│   │   └── .shellcheckrc        # ShellCheck configuration
│   ├── deployment/               # Modular deployment scripts
│   │   ├── lib/
│   │   │   ├── ssh-helpers.sh   # Retry mechanisms (68 lines)
│   │   │   └── common.sh        # Utilities and validation (86 lines)
│   │   ├── health-check.sh      # Health verification (584 lines)
│   │   ├── deploy-stacks.sh     # Deployment orchestration (690 lines)
│   │   ├── detect-removed-stacks.sh  # Stack removal detection (328 lines)
│   │   ├── cleanup-stack.sh     # Individual stack cleanup (87 lines)
│   │   ├── rollback-stacks.sh   # Rollback automation (495 lines)
│   │   ├── .shellcheckrc        # ShellCheck configuration
│   │   └── IMPLEMENTATION_GUIDE.md  # Refactoring documentation
│   └── testing/
│       ├── test-workflow.sh     # Workflow testing script
│       ├── validate-compose.sh  # Compose validation script
│       └── README.md            # Testing documentation
├── CLAUDE.md                    # This file - Claude Code guidance
├── README.md                    # Repository documentation
└── renovate.json                # Renovate configuration for dependency updates
```

### Dependency Management

The repository uses Renovate for automated dependency updates:
- GitHub Actions are automatically updated with minor/patch versions
- Major version updates are grouped separately for review

## Troubleshooting Workflows

### Common Workflow Issues

#### GitGuardian Scanning Failures

**Symptoms**: Lint workflow fails at GitGuardian step

**Solutions**:
1. Check `OP_SERVICE_ACCOUNT_TOKEN` is configured correctly
2. Verify GitGuardian API key exists in 1Password vault
3. Ensure 1Password service account has access to GitGuardian secrets

#### Deployment Connection Issues  

**Symptoms**: Deploy workflow fails to connect to deployment server

**Solutions**:
1. Verify `SSH_USER` and `SSH_HOST` secrets are configured
2. Check Tailscale OAuth credentials in 1Password
3. Ensure deployment server is accessible via Tailscale
4. Verify SSH key authentication is working
5. Check SSH retry logic in logs for connection details

#### Discord Notification Failures

**Symptoms**: Workflow completes but no Discord notifications

**Solutions**:
1. Check webhook URL format in 1Password: `op://Vault/Item/field`
2. Verify 1Password service account has access to Discord webhook secrets  
3. Test webhook URL manually
4. Check Discord channel permissions

#### Health Check Failures

**Symptoms**: Deployment succeeds but health checks fail or show incorrect counts

**Solutions**:
1. Verify stack-specific compose files are being used (`-f compose.yaml`)
2. Check health check retry logic settings (attempts and wait times)
3. Verify services have proper health check configurations
4. Check Docker Compose service dependencies
5. Review container logs for startup issues
6. Ensure health checks are using stack-specific paths

### Workflow Debugging

#### Enable Debug Logging

Add this to workflow calls for detailed logging:

```yaml
env:
  ACTIONS_STEP_DEBUG: true
  ACTIONS_RUNNER_DEBUG: true
```

#### Check Workflow Outputs

Monitor workflow outputs for troubleshooting:

```yaml
- name: Debug Outputs
  run: |
    echo "Deploy Status: ${{ needs.deploy.outputs.deploy_status }}"
    echo "Health Status: ${{ needs.deploy.outputs.health_status }}"
    echo "Healthy Stacks: ${{ needs.deploy.outputs.healthy_stacks }}"
```

#### SSH Connection Issues

Check SSH multiplexing and retry logic:
- Review `/tmp/retry.sh` execution in logs
- Check SSH ControlMaster configuration
- Verify connection persistence settings

## Performance Optimization

### Parallel Execution
- GitGuardian scanning and YAML linting run concurrently
- Stack deployments execute in parallel
- Matrix strategy for independent stack validation

### Caching Strategy
- Tailscale state cached per repository owner
- Deployment tools cached with version key
- SSH connections multiplexed for reuse

### Retry Logic
- SSH operations retry with exponential backoff
- Health checks use dynamic retry timing
- Deployment operations have configurable timeouts

# important-instruction-reminders
Do what has been asked; nothing more, nothing less.
NEVER create files unless they're absolutely necessary for achieving your goal.
ALWAYS prefer editing an existing file to creating a new one.
NEVER proactively create documentation files (*.md) or README files. Only create documentation files if explicitly requested by the User.