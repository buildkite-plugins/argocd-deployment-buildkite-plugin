#!/bin/bash
# health.bash - Application health monitoring functions


# Monitor application health with configurable retry behavior
monitor_application_health() {
    local app_name="$1"
    local retry_enabled="${2:-true}"  # Default to true for backward compatibility
    
    if [[ "$retry_enabled" == "false" ]]; then
        log_info "Manual rollback mode - checking health once without retry"
        check_application_health "$app_name"
        local health_exit_code=$?
        
        if [[ $health_exit_code -eq 0 ]]; then
            log_success "Application health check passed"
            return 0
        else
            log_error "Application is unhealthy - manual intervention required"
            return $health_exit_code
        fi
    fi
    
    # Auto rollback mode - full health monitoring with retries
    local health_check_interval
    local health_check_timeout
    
    health_check_interval=$(plugin_read_config HEALTH_CHECK_INTERVAL "30")
    health_check_timeout=$(plugin_read_config HEALTH_CHECK_TIMEOUT "300")
    
    # Validate health check parameters
    if [[ $health_check_interval -lt 10 || $health_check_interval -gt 300 ]]; then
        log_warning "Invalid health_check_interval: $health_check_interval. Using default: 30"
        health_check_interval=30
    fi
    
    if [[ $health_check_timeout -lt 60 || $health_check_timeout -gt 1800 ]]; then
        log_warning "Invalid health_check_timeout: $health_check_timeout. Using default: 300"
        health_check_timeout=300
    fi
    
    log_info "Starting health monitoring for $app_name (auto rollback mode)"
    log_info "Health check interval: ${health_check_interval}s, timeout: ${health_check_timeout}s"
    
    local start_time
    start_time=$(date +%s)
    local end_time
    end_time=$((start_time + health_check_timeout))
    
    local check_count=0
    
    while [[ $(date +%s) -lt $end_time ]]; do
        check_count=$((check_count + 1))
        log_debug "Health check attempt #$check_count"
        
        check_application_health "$app_name"
        local health_exit_code=$?
        
        if [[ $health_exit_code -eq 0 ]]; then
            log_success "Application health check passed after $check_count attempts"
            return 0
        elif [[ $health_exit_code -eq 2 ]]; then
            log_error "Application is degraded - failing fast instead of waiting for timeout"
            return 2
        fi
        
        local remaining_time=$((end_time - $(date +%s)))
        if [[ $remaining_time -gt 0 ]]; then
            log_info "Waiting ${health_check_interval}s before next health check (${remaining_time}s remaining)..."
            sleep "$health_check_interval"
        fi
    done
    
    log_error "Health check timeout reached after $check_count attempts (application never became healthy)"
    return 1
}

# Check application health status via ArgoCD API
check_application_health() {
    local app_name="$1"
    
    log_debug "Checking health status for $app_name"
    
    # Get application status via ArgoCD API
    local app_status
    app_status=$(argocd app get "$app_name" --output json 2>/dev/null | jq -r '.status.health.status // "Unknown"' 2>/dev/null || echo "Unknown")
    
    log_debug "Application $app_name health status: $app_status"
    
    case "$app_status" in
        "Healthy")
            log_debug "Application is healthy"
            return 0
            ;;
        "Progressing")
            log_debug "Application is progressing..."
            return 1
            ;;
        "Degraded")
            log_error "Application is degraded - triggering immediate rollback"
            return 2  # Special exit code for immediate failure
            ;;
        "Suspended")
            log_warning "Application is suspended"
            return 1
            ;;
        "Missing")
            log_error "Application resources are missing"
            return 2
            ;;
        *)
            log_warning "Unknown application status: $app_status"
            return 1
            ;;
    esac
}

# Check if application exists
application_exists() {
    local app_name="$1"
    
    log_debug "Checking if application $app_name exists"
    
    if argocd app get "$app_name" --output json >/dev/null 2>&1; then
        log_debug "Application $app_name exists"
        return 0
    else
        log_error "Application $app_name does not exist or is not accessible"
        return 1
    fi
}

