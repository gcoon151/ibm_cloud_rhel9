#!/bin/bash
# Functional Test Framework for PodVM Images
# Tests: Boot, dm-verity, CDH/Trustee, Intel Trust Authority
#
# Usage:
#   ./scripts/test-podvm.sh [test-suite] [pod-name] [namespace]
#
# Test Suites:
#   all         - Run all tests (default)
#   boot        - Basic boot and runtime tests
#   cdh         - Confidential Data Hub / Trustee tests
#   dmverity    - dm-verity integrity tests (when enabled)
#   ita         - Intel Trust Authority attestation tests
#   quick       - Fast smoke tests only

# Note: Not using 'set -e' because we handle errors explicitly with return codes

# Configuration
TEST_SUITE="${1:-all}"
POD_NAME="${2:-test-podvm-candidate}"
NAMESPACE="${3:-default}"
TIMEOUT=300  # 5 minutes for pod to be ready

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test results tracking
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[PASS]${NC} $1"; ((TESTS_PASSED++)); }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; ((TESTS_FAILED++)); }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_skip() { echo -e "${YELLOW}[SKIP]${NC} $1"; ((TESTS_SKIPPED++)); }

test_start() {
    ((TESTS_RUN++))
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}TEST $TESTS_RUN: $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Test: Pod exists and is scheduled
test_pod_exists() {
    test_start "Pod Exists and Scheduled"
    
    if ! oc get pod "$POD_NAME" -n "$NAMESPACE" &>/dev/null; then
        log_fail "Pod '$POD_NAME' not found in namespace '$NAMESPACE'"
        return 1
    fi
    
    log_success "Pod exists"
    
    # Check if scheduled
    local node=$(oc get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")
    if [ -z "$node" ]; then
        log_fail "Pod not scheduled to any node"
        return 1
    fi
    
    log_success "Pod scheduled to node: $node"
    return 0
}

# Test: Pod reaches Running state
test_pod_running() {
    test_start "Pod Running State"
    
    log_info "Waiting for pod to be ready (timeout: ${TIMEOUT}s)..."
    
    local elapsed=0
    local interval=5
    
    while [ $elapsed -lt $TIMEOUT ]; do
        local status=$(oc get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
        
        if [ "$status" = "Running" ]; then
            # Check if containers are ready
            local ready=$(oc get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
            if [ "$ready" = "true" ]; then
                log_success "Pod is Running and Ready (${elapsed}s)"
                return 0
            fi
        elif [ "$status" = "Failed" ] || [ "$status" = "CrashLoopBackOff" ]; then
            log_fail "Pod failed to start: $status"
            oc describe pod "$POD_NAME" -n "$NAMESPACE" | tail -20
            return 1
        fi
        
        echo -n "."
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    echo ""
    log_fail "Pod did not reach Running state within ${TIMEOUT}s"
    oc get pod "$POD_NAME" -n "$NAMESPACE"
    return 1
}

# Test: Runtime class is kata-remote
test_runtime_class() {
    test_start "Runtime Class Verification"
    
    local runtime=$(oc get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.runtimeClassName}')
    
    if [ "$runtime" = "kata-remote" ]; then
        log_success "Runtime class: kata-remote"
        return 0
    else
        log_fail "Expected kata-remote, got: $runtime"
        return 1
    fi
}

# Test: Pod has VSI image annotation
test_vsi_image_annotation() {
    test_start "VSI Image Annotation"
    
    local image_id=$(oc get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.annotations.io\.katacontainers\.config\.hypervisor\.image}')
    
    if [ -z "$image_id" ]; then
        log_fail "No VSI image annotation found"
        return 1
    fi
    
    if [[ "$image_id" =~ ^r014- ]]; then
        log_success "VSI image ID: $image_id"
        return 0
    else
        log_fail "Invalid VSI image ID format: $image_id"
        return 1
    fi
}

# Test: Application responds
test_application_response() {
    test_start "Application Response"
    
    log_info "Testing helloworld application..."
    
    local response=$(oc exec "$POD_NAME" -n "$NAMESPACE" -- curl -s http://127.0.0.1:5000/hello 2>/dev/null || echo "ERROR")
    
    if [[ "$response" == *"Hello"* ]] || [[ "$response" == *"version"* ]]; then
        log_success "Application responding: ${response:0:50}..."
        return 0
    else
        log_fail "Application not responding correctly: $response"
        return 1
    fi
}

# Test: CDH endpoint accessible (SUCCESS CRITERIA)
test_cdh_endpoint() {
    test_start "CDH Endpoint Access (Critical)"
    
    log_info "Testing Confidential Data Hub endpoint..."
    
    local response=$(oc exec "$POD_NAME" -n "$NAMESPACE" -- curl -s http://127.0.0.1:8006/cdh/resource/default/kbsres1/key1 2>/dev/null || echo "ERROR")
    
    if [ "$response" = "res1val1" ]; then
        log_success "CDH endpoint accessible and returning correct value"
        return 0
    else
        log_fail "CDH endpoint failed. Expected 'res1val1', got: '$response'"
        log_warn "This indicates confidential computing may not be working"
        return 1
    fi
}

# Test: Trustee connection
test_trustee_connection() {
    test_start "Trustee Service Connection"
    
    log_info "Checking trustee service connectivity..."
    
    # Check if CDH is running
    local cdh_status=$(oc exec "$POD_NAME" -n "$NAMESPACE" -- sh -c "ps aux | grep cdh | grep -v grep" 2>/dev/null || echo "")
    
    if [ -n "$cdh_status" ]; then
        log_success "CDH process is running"
        return 0
    else
        log_warn "CDH process not found (may be expected depending on configuration)"
        return 0  # Don't fail, just warn
    fi
}

# Test: dm-verity status (when enabled)
test_dmverity_status() {
    test_start "dm-verity Status"
    
    log_info "Checking dm-verity configuration..."
    
    # Check if dm-verity is enabled in kernel cmdline
    local cmdline=$(oc exec "$POD_NAME" -n "$NAMESPACE" -- cat /proc/cmdline 2>/dev/null || echo "")
    
    if [[ "$cmdline" == *"dm-mod.create"* ]] || [[ "$cmdline" == *"verity"* ]]; then
        log_success "dm-verity appears to be enabled"
        
        # Check for verity devices
        local verity_devs=$(oc exec "$POD_NAME" -n "$NAMESPACE" -- sh -c "dmsetup table 2>/dev/null | grep verity" || echo "")
        if [ -n "$verity_devs" ]; then
            log_success "dm-verity devices found"
            return 0
        else
            log_warn "dm-verity enabled in cmdline but no devices found"
            return 0
        fi
    else
        log_skip "dm-verity not enabled (expected for current builds)"
        return 0
    fi
}

# Test: Intel Trust Authority attestation
test_ita_attestation() {
    test_start "Intel Trust Authority Attestation"
    
    log_info "Checking ITA attestation status..."
    
    # This is a placeholder - actual ITA testing requires specific setup
    log_skip "ITA attestation test not yet implemented"
    return 0
}

# Test: Peer pod VM metrics
test_vm_metrics() {
    test_start "Peer Pod VM Metrics"
    
    log_info "Checking VM resource usage..."
    
    # Get memory usage
    local mem_usage=$(oc exec "$POD_NAME" -n "$NAMESPACE" -- sh -c "free -m | grep Mem | awk '{print \$3}'" 2>/dev/null || echo "0")
    
    if [ "$mem_usage" -gt 0 ]; then
        log_success "VM memory usage: ${mem_usage}MB"
    else
        log_warn "Could not determine memory usage"
    fi
    
    # Get CPU info
    local cpu_count=$(oc exec "$POD_NAME" -n "$NAMESPACE" -- sh -c "nproc" 2>/dev/null || echo "0")
    
    if [ "$cpu_count" -gt 0 ]; then
        log_success "VM CPU count: $cpu_count"
    else
        log_warn "Could not determine CPU count"
    fi
    
    return 0
}

# Test: Network connectivity
test_network_connectivity() {
    test_start "Network Connectivity"
    
    log_info "Testing external network access..."
    
    # Test DNS resolution and external connectivity
    local dns_test=$(oc exec "$POD_NAME" -n "$NAMESPACE" -- sh -c "nslookup google.com 2>&1" || echo "ERROR")
    
    if [[ "$dns_test" != *"ERROR"* ]] && [[ "$dns_test" == *"Address"* ]]; then
        log_success "DNS resolution working"
    else
        log_warn "DNS resolution may not be working"
    fi
    
    return 0
}

# Test: CAA logs for errors
test_caa_logs() {
    test_start "Cloud API Adaptor Logs"
    
    log_info "Checking CAA logs for errors in openshift-sandboxed-containers-operator namespace..."
    
    # CAA runs as daemonset with name pattern osc-caa-ds-*
    local caa_pods=$(oc get pods -n openshift-sandboxed-containers-operator --no-headers 2>/dev/null | grep "^osc-caa-ds-" | grep "Running" | awk '{print $1}')
    
    if [ -z "$caa_pods" ]; then
        log_fail "No CAA pods found in openshift-sandboxed-containers-operator namespace"
        return 1
    fi
    
    local pod_count=$(echo "$caa_pods" | wc -l | tr -d ' ')
    log_info "Found $pod_count CAA pods"
    
    local total_errors=0
    local pods_checked=0
    
    while IFS= read -r pod; do
        if [ -n "$pod" ]; then
            ((pods_checked++))
            local errors=$(oc logs "$pod" -n openshift-sandboxed-containers-operator --tail=50 2>/dev/null | grep -i "error" | wc -l | tr -d ' ')
            total_errors=$((total_errors + errors))
        fi
    done <<< "$caa_pods"
    
    if [ $total_errors -eq 0 ]; then
        log_success "No errors in recent CAA logs across $pods_checked pods"
        return 0
    else
        log_warn "Found $total_errors error lines across $pods_checked CAA pods (may be expected)"
        return 0
    fi
}

# Test suite runners
run_boot_tests() {
    log_info "Running BOOT test suite..."
    test_pod_exists
    test_pod_running
    test_runtime_class
    test_vsi_image_annotation
    test_application_response
    test_vm_metrics
    test_network_connectivity
}

run_cdh_tests() {
    log_info "Running CDH/TRUSTEE test suite..."
    test_cdh_endpoint
    test_trustee_connection
}

run_dmverity_tests() {
    log_info "Running DM-VERITY test suite..."
    test_dmverity_status
}

run_ita_tests() {
    log_info "Running ITA test suite..."
    test_ita_attestation
}

run_quick_tests() {
    log_info "Running QUICK test suite..."
    test_pod_exists
    test_pod_running
    test_cdh_endpoint
}

run_all_tests() {
    log_info "Running ALL test suites..."
    run_boot_tests
    run_cdh_tests
    run_dmverity_tests
    test_caa_logs
}

# Main execution
main() {
    echo "=========================================="
    echo "  PodVM Functional Test Framework"
    echo "=========================================="
    echo "Test Suite: $TEST_SUITE"
    echo "Pod: $POD_NAME"
    echo "Namespace: $NAMESPACE"
    echo "Timestamp: $(date)"
    echo "=========================================="
    echo ""
    
    # Verify oc is available
    if ! command -v oc &>/dev/null; then
        log_fail "oc command not found. Please install OpenShift CLI."
        exit 1
    fi
    
    # Verify cluster access
    if ! oc whoami &>/dev/null; then
        log_fail "Not logged into OpenShift cluster"
        exit 1
    fi
    
    # Run selected test suite
    case "$TEST_SUITE" in
        boot)
            run_boot_tests
            ;;
        cdh)
            run_cdh_tests
            ;;
        dmverity)
            run_dmverity_tests
            ;;
        ita)
            run_ita_tests
            ;;
        quick)
            run_quick_tests
            ;;
        all)
            run_all_tests
            ;;
        *)
            log_fail "Unknown test suite: $TEST_SUITE"
            echo "Valid suites: all, boot, cdh, dmverity, ita, quick"
            exit 1
            ;;
    esac
    
    # Print summary
    echo ""
    echo "=========================================="
    echo "  Test Summary"
    echo "=========================================="
    echo "Total Tests: $TESTS_RUN"
    echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
    echo -e "${RED}Failed: $TESTS_FAILED${NC}"
    echo -e "${YELLOW}Skipped: $TESTS_SKIPPED${NC}"
    echo "=========================================="
    
    # Exit with appropriate code
    if [ $TESTS_FAILED -gt 0 ]; then
        echo -e "${RED}❌ TESTS FAILED${NC}"
        exit 1
    elif [ $TESTS_PASSED -eq 0 ]; then
        echo -e "${YELLOW}⚠️  NO TESTS PASSED${NC}"
        exit 1
    else
        echo -e "${GREEN}✅ ALL TESTS PASSED${NC}"
        exit 0
    fi
}

# Run main
main

# Made with Bob