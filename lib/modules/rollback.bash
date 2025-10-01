#!/bin/bash
# rollback.bash - Rollback logic and smart auto-sync management


# Execute rollback operation with proper parameter handling
execute_rollback() {
    local app_name="$1"
    local target_revision="$2"  # History ID format
    local rollback_type="$3"    # "automatic" or "explicit"
    local log_file="$4"         # Fixed: Include log_file parameter to prevent bash context errors
    
    log_info "Starting $rollback_type rollback for ArgoCD application: $app_name"
    log_info "Target revision: $target_revision"
    
    # Create rollback log if not provided
    if [[ -z "$log_file" ]]; then
        log_file=$(create_deployment_log "$app_name" "rollback" "in_progress")
    fi
    
    # Get current deployment for logging purposes
    local stable_revision
    stable_revision=$(get_stable_deployment "$app_name")
    
    if [[ -z "$target_revision" || "$target_revision" == "unknown" ]]; then
        log_error "No target revision available"
        echo "=== Rollback Result: FAILED - No target revision ===" >> "$log_file"
        handle_log_collection_and_artifacts "$app_name" "$log_file"
        exit 1
    fi
    
    log_info "Rolling back to revision $target_revision..."
    
    # Store rollback metadata
    set_rollback_metadata "$app_name" "rolling_back" "" "$stable_revision" "$target_revision"
    
    # Execute rollback with smart auto-sync management
    local rollback_success=false
    local timeout
    timeout=$(plugin_read_config TIMEOUT "300")
    
    # Check if auto-sync is enabled and manage it properly
    local auto_sync_was_enabled=false
    if is_auto_sync_enabled "$app_name"; then
        log_info "Auto-sync detected - temporarily disabling for proper rollback"
        auto_sync_was_enabled=true
        
        if ! disable_auto_sync "$app_name" "$log_file"; then
            log_warning "Failed to disable auto-sync, proceeding with rollback anyway..."
            auto_sync_was_enabled=false
        else
            log_success "Auto-sync disabled successfully"
        fi
    fi
    
    # Perform rollback using helper function
    log_info "Performing rollback to revision: $target_revision"
    {
        echo "=== Rollback Command Output ==="
        echo "Looking up history ID for revision: $target_revision"
        argocd app history "$app_name" | head -11
    } >> "$log_file"
    
    # Use helper function to look up deployment history ID and execute rollback
    local history_id
    if history_id=$(lookup_deployment_history_id "$app_name" "$target_revision"); then
        if execute_argocd_rollback "$app_name" "$history_id" "$timeout" "$log_file"; then
            log_success "Rollback command succeeded"
            
            # Wait for rollback to complete (only for automatic rollback)
            if [[ "$rollback_type" == "automatic" ]]; then
                log_info "Waiting for rollback to complete..."
                if wait_for_argocd_operation "$app_name" "$timeout" "$log_file"; then
                    log_success "Rollback completed successfully"
                    rollback_success=true
                else
                    log_error "Rollback wait failed"
                    rollback_success=false
                fi
            else
                # For explicit rollbacks, don't wait - user initiated it deliberately
                log_success "Explicit rollback command completed"
                rollback_success=true
            fi
        else
            log_error "ArgoCD rollback command failed"
            rollback_success=false
        fi
    else
        log_error "Failed to lookup deployment history ID for revision: $target_revision"
        rollback_success=false
    fi
    
    # Re-enable auto-sync if it was originally enabled
    if [[ "$auto_sync_was_enabled" == "true" ]]; then
        log_info "Re-enabling auto-sync..."
        if enable_auto_sync "$app_name" "$log_file"; then
            log_success "Auto-sync re-enabled successfully"
        else
            log_warning "Failed to re-enable auto-sync"
        fi
    fi
    
    # Handle rollback result
    if [[ "$rollback_success" == "true" ]]; then
        # Update metadata with success
        set_deployment_metadata "$app_name" "rolled_back" "rollback_success" "$target_revision"
        
        # Update log with success
        echo "=== Rollback Result: SUCCESS ===" >> "$log_file"
        echo "Rolled back to revision: $target_revision" >> "$log_file"
        
        create_rollback_annotation "$app_name" "$stable_revision" "$target_revision"
        
        # Collect logs and upload artifacts
        handle_log_collection_and_artifacts "$app_name" "$log_file"
        
        # Send success notification (avoid recursive calls)
        if [[ "$rollback_type" == "automatic" ]]; then
            send_notification "$app_name" "rollback_success_auto" "$stable_revision" "$target_revision"
        else
            send_notification "$app_name" "rollback_success_manual" "$stable_revision" "$target_revision"
        fi
        
        log_success "Rollback successful"
        log_info "Rolled from: $stable_revision"
        log_info "Rolled to:   $target_revision"
    else
        # Update metadata with failure
        set_deployment_metadata "$app_name" "rollback_failed" "rollback_failed"
        
        # Update log with failure
        echo "=== Rollback Result: FAILED ===" >> "$log_file"
        
        # Collect logs and upload artifacts even on failure
        handle_log_collection_and_artifacts "$app_name" "$log_file"
        
        # Send failure notification (avoid recursive calls)
        if [[ "$rollback_type" == "automatic" ]]; then
            send_notification "$app_name" "rollback_failed_auto" "$stable_revision" "$target_revision"
        else
            send_notification "$app_name" "rollback_failed_manual" "$stable_revision" "$target_revision"
        fi
        
        log_error "Rollback failed"
        exit 1
    fi
}

# Handle deployment failure with appropriate rollback strategy
handle_deployment_failure() {
    local app_name="$1"
    local rollback_mode="$2"
    local previous_revision="$3"
    local log_file="$4"
    local failure_reason="$5"
    
    log_error "Handling deployment failure for $app_name"
    log_info "Rollback mode: $rollback_mode, Failure reason: $failure_reason"
    
    # Update metadata with failure
    set_deployment_metadata "$app_name" "failed" "failed"
    set_metadata "deployment:argocd:${app_name}:failure_reason" "$failure_reason"
    
    # Update log with failure
    echo "=== Deployment Result: FAILED - $failure_reason ===" >> "$log_file"
    
    # Create failure annotation
    create_deployment_annotation "$app_name" "$previous_revision" "$previous_revision" "failed"
    
    # If no previous revision available, try to get from ArgoCD history as fallback
    if [[ -z "$previous_revision" || "$previous_revision" == "unknown" ]]; then
        log_debug "No previous revision available, checking ArgoCD history as fallback..."
        previous_revision=$(get_previous_deployment "$app_name" 2>/dev/null)
    fi
    
    if [[ -z "$previous_revision" || "$previous_revision" == "unknown" ]]; then
        log_error "No previous version available for rollback"
        handle_log_collection_and_artifacts "$app_name" "$log_file"
        exit 1
    fi
    
    # Handle rollback based on mode
    if [[ "$rollback_mode" == "auto" ]]; then
        log_info "Auto rollback mode: initiating automatic rollback..."
        
        # Send notification about deployment failure and auto rollback in progress
        send_notification "$app_name" "deployment_failed_auto" "current" "$previous_revision"
        
        execute_rollback "$app_name" "$previous_revision" "automatic" "$log_file"
    else
        # rollback_mode == "manual"
        log_info "Manual rollback mode: injecting block step for user decision..."
        
        inject_rollback_decision_block "$app_name" "$previous_revision"
        
        # Collect logs and upload artifacts for manual review
        handle_log_collection_and_artifacts "$app_name" "$log_file"
        
        # Send notification about failure (avoid recursive calls)
        send_notification "$app_name" "deployment_failed_manual" "current" "$previous_revision"
        
        log_info "Pipeline paused for manual rollback decision"
        # Exit successfully - the block step will handle the rollback decision
        exit 0
    fi
}

# Inject rollback decision block step for manual intervention
inject_rollback_decision_block() {
    local app_name="$1"
    local previous_revision="$2"
    
    log_info "Injecting rollback decision block step for $app_name..."
    
    # Pre-compute everything while in plugin context (Layer 2)
    local rollback_target
    if [[ -n "$previous_revision" && "$previous_revision" != "unknown" ]]; then
        rollback_target="$previous_revision"
    else
        # Get the current stable deployment that's actually running in the cluster
        rollback_target=$(get_stable_deployment "$app_name")
    fi
    
    # Get the ArgoCD history ID NOW while we have plugin functions
    local history_id=""
    if [[ "$rollback_target" != "unknown" ]]; then
        history_id="$rollback_target"
    fi
    
    # Get connection details NOW
    local timeout
    local timestamp
    timeout=$(plugin_read_config TIMEOUT "300")
    
    # Pre-compute timestamp to avoid command substitution in Layer 3
    timestamp=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
    
    # Validate we have what we need for rollback
    if [[ "$rollback_target" == "unknown" || -z "$history_id" ]]; then
        log_error "Cannot determine rollback target for manual rollback"
        log_info "rollback_target: $rollback_target"
        log_info "history_id: $history_id"
        log_info "This usually means:"
        log_info "- No previous deployment exists"
        log_info "- ArgoCD history lookup failed"
        log_info "- Application has never been successfully deployed"
        log_info ""
        log_info "Manual rollback requires a valid previous deployment to rollback to."
        return 1
    fi
    
    log_success "Pre-computed rollback: target=$rollback_target, history_id=$history_id"
    
    # Create a temporary file for the pipeline YAML
    local pipeline_file
    pipeline_file=$(create_temp_file "rollback-pipeline")
    
    # Generate the pipeline YAML with pre-baked values
    cat > "$pipeline_file" << EOF
steps:
  - block: "Deployment Failed - Choose Action"
    key: "deployment-failed-choose-action"
    prompt: |
      🚨 DEPLOYMENT FAILED: $app_name
      
      Please choose your next action:
      
      🔄 ROLLBACK (RECOMMENDED)
      Rollback to previous stable deployment (Target: $rollback_target)
      Safer option for production environments
      
      ❌ ACCEPT FAILURE  
      Keep current failed state for debugging
      Manual investigation required
    fields:
      - select: "Action"
        key: "rollback_decision"
        hint: "What would you like to do?"
        required: true
        default: "rollback"
        options:
          - label: "🔄 Rollback to Previous Stable Version"
            value: "rollback"
          - label: "❌ Accept Failure (No Rollback)"
            value: "accept"

  - label: "Execute User Decision"
    depends_on: "deployment-failed-choose-action"
    agents:
      queue: kubernetes
    command: |
      echo "--- Checking user decision from block step"
      
      # Small delay to ensure metadata is saved
      sleep 2
       
      # Use metadata directly in conditional without variable assignment
      if buildkite-agent meta-data get "rollback_decision" --default "" | grep -q "^rollback\$"; then
        echo "User selected: rollback"
        echo "--- Executing rollback for $app_name"
        echo "Target revision: $rollback_target"
        echo "History ID: $history_id"
        
        # Authenticate with ArgoCD first (use Buildkite plugin environment variables)
        echo "🔐 Authenticating with ArgoCD server..."
        if ! argocd login "\$BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_ARGOCD_SERVER" --username "\$BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_ARGOCD_USERNAME" --password "\$ARGOCD_PASSWORD" --insecure >/dev/null 2>&1; then
          echo "❌ Failed to authenticate with ArgoCD"
          exit 1
        fi
        
        # Direct rollback with pre-computed values
        echo "🔄 Executing rollback command..."
        
        # Execute rollback and capture result
        if argocd app rollback "$app_name" "$history_id" --timeout "$timeout"; then
          rollback_exit_code=0
          echo "Debug: rollback_exit_code=0"
          echo "Rollback command completed successfully"
          
          # Wait for rollback to complete and sync
          echo "🔄 Waiting for rollback to complete and sync..."
          if argocd app wait "$app_name" --timeout "$timeout" --health; then
            echo "✅ Rollback sync completed successfully"
            
            # Create success annotation
            printf "**Manual Rollback Successful**\n\n**Application:** %s\n\n**Rolled back to:** %s\n\n**History ID:** %s\n\n**Timestamp:** %s\n\nThe application has been restored to the previous stable version." "$app_name" "$rollback_target" "$history_id" "$timestamp" | buildkite-agent annotate --style "success" --context "manual-rollback-$app_name" || true
              
            # Update metadata
            buildkite-agent meta-data set "deployment:argocd:$app_name:result" "rollback_success"
            buildkite-agent meta-data set "deployment:argocd:$app_name:status" "rolled_back"
            
          else
            echo "❌ Rollback wait failed - application did not become healthy"
            
            # Create failure annotation for wait failure
            printf "**Manual Rollback Wait Failed**\n\n**Application:** %s\n\n**Target:** %s\n\n**History ID:** %s\n\n**Timestamp:** %s\n\nRollback command succeeded but application did not become healthy. Manual investigation required." "$app_name" "$rollback_target" "$history_id" "$timestamp" | buildkite-agent annotate --style "error" --context "manual-rollback-wait-failed-$app_name" || true
              
            # Update metadata
            buildkite-agent meta-data set "deployment:argocd:$app_name:result" "rollback_failed"
            buildkite-agent meta-data set "deployment:argocd:$app_name:status" "rollback_failed"
            
            exit 1
          fi
          
        else
          rollback_exit_code=1
          echo "Debug: rollback_exit_code=1"
          echo "❌ Rollback command failed"
          
          # Create failure annotation
          printf "**Manual Rollback Failed**\n\n**Application:** %s\n\n**Target:** %s\n\n**History ID:** %s\n\n**Timestamp:** %s\n\nManual investigation may be required." "$app_name" "$rollback_target" "$history_id" "$timestamp" | buildkite-agent annotate --style "error" --context "manual-rollback-failed-$app_name" || true
            
          # Update metadata
          buildkite-agent meta-data set "deployment:argocd:$app_name:result" "rollback_failed"
          buildkite-agent meta-data set "deployment:argocd:$app_name:status" "rollback_failed"
          
          exit 1
        fi
        
      elif buildkite-agent meta-data get "rollback_decision" --default "" | grep -q "^accept\$"; then
        echo "User selected: accept"
        echo "--- User chose to accept deployment failure"
        
        # Create annotation for accepted failure
        printf "**Deployment Failure Accepted**\n\n**Application:** %s\n\n**Action:** User chose to accept failure and skip rollback\n\n**Status:** Failed deployment left in place for debugging\n\n**Timestamp:** %s\n\nManual investigation and cleanup may be required." "$app_name" "$timestamp" | buildkite-agent annotate --style "warning" --context "accept-failure-$app_name" || true
        
        # Update metadata
        buildkite-agent meta-data set "deployment:argocd:$app_name:result" "failure_accepted"
        buildkite-agent meta-data set "deployment:argocd:$app_name:status" "failed_accepted"
        
        echo "Failure accepted - no rollback performed"
        
      else
        echo "❌ Error: No valid decision found in metadata"
        echo "Expected 'rollback' or 'accept', but neither pattern matched"
        echo "Raw metadata value:"
        buildkite-agent meta-data get "rollback_decision" --default "EMPTY" || echo "Failed to get metadata"
        echo "Please complete the block step first"
        exit 1
      fi
EOF
    
    log_info "Uploading rollback decision pipeline..."
    local upload_output
    if upload_output=$(buildkite-agent pipeline upload "$pipeline_file" 2>&1); then
        log_success "Successfully injected rollback decision steps"
        rm -f "$pipeline_file"
        return 0
    else
        log_error "Failed to inject rollback decision steps - pipeline upload failed"
        log_error "Upload error: $upload_output"
        rm -f "$pipeline_file"
        return 1
    fi
}
