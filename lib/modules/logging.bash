#!/bin/bash
# logging.bash - Log collection and artifact management functions


# Create deployment log file with proper temporary file handling
create_deployment_log() {
    local app_name="$1"
    local operation="${2:-deploy}"  # deploy or rollback
    local status="${3:-in_progress}"
    
    log_debug "Creating deployment log for $app_name ($operation)"
    
    # Use mktemp with /tmp/ prefix for proper temporary file creation
    local log_file
    log_file=$(mktemp "/tmp/deployment-${app_name}-${operation}-XXXXXX.log" 2>/dev/null || mktemp)
    
    # Initialize log file with header
    {
        echo "=== ArgoCD $operation Log ==="
        echo "Application: $app_name"
        echo "Operation: $operation"
        echo "Status: $status"
        echo "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "Build: ${BUILDKITE_BUILD_NUMBER:-unknown}"
        echo "Pipeline: ${BUILDKITE_PIPELINE_SLUG:-unknown}"
        echo "Branch: ${BUILDKITE_BRANCH:-unknown}"
        echo "================================"
        echo ""
    } > "$log_file"
    
    log_debug "Created deployment log: $log_file"
    echo "$log_file"
}

# Collect ArgoCD application logs
collect_app_logs() {
    local app_name="$1"
    local log_lines="${2:-1000}"
    
    log_info "Collecting ArgoCD application logs for $app_name" >&2
    
    # Use mktemp -d for temporary directory creation
    local log_dir
    log_dir=$(mktemp -d "/tmp/argocd-logs-${app_name}-XXXXXX")
    
    log_debug "Created log directory: $log_dir"
    
    # Validate log_lines parameter
    if [[ $log_lines -lt 100 || $log_lines -gt 10000 ]]; then
        log_warning "Invalid log_lines: $log_lines. Using default: 1000"
        log_lines=1000
    fi
    
    # Collect pod logs via ArgoCD
    log_info "Collecting pod logs via ArgoCD (${log_lines} lines)..." >&2
    local pod_log_file="$log_dir/pod-logs.log"
    
    {
        echo "=== Pod Logs (via ArgoCD) ==="
        echo "Application: $app_name"
        echo "Lines: $log_lines"
        echo "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "================================"
        echo ""
    } > "$pod_log_file"
    
    if argocd app logs "$app_name" --tail "$log_lines" >> "$pod_log_file" 2>&1; then
        log_success "Pod logs collected via ArgoCD" >&2
    else
        log_warning "Failed to collect pod logs" >&2
        echo "Failed to collect pod logs" >> "$pod_log_file"
    fi
    
    # Collect ArgoCD application status
    log_info "Collecting application status..." >&2
    local status_file="$log_dir/app-status.json"
    
    if argocd app get "$app_name" --output json > "$status_file" 2>/dev/null; then
        log_success "Application status collected" >&2
    else
        log_warning "Failed to collect application status" >&2
        echo '{"error": "Failed to get application status"}' > "$status_file"
    fi
    
    # Create summary file
    local summary_file="$log_dir/summary.txt"
    {
        echo "=== Log Collection Summary ==="
        echo "Application: $app_name"
        echo "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "Log Directory: $log_dir"
        echo "Files Collected:"
        ls -la "$log_dir"
        echo ""
        echo "Total Size: $(du -sh "$log_dir" | cut -f1)"
    } > "$summary_file"
    
    log_success "Log collection completed for $app_name" >&2
    log_debug "Logs collected in: $log_dir" >&2
    
    # Only return the directory path, no other output
    echo "$log_dir"
}

# Upload artifacts to Buildkite
upload_artifacts() {
    local log_dir="$1"
    local app_name="$2"
    
    log_info "Uploading artifacts for $app_name"
    
    if [[ ! -d "$log_dir" ]]; then
        log_error "Log directory does not exist: $log_dir"
        return 1
    fi
    
    # Create a compressed archive for easier download
    local archive_name
    archive_name="argocd-logs-${app_name}-$(date +%Y%m%d-%H%M%S).tar.gz"
    local archive_path="/tmp/$archive_name"
    
    log_info "Creating compressed archive: $archive_name"
    
    if tar -czf "$archive_path" -C "$(dirname "$log_dir")" "$(basename "$log_dir")" 2>/dev/null; then
        log_success "Archive created: $archive_path"
        
        # Upload the archive
        if buildkite-agent artifact upload "$archive_path"; then
            log_success "Archive uploaded successfully"
        else
            log_warning "Failed to upload archive"
        fi
        
        # Clean up archive
        rm -f "$archive_path"
    else
        log_warning "Failed to create archive"
    fi
    
    log_success "Artifact upload completed for $app_name"
}

# Handle log collection and artifacts based on configuration
handle_log_collection_and_artifacts() {
    local app_name="$1"
    local deployment_log_file="$2"
    
    local collect_logs
    local upload_artifacts_enabled
    local log_lines
    
    collect_logs=$(plugin_read_config COLLECT_LOGS "false")
    upload_artifacts_enabled=$(plugin_read_config UPLOAD_ARTIFACTS "false")
    log_lines=$(plugin_read_config LOG_LINES "1000")
    
    log_debug "Log collection settings: collect_logs=$collect_logs, upload_artifacts=$upload_artifacts_enabled, log_lines=$log_lines"
    
    if [[ "$collect_logs" == "true" ]]; then
        log_info "Log collection enabled, gathering ArgoCD application logs..."
        local log_dir
        log_dir=$(collect_app_logs "$app_name" "$log_lines")
        
        if [[ "$upload_artifacts_enabled" == "true" ]]; then
            upload_artifacts "$log_dir" "$app_name"
        else
            log_info "Artifact upload disabled, logs collected in: $log_dir"
        fi
        
        # Clean up log directory after upload
        cleanup_temp_files "$log_dir"
    else
        log_info "Log collection disabled"
    fi
    
    # Clean up deployment log file
    if [[ -f "$deployment_log_file" ]]; then
        log_debug "Cleaning up deployment log file: $deployment_log_file"
        rm -f "$deployment_log_file"
    fi
}

# Set deployment metadata for tracking
set_deployment_metadata() {
    local app_name="$1"
    local status="$2"
    local result="${3:-}"
    local current_version="${4:-}"
    local previous_version="${5:-}"
    
    log_debug "Setting deployment metadata for $app_name: status=$status, result=$result"
    
    set_metadata "deployment:argocd:${app_name}:status" "$status"
    
    if [[ -n "$result" ]]; then
        set_metadata "deployment:argocd:${app_name}:result" "$result"
    fi
    
    if [[ -n "$current_version" ]]; then
        set_metadata "deployment:argocd:${app_name}:current_version" "$current_version"
    fi
    
    if [[ -n "$previous_version" ]]; then
        set_metadata "deployment:argocd:${app_name}:previous_version" "$previous_version"
    fi
    
    # Set timestamp
    set_metadata "deployment:argocd:${app_name}:timestamp" "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
}

# Set rollback metadata for tracking
set_rollback_metadata() {
    local app_name="$1"
    local status="$2"
    local result="${3:-}"
    local from_version="${4:-}"
    local to_version="${5:-}"
    
    log_debug "Setting rollback metadata for $app_name: status=$status, result=$result"
    
    set_metadata "rollback:argocd:${app_name}:status" "$status"
    
    if [[ -n "$result" ]]; then
        set_metadata "rollback:argocd:${app_name}:result" "$result"
    fi
    
    if [[ -n "$from_version" ]]; then
        set_metadata "rollback:argocd:${app_name}:from_version" "$from_version"
    fi
    
    if [[ -n "$to_version" ]]; then
        set_metadata "rollback:argocd:${app_name}:to_version" "$to_version"
    fi
    
    # Set timestamp
    set_metadata "rollback:argocd:${app_name}:timestamp" "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
}
