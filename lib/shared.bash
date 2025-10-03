#!/bin/bash
# shared.bash - Common utilities and functions for ArgoCD deployment plugin

# Plugin configuration
PLUGIN_PREFIX="ARGOCD_DEPLOYMENT"

# Strict error handling
set -euo pipefail

# Logging functions with consistent formatting
log_error() {
    echo "❌ Error: $*" >&2
}

log_warning() {
    echo "⚠️  Warning: $*" >&2
}

log_info() {
    echo "ℹ️  $*"
}

log_success() {
    echo "✅ $*"
}

log_debug() {
    if [[ "${BUILDKITE_PLUGIN_DEBUG:-false}" == "true" ]]; then
        echo "🐛 Debug: $*" >&2
    fi
}

# Error trap setup for better debugging
setup_error_trap() {
    trap 'log_error "Script failed at line $LINENO with exit code $?"' ERR
}

# Enable debug mode if requested
enable_debug_if_requested() {
    if [[ "${BUILDKITE_PLUGIN_DEBUG:-false}" == "true" ]]; then
        log_info "Debug mode enabled"
        set -x
    fi
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Validate required configuration with descriptive error messages
validate_required_config() {
    local config_name="$1"
    local config_value="$2"
    
    if [[ -z "$config_value" ]]; then
        log_error "$config_name is required but not provided"
        log_info "Please check your plugin configuration and ensure all required parameters are set"
        exit 1
    fi
}

# Check dependencies
check_dependencies() {
    local missing_deps=()
    
    for dep in "$@"; do
        if ! command_exists "$dep"; then
            missing_deps+=("$dep")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        log_info "Please install the missing tools before running this plugin"
        exit 1
    fi
}

# Metadata helpers
set_metadata() {
    local key="$1"
    local value="$2"
    buildkite-agent meta-data set "$key" "$value" || true
}

get_metadata() {
    local key="$1"
    local default="${2:-}"
    buildkite-agent meta-data get "$key" --default "$default" 2>/dev/null || echo "$default"
}

# Cleanup function for temporary files
cleanup_temp_files() {
    local temp_dir="${1:-}"
    if [[ -n "$temp_dir" && -d "$temp_dir" ]]; then
        log_debug "Cleaning up temporary directory: $temp_dir"
        rm -rf "$temp_dir"
    fi
}

# Safe temporary file creation
create_temp_file() {
    local prefix="${1:-buildkite-plugin}"
    mktemp "/tmp/${prefix}-XXXXXX"
}

create_temp_dir() {
    local prefix="${1:-buildkite-plugin}"
    mktemp -d "/tmp/${prefix}-XXXXXX"
}

# Buildkite Plugin configuration reader
# Reads plugin configuration values with fallback defaults
plugin_read_config() {
    local var="BUILDKITE_PLUGIN_${PLUGIN_PREFIX}_${1}"
    local default="${2:-}"
    echo "${!var:-$default}"
}
