#!/bin/bash
# Provision Uptycs OSQuery Agent from initdata
# This script extracts Uptycs configuration from initdata and starts the agent
# Exits gracefully (exit 0) if initdata is missing or Uptycs config is not present

# Don't exit on error - we want to handle errors gracefully
set +e

INITDATA_FILE="/run/peerpod/initdata"
UPTYCS_BIN="/opt/uptycs/bin/osqueryd"

# Target directories (symlinked to /var/run/osquery/* for dm-verity compatibility)
OSQUERY_ETC="/etc/osquery"
OSQUERY_LOGS="/var/log/osquery"
OSQUERY_DB="/var/osquery"

echo "Starting Uptycs provisioning..."

# Check for required commands
if ! command -v base64 >/dev/null 2>&1; then
    echo "ERROR: base64 command not found (coreutils package missing)"
    exit 0
fi

if ! command -v gzip >/dev/null 2>&1; then
    echo "ERROR: gzip command not found (gzip package missing)"
    exit 0
fi

if ! command -v awk >/dev/null 2>&1; then
    echo "ERROR: awk command not found (gawk package missing)"
    exit 0
fi

echo "All required commands available (base64, gzip, awk)"

# Check if initdata exists
if [ ! -f "$INITDATA_FILE" ]; then
    echo "No initdata file found at $INITDATA_FILE, skipping Uptycs configuration"
    exit 0
fi

# Decode and decompress initdata
echo "Decoding initdata..."
DECODED=$(cat "$INITDATA_FILE" | base64 -d 2>/dev/null | gzip -d 2>/dev/null)

if [ $? -ne 0 ] || [ -z "$DECODED" ]; then
    echo "Failed to decode initdata, skipping Uptycs configuration"
    exit 0
fi

# Extract uptycs.conf section from TOML structure
echo "Extracting Uptycs configuration..."
UPTYCS_CONF=$(echo "$DECODED" | awk '/^"uptycs\.conf" = /,/^'\'\'\''$/ {print}' | sed "1d;\$d")

if [ -z "$UPTYCS_CONF" ]; then
    echo "No Uptycs configuration found in initdata, skipping"
    exit 0
fi

# Write configuration to temporary location
TEMP_CONFIG="/run/peerpod/uptycs.conf"
echo "$UPTYCS_CONF" > "$TEMP_CONFIG"

# Source the configuration
source "$TEMP_CONFIG"

# Verify required variables
if [ -z "$UPTYCS_SECRET" ]; then
    echo "ERROR: UPTYCS_SECRET not found in configuration"
    exit 0
fi

if [ -z "$UPTYCS_BACKEND" ]; then
    echo "ERROR: UPTYCS_BACKEND not found in configuration"
    exit 0
fi

# Check if Uptycs binary exists
if [ ! -f "$UPTYCS_BIN" ]; then
    echo "ERROR: Uptycs binary not found at $UPTYCS_BIN"
    exit 0
fi

# Ensure /etc/osquery directory exists (should be symlink to /run/osquery/etc)
if [ ! -d "$OSQUERY_ETC" ]; then
    echo "ERROR: $OSQUERY_ETC directory does not exist"
    echo "This should have been created as a symlink during image build"
    exit 0
fi

# Create required files in /etc/osquery/
echo "Creating Uptycs configuration files..."

# 1. Create uptycs.secret file
echo "$UPTYCS_SECRET" > "$OSQUERY_ETC/uptycs.secret"
chmod 600 "$OSQUERY_ETC/uptycs.secret"
echo "✓ Created $OSQUERY_ETC/uptycs.secret"

# 2. Create osquery.conf file (empty for now, will be populated by TLS config plugin)
touch "$OSQUERY_ETC/osquery.conf"
chmod 644 "$OSQUERY_ETC/osquery.conf"
echo "✓ Created $OSQUERY_ETC/osquery.conf"

# 3. Create osquery.flags file with actual flags from EDR team
cat > "$OSQUERY_ETC/osquery.flags" <<'EOF'
--add_container_image_to_events=false
--additional_enroll_sql=
--additional_logger=
--allow_inotify_file_events=false
--allow_nw_events=false
--allowed_yara_fim_operation=open,open+truncate,open+modify,write,rename,rename_to,CREATED,UPDATED,MOVED_TO,symlink,link
--ancestor_list_cmdline_max_length=200
--ancestor_list_enabled=true
--ancestor_list_max_entries=20
--ancestor_list_no_persist=false
--apply_events_rate_before=true
--audit_allow_apparmor_events=false
--audit_allow_config=true
--audit_allow_fim_events=true
--audit_allow_process_events=true
--audit_allow_selinux_events=false
--audit_allow_sockets=true
--audit_allow_syscall_events=true
--audit_allow_unix=false
--audit_allow_user_events=true
--audit_backlog_limit=4096
--audit_eoe_record_timeout=0
--audit_events_rate=0
--audit_exe_rules_sync=false
--audit_exe_rules_sync_period=10
--audit_fim_category_as_key=false
--audit_fim_show_accesses=false
--audit_force_dispatcher_mode=false
--audit_force_reconfigure=false
--audit_records_rate=10000
--audit_rules_sync=0
--audit_rules_sync_period=10
--audit_show_partial_fim_events=false
--audit_syscall_events_list=
--audit_use_sys_config=false
--auditd_dispatcher_q_depth=4096
--auditd_service_control=0
--augeas_allow_adhoc_lens=true
--augeas_lenses=/usr/share/osquery/lenses
--aul_events_processes=
--bf_failed_login_events_time_window=10
--block_external_mounts=false
--block_network_mounts=false
--buffered_log_max=1000000
--carve_upload_timeout=58
--carver_block_size=5242880
--carver_compression=false
--carver_continue_endpoint=/agent/carve_continue
--carver_start_endpoint=/agent/carve_start
--compliance_data_in_json=false
--compliance_data_limit=10240
--config_accelerated_refresh=900
--config_plugin=tls
--config_refresh=900
--config_tls_endpoint=/agent/config
--config_tls_max_attempts=1
--containerd_socket=/run/containerd/containerd.sock
--cpu_percent_scale_factor=3
--crio_socket=/run/crio/crio.sock
--database_path=/var/osquery/osquery.db
--decorations_top_level=true
--delayed_queue_splay=5
--disable_audit=true
--disable_auto_memory=false
--disable_carver=false
--disable_distributed=false
--disable_events=false
--disable_events_exclusion_count=true
--disable_events_filters=
--disable_events_staging=true
--disable_loopback_socket_events=true
--disable_memory_access_for_exenames=
--disable_port_scanning=false
--disable_process_carver=false
--disable_yara_fast_scan_mode=false
--disk_scan_cpu_percent=5
--disk_scan_sleep_duration=200
--distributed_interval=0
--distributed_plugin=tls
--distributed_thread_cpu_percent=7
--distributed_tls_max_attempts=10
--distributed_tls_read_endpoint=/agent/distributed_read
--distributed_tls_write_endpoint=/agent/distributed_write
--dns_lookup_interface=en0
--docker_socket=/run/docker.sock
--drop_user_events_types=1100,1103,1104,1110
--ebpf_dns_event_raw_packet=false
--ebpf_max_single_arg_len=512
--ebpf_percpu_ring_buffer_size=0
--ebpf_program_location=/usr/bin/bpf_progs.o
--enable_aul_events=false
--enable_bf_failed_login_events=true
--enable_bulk_remediation=true
--enable_chained_queries=true
--enable_compliance_remediation=false
--enable_containerd_events=true
--enable_core_dumps=false
--enable_curl=false
--enable_dbus_default_filters=false
--enable_dbus_events=false
--enable_disk_scan=true
--enable_dns_blocking=false
--enable_dns_lookups=true
--enable_dns_protection=false
--enable_docker_events=true
--enable_ebpf_dns_events=true
--enable_ebpf_https_events=false
--enable_ebpf_usrcall_events=false
--enable_enhanced_sec_events=false
--enable_exec_inode_cache=true
--enable_failed_ebpf_dns_events=false
--enable_file_hashing=true
--enable_file_scan=true
--enable_fs_events_based_file_events=false
--enable_gpu_events=false
--enable_http_lookups=true
--enable_keyboard_events=false
--enable_ldap_events=false
--enable_location_events=false
--enable_log_file_events=false
--enable_monitor=true
--enable_mouse_events=false
--enable_net_vol_inode_cache=true
--enable_network_events=false
--enable_network_scanning=true
--enable_ntp_query=false
--enable_numeric_monitoring=false
--enable_package_files_inventory=false
--enable_proc_vuln_ebpf=false
--enable_proc_vuln_events=false
--enable_process_blocking=false
--enable_process_blocking_events=false
--enable_process_event_blocking_decoration=false
--enable_protect=false
--enable_proxy_auto_discovery=true
--enable_quic_events=true
--enable_remediation=true
--enable_resource_monitoring_events=false
--enable_script_bulk_remediation=true
--enable_syslog=false
--enable_tamperproof=false
--enable_user_agent=false
--enable_windows_defender_perf_validator=true
--enable_windows_kernel_events=true
--enable_wmi=true
--enable_yara_ad_hoc_rules=false
--enable_yara_process_events=true
--enable_yara_process_file_events=true
--enable_yara_process_scanning=true
--enroll_always=true
--enroll_secret_path=/etc/osquery/uptycs.secret
--enroll_skip_tables=cloud_info
--enroll_tls_endpoint=/agent/enroll
--events_max=5000
--events_rate=5
--exclude_checkids=L0028,L0140,L0213,L0214,L0215,L0216,L0217,L0218,L0234
--exclude_controlling_parents=true
--fim_capture_magic_number_bytes=10
--force_legacy_dns_events=false
--force_legacy_process_blocking_events=false
--force_legacy_process_events=false
--generate_process_hash_in_process_event=true
--generate_record_hash=true
--host_identifier=uuid
--ignore_network_home_directories=true
--include_http_headers=
--java_scan_process_open_jar=false
--log_subquery_results=false
--logger_event_type=true
--logger_path=/var/log/osquery
--logger_plugin=tls
--logger_tls_compress=true
--logger_tls_endpoint=/agent/log
--logger_tls_format=3
--logger_tls_max=5242880
--logger_tls_period=4
--lxd_socket=/var/lib/lxd/unix.socket
--malware_check_hashes=false
--max_binary_scan_size=20000000
--max_cmd_output_size=100
--max_distributed_payload=5120
--max_download_file_size=20971520
--max_heartbeat_delay=3600
--max_private_scan_size=3145728
--max_secret_scan_size=16384
--max_stderr_log_size=50
--max_yara_scan_strings_match=16384
--mft_scan_sleep_duration=400
--min_private_scan_size=102400
--monitor_network_inout_ports=
--mute_specific_dirs=false
--no_install_audit_fim_events_rule=false
--no_install_audit_process_events_rule=false
--no_install_audit_socket_events_rule=false
--non_system_drives_are_remote=false
--override_audit_allow_fim_events=true
--pidfile=/var/run/osqueryd.pid
--port_scan_list=21,22,23,25,53,67,80,110,123,135,137,138,139,161,443,445,520,631,3389,8080
--proc_vuln_events_min_age_sec=30
--proxy_auto_discovery_order=direct, db, flags, os
--proxy_basic_auth=
--proxy_hostname=
--redirect_stderr=true
--report_all_open_events=false
--report_all_relative_paths=false
--report_chroot_events=false
--reset_dns_blocking=true
--reset_process_blocking=true
--rule_engine_throttling=thread
--schedule_default_interval=3600
--schedule_max_drift=1800
--schedule_reload=300
--schedule_splay_percent=10
--schedule_thread_cpu_percent=10
--schedule_timeout=0
--software_update=true
--sysfs_mountpoint=/sys
--syshook_poll_time=30
--syslog_events_max=100000
--syslog_pipe_path=/var/osquery/syslog_pipe
--syslog_rate_limit=100
--threat_indicator_refresh_interval=7200
--tls_hostname=armada.uptycs.io
--tls_server_certs=/etc/osquery/ca.crt
--tls_threat_indicator_index_interval=3600
--try_audit_based_events_first=false
--utc=true
--verbose_level=2
--watchdog_above_sixteen_alloc_vm=32
--watchdog_base_alloc_vm=400
--watchdog_base_memory=2
--watchdog_below_sixteen_alloc_vm=80
--watchdog_db_check_interval=600
--watchdog_db_limit=0
--watchdog_level=0
--watchdog_memory_limit=300
--watchdog_utilization_limit=0
--win_allow_all_api_events=false
--win_allow_amsi_events=false
--win_allow_api_blocking=false
--win_allow_api_events=false
--win_allow_creddump_process=
--win_allow_dll_injection_process=
--win_allow_drive_events=false
--win_allow_failed_login_events=true
--win_allow_fim_events=true
--win_allow_image_events=true
--win_allow_kerberoasting_attack_process=
--win_allow_logon_events=true
--win_allow_lsass_memory_modifier_process=
--win_allow_mbr_attack_process=
--win_allow_pass_the_ticket_process=
--win_allow_powershell_events=true
--win_allow_process_control_events=false
--win_allow_process_events=true
--win_allow_process_hollowing_process=
--win_allow_ransomeware_process=
--win_allow_reg_events=true
--win_allow_reverseshell_process=
--win_allow_rpc_query_events=false
--win_allow_sockets=true
--win_allow_user_focus_events=false
--win_allow_user_threat_events=false
--win_allow_wmi_query_events=true
--win_allowed_event_percent=0
--win_amsi_payload_length=16384
--win_enable_advanced_forensics=false
--win_enable_dns_lookups=true
--win_enable_http_events=false
--win_enable_login_audit=false
--win_enable_network_events=false
--win_enable_ransomware_detection=true
--win_forensics_operations_flags=1
--win_forensics_trigger_path=
--win_forensics_write_flags=6
--win_inject_system=false
--win_inject_trusted=false
--win_inline_process_events=true
--win_inline_reg_events=false
--win_max_shed_events=10000
--win_max_users=10
--win_netsh_trace_capture=false
--win_ransomware_detection_time_window=60
--win_ransomware_dir_to_watch=0
--win_ransomware_extension_to_watch=0
--win_ransomware_fileop_to_watch=5
--win_ransomware_ignore_path_contains=temp,tmp
--win_ransomware_monitor_src_ext=jpg,jpeg,png,gif,flv,avi,mov,wmv,rm,asf,mp4,mpg,mpeg,m4v,3gp,3g2,pdf,docx,pptx,doc,7z,zip,txt,ppt,pps,xlr,xls,xlsl,suo,cpp,pas,asm,cmd,bat,ps1,vbs,java,jar,class,mp3,wav,swf,vob,mkv,svg,psd,nef,tiff,tif,cgm,raw,bmp,vcd,iso,backup,rar,tgz,tar,bak,tbk,bz2,msg,ost,pst,potm,potx,ppam,ppsx,ppsm,pot,pptm,xltm,xltx,xlc,xlm,xlt,xlw,xlsb,xlsm,xlsx,dotx,dotm,dot,docm,docb
--windows_defender_preference_update_interval=180000
--windows_event_channels=Application,Security,Setup,System,Microsoft-Windows-Windows Defender/Operational
--windows_event_excluded_ids=
--worker_cpu_stat_delay=60
--yara_process_events_exclude_prefixes=/lib:/usr/lib:/usr/local/lib
--yara_process_events_min_age=5
--yara_process_events_scan_all_at_startup=false
--yara_process_limit_mem_used=10485760
EOF

# Add tags if specified
if [ -n "$UPTYCS_TAGS" ]; then
    echo "--host_identifier=$UPTYCS_TAGS" >> "$OSQUERY_ETC/osquery.flags"
    # Also create uptycs_tags file
    echo "$UPTYCS_TAGS" > "$OSQUERY_ETC/uptycs_tags"
    echo "✓ Created $OSQUERY_ETC/uptycs_tags"
fi

# Add proxy if specified
if [ -n "$UPTYCS_PROXY" ]; then
    echo "--proxy_hostname=$UPTYCS_PROXY" >> "$OSQUERY_ETC/osquery.flags"
fi

chmod 644 "$OSQUERY_ETC/osquery.flags"
echo "✓ Created $OSQUERY_ETC/osquery.flags"

# 4. Copy CA certificate if it exists
if [ -f /usr/share/osquery/certs/certs.pem ]; then
    cp /usr/share/osquery/certs/certs.pem "$OSQUERY_ETC/ca.crt"
    chmod 644 "$OSQUERY_ETC/ca.crt"
    echo "✓ Copied CA certificate to $OSQUERY_ETC/ca.crt"
fi

# Verify all required files exist
echo ""
echo "Verifying /etc/osquery directory contents:"
ls -la "$OSQUERY_ETC/"
echo ""

# Ensure runtime directories exist (they're symlinks to /var/run/osquery/*)
# The actual directories were created during image build
mkdir -p "$OSQUERY_LOGS"
mkdir -p "$OSQUERY_DB"
echo "✓ Runtime directories ready:"
echo "  - Logs: $OSQUERY_LOGS (-> /var/run/osquery/logs)"
echo "  - Database: $OSQUERY_DB (-> /var/run/osquery/db)"

echo "Uptycs configuration complete"
echo "Starting Uptycs OSQuery agent..."

# Launch Uptycs with new command format
# Using --flagfile and --config_path as specified by EDR team
UPTYCS_CMD="$UPTYCS_BIN --flagfile $OSQUERY_ETC/osquery.flags --config_path $OSQUERY_ETC/osquery.conf"

# Add tags via command line if specified
if [ -n "$UPTYCS_TAGS" ]; then
    UPTYCS_CMD="$UPTYCS_CMD --osquery_tags \"$UPTYCS_TAGS\""
fi

echo "Command: $UPTYCS_CMD"
echo ""
echo "Logs will be written to: $OSQUERY_LOGS/osqueryd.worker.log"
echo ""

# Launch Uptycs in foreground (systemd will manage as daemon)
exec $UPTYCS_CMD

# Made with Bob
