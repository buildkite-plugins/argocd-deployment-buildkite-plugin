#!/bin/bash
# argocd.bash - ArgoCD API operations and authentication


# ArgoCD authentication setup
setup_argocd_auth() {
    log_info "Setting up ArgoCD authentication..."
    
    local argocd_server
    local argocd_username
    local argocd_password
    
    argocd_server=$(plugin_read_config ARGOCD_SERVER "${ARGOCD_SERVER:-}")
    argocd_username=$(plugin_read_config ARGOCD_USERNAME "${ARGOCD_USERNAME:-}")
    argocd_password="${ARGOCD_PASSWORD:-}"
    
    validate_required_config "ArgoCD server URL" "$argocd_server"
    validate_required_config "ArgoCD username" "$argocd_username"
    validate_required_config "ArgoCD password" "$argocd_password"
    
    log_info "Authenticating with ArgoCD server: $argocd_server"
    
    if ! argocd login "$argocd_server" --username "$argocd_username" --password "$argocd_password" --insecure >/dev/null 2>&1; then
        log_error "Failed to authenticate with ArgoCD server"
        log_info "Please check your credentials and server connectivity"
        exit 1
    fi
    
    log_success "ArgoCD authentication successful"
}

# Validate ArgoCD requirements
validate_requirements() {
    log_info "Validating plugin requirements..."
    
    check_dependencies argocd jq
    
    log_success "All requirements validated"
}

# Get current stable deployment (History ID format)
get_stable_deployment() {
    local app_name="$1"
    
    log_debug "Getting current deployment for $app_name"
    
    # Get the most recent deployment from ArgoCD history (regardless of health status)
    local current_history_id
    current_history_id=$(argocd app history "$app_name" 2>/dev/null | tail -1 | awk '{print $1}' 2>/dev/null || echo "unknown")
    
    if [[ "$current_history_id" == "unknown" || -z "$current_history_id" || "$current_history_id" == "ID" ]]; then
        log_warning "Could not determine current deployment for $app_name from history"
        echo "unknown"
        return 1
    fi
    
    log_debug "Current deployment: $current_history_id"
    echo "$current_history_id"
}

# Get previous deployment from metadata or ArgoCD history
get_previous_deployment() {
    local app_name="$1"
    
    log_debug "Getting previous stable deployment for $app_name"
    
    # Try to get from stored metadata first, but validate it exists in current history
    local previous_revision
    previous_revision=$(get_metadata "deployment:argocd:${app_name}:previous_version" "")
    
    log_debug "Metadata lookup result: '$previous_revision'"
    
    if [[ -n "$previous_revision" && "$previous_revision" != "unknown" ]]; then
        log_debug "Found previous revision in metadata: $previous_revision"
        
        # Validate that this revision still exists in ArgoCD history
        local history_output
        history_output=$(argocd app history "$app_name" 2>/dev/null | tail -n +2)
        
        log_debug "Current ArgoCD history (first 10 lines):"
        log_debug "$(echo "$history_output" | head -10)"
        
        if echo "$history_output" | grep -q "^$previous_revision "; then
            log_debug "Metadata revision $previous_revision validated in ArgoCD history - USING METADATA"
            echo "$previous_revision"
            return 0
        else
            log_warning "Metadata revision $previous_revision not found in current ArgoCD history - using fresh history"
            log_debug "DEBUG: Falling through to ArgoCD history lookup"
            # Fall through to ArgoCD history lookup
        fi
    else
        log_debug "DEBUG: No valid metadata found, going to ArgoCD history lookup"
    fi
    
    # Fallback: Get most recent entry from ArgoCD history (any previous deployment)
    log_debug "Querying ArgoCD history for $app_name"
    local history_output
    history_output=$(argocd app history "$app_name" 2>/dev/null | tail -n +2)
    
    if [[ -z "$history_output" ]]; then
        log_warning "No deployment history available for $app_name"
        echo "unknown"
        return 1
    fi
    log_debug "Available ArgoCD history entries: $(echo "$history_output" | wc -l) total"
    
    # Try to find the last successful deployment from our stored metadata
    # Process history in reverse order (newest to oldest) to find most recent success
    local previous_history_id=""
    log_debug "Searching for successful deployments in metadata (newest first)..."
    while IFS= read -r line; do
        local history_id
        history_id=$(echo "$line" | awk '{print $1}' | grep -E '^[0-9]+$' || echo "")
        if [[ -n "$history_id" ]]; then
            # Check if this deployment was marked as successful in our metadata
            local deployment_result
            deployment_result=$(get_metadata "deployment:argocd:${app_name}:history_${history_id}:result" "")
            log_debug "Checking history ID $history_id, metadata result: '$deployment_result'"
            if [[ "$deployment_result" == "success" ]]; then
                log_debug "Found successful deployment in history: $history_id"
                previous_history_id="$history_id"
                break
            fi
        fi
    done <<< "$(echo "$history_output" | tac)"
    
    # If no successful deployment found in metadata, fall back to penultimate deployment
    if [[ -z "$previous_history_id" ]]; then
        log_debug "Using previous deployment from filtered history"
        # Get the second-to-last entry (previous deployment, not current)
        previous_history_id=$(echo "$history_output" | tail -2 | head -1 | awk '{print $1}' | grep -E '^[0-9]+$' || echo "")
        log_debug "Selected previous deployment: '$previous_history_id'"
        
        # If second-to-last entry is empty, try third-to-last entry as fallback
        if [[ -z "$previous_history_id" ]]; then
            previous_history_id=$(echo "$history_output" | tail -3 | head -1 | awk '{print $1}' | grep -E '^[0-9]+$' || echo "")
            log_debug "Third-to-last entry fallback: '$previous_history_id'"
        fi
    fi
    
    if [[ -z "$previous_history_id" ]]; then
        log_warning "Could not find any valid deployment in history for $app_name"
        log_debug "History format: $(echo "$history_output" | head -10)"
        echo "unknown"
        return 1
    fi
    
    log_debug "Found previous deployment in history: $previous_history_id"
    echo "$previous_history_id"
}

# Lookup deployment history ID from revision (Git SHA or History ID)
lookup_deployment_history_id() {
    local app_name="$1"
    local target_revision="$2"
    local verbose="${3:-false}"  # Optional verbose flag, defaults to false
    
    if [[ "$verbose" == "true" ]]; then
        log_debug "Looking up history ID for revision: $target_revision"
    fi
    
    # If it's already a history ID (numeric), return it
    if [[ "$target_revision" =~ ^[0-9]+$ ]]; then
        log_debug "Target revision is already a history ID: $target_revision"
        echo "$target_revision"
        return 0
    fi
    
    # Look up in ArgoCD history
    local history_output
    history_output=$(argocd app history "$app_name" 2>/dev/null | tail -n +2)
    
    if [[ -z "$history_output" ]]; then
        if [[ "$verbose" == "true" ]]; then
            log_error "No deployment history available for $app_name"
        fi
        return 1
    fi
    
    # Search for matching revision (either full SHA or short SHA)
    local history_id
    history_id=$(echo "$history_output" | awk -v target="$target_revision" '
        $3 ~ target || target ~ $3 { print $1; exit }
    ' | grep -E '^[0-9]+$' || echo "")
    
    if [[ -z "$history_id" ]]; then
        if [[ "$verbose" == "true" ]]; then
            log_error "Could not find history ID for revision: $target_revision"
            echo "ℹ️  Available history:" >&2
            echo "$history_output" >&2
        fi
        return 1
    fi
    
    if [[ "$verbose" == "true" ]]; then
        log_debug "Found history ID: $history_id for revision: $target_revision"
    fi
    echo "$history_id"
}

# Execute ArgoCD sync operation
execute_argocd_sync() {
    local app_name="$1"
    local timeout="$2"
    local log_file="$3"
    
    log_info "Executing ArgoCD sync for $app_name"
    
    {
        echo "=== Deployment Command Output ==="
        echo "Command: argocd app sync $app_name --timeout $timeout"
        echo "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    } >> "$log_file"
    
    set +e
    argocd app sync "$app_name" --timeout "$timeout" >> "$log_file" 2>&1
    local sync_exit_code=$?
    set -e
    
    echo "Exit code: $sync_exit_code" >> "$log_file"
    
    if [[ $sync_exit_code -eq 0 ]]; then
        log_success "ArgoCD sync completed successfully"
    else
        log_error "ArgoCD sync failed with exit code: $sync_exit_code"
    fi
    
    return "$sync_exit_code"
}

# Execute ArgoCD rollback operation
execute_argocd_rollback() {
    local app_name="$1"
    local history_id="$2"
    local timeout="$3"
    local log_file="$4"
    
    log_info "Executing ArgoCD rollback for $app_name to history ID: $history_id"
    
    {
        echo "=== Rollback Command Output ==="
        echo "Command: argocd app rollback $app_name $history_id --timeout $timeout"
        echo "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    } >> "$log_file"
    
    set +e
    argocd app rollback "$app_name" "$history_id" --timeout "$timeout" >> "$log_file" 2>&1
    local rollback_exit_code=$?
    set -e
    
    echo "Exit code: $rollback_exit_code" >> "$log_file"
    
    if [[ $rollback_exit_code -eq 0 ]]; then
        log_success "ArgoCD rollback completed successfully"
    else
        log_error "ArgoCD rollback failed with exit code: $rollback_exit_code"
    fi
    
    return "$rollback_exit_code"
}

# Wait for ArgoCD operation to complete
wait_for_argocd_operation() {
    local app_name="$1"
    local timeout="$2"
    local log_file="$3"
    
    log_info "Waiting for ArgoCD operation to complete for $app_name"
    
    {
        echo "=== Wait Command Output ==="
        echo "Command: argocd app wait $app_name --health --timeout $timeout"
        echo "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    } >> "$log_file"
    
    set +e
    argocd app wait "$app_name" --health --timeout "$timeout" >> "$log_file" 2>&1
    local wait_exit_code=$?
    set -e
    
    echo "Exit code: $wait_exit_code" >> "$log_file"
    
    if [[ $wait_exit_code -eq 0 ]]; then
        log_success "ArgoCD operation completed successfully"
    else
        log_error "ArgoCD operation wait failed with exit code: $wait_exit_code"
    fi
    
    return "$wait_exit_code"
}

# Manage auto-sync policy
disable_auto_sync() {
    local app_name="$1"
    local log_file="$2"
    
    log_info "Disabling auto-sync for $app_name"
    
    {
        echo "=== Disabling Auto-Sync ==="
        echo "Command: argocd app set $app_name --sync-policy manual"
        echo "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    } >> "$log_file"
    
    set +e
    argocd app set "$app_name" --sync-policy manual >> "$log_file" 2>&1
    local disable_exit_code=$?
    set -e
    
    echo "Exit code: $disable_exit_code" >> "$log_file"
    
    if [[ $disable_exit_code -eq 0 ]]; then
        log_success "Auto-sync disabled successfully"
        return 0
    else
        log_warning "Failed to disable auto-sync (exit code: $disable_exit_code)"
        return "$disable_exit_code"
    fi
}

enable_auto_sync() {
    local app_name="$1"
    local log_file="$2"
    
    log_info "Re-enabling auto-sync for $app_name"
    
    {
        echo "=== Re-enabling Auto-Sync ==="
        echo "Command: argocd app set $app_name --sync-policy automated"
        echo "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    } >> "$log_file"
    
    set +e
    argocd app set "$app_name" --sync-policy automated >> "$log_file" 2>&1
    local enable_exit_code=$?
    set -e
    
    echo "Exit code: $enable_exit_code" >> "$log_file"
    
    if [[ $enable_exit_code -eq 0 ]]; then
        log_success "Auto-sync re-enabled successfully"
        return 0
    else
        log_warning "Failed to re-enable auto-sync (exit code: $enable_exit_code)"
        return "$enable_exit_code"
    fi
}

# Check if auto-sync is enabled
is_auto_sync_enabled() {
    local app_name="$1"
    
    local sync_policy
    sync_policy=$(argocd app get "$app_name" -o json 2>/dev/null | jq -r '.spec.syncPolicy.automated // empty' || echo "")
    
    if [[ -n "$sync_policy" ]]; then
        log_debug "Auto-sync is enabled for $app_name"
        return 0
    else
        log_debug "Auto-sync is disabled for $app_name"
        return 1
    fi
}
