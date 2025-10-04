# Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help) show_help; exit 0 ;;
            -i|--interactive) INTERACTIVE_MODE=true ;;
            -a|--auto) INTERACTIVE_MODE=false ;;
            -d|--dry-run) DRY_RUN=true ;;
            --no-aur) UPDATE_AUR=false ;;
            --no-flatpak) UPDATE_FLATPAK=false ;;
            --no-snap) UPDATE_SNAP=false ;;
            --no-backup) CREATE_BACKUP=false ;;
            --no-snapshot) CREATE_SNAPSHOT=false ;;
            --no-parallel) ENABLE_PARALLEL_DOWNLOADS=false ;;
            --no-notification) SEND_NOTIFICATION=false ;;
            --auto-remove) AUTO_REMOVE_CONFLICTS=true ;;
            --config) CONFIG_FILE="$2"; shift ;;
            *) log ERROR "Unknown option: $1"; show_help; exit 1 ;;
        esac
        shift
    done
    
    load_config
    print_header
    
    log INFO "Starting system upgrade process..."
    log INFO "Mode: $([ "$INTERACTIVE_MODE" == true ] && echo "Interactive" || echo "Automatic")"
    [[ "$DRY_RUN" == true ]] && log WARN "DRY RUN MODE - No changes will be made"
    
    # Pre-flight checks
    check_system_resources
    check_for_partial_upgrades
    check_mirror_health
    detect_managers
    
    if [[ "$CREATE_BACKUP" == true ]]; then
        create_system_snapshot
    fi
    
    check_disk_space
    check_and_enable_parallel_downloads
    
    if ! check_updates_available; then
        send_notification "System Up to Date" "No updates available"
        exit 0
    fi
    
    if ! ask_user "Proceed with system upgrade?" "y"; then
        log INFO "Upgrade cancelled by user"
        exit 0
    fi
    
    refresh_keyrings
    
    if ! perform_system_upgrade; then
        send_notification "Upgrade Failed" "Check log for details" 
        parse_and_fix_conflicts
    fi
    
    # Create post-snapshot for snapper
    create_post_snapshot
    
    update_other_managers
    perform_cleanup
    verify_system_integrity
    show_summary
    
    log SUCCESS "All operations completed!"
}

# Run main function
main "$@"#!/usr/bin/env bash
# upgrade.sh
# Professional System Upgrade Manager for Manjaro/Arch
# Features: Interactive mode, safety checks, rollback support, conflict resolution
# Author: @irfnrdh | License: MIT

set -o pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================
VERSION="2.0.0"
LOGDIR="$HOME/.system-upgrade-logs"
LOGFILE="$LOGDIR/upgrade_$(date +%Y%m%d_%H%M%S).log"
TMPERR="/tmp/pacman_error_$$.log"
BACKUP_DIR="$HOME/.system-upgrade-backups"
CONFIG_FILE="$HOME/.config/system-upgrade.conf"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Default settings (can be overridden by config file)
INTERACTIVE_MODE=true
AUTO_REMOVE_CONFLICTS=false
CREATE_BACKUP=true
CLEAN_CACHE_AFTER=true
UPDATE_AUR=true
UPDATE_FLATPAK=true
UPDATE_SNAP=true
DRY_RUN=false
ENABLE_PARALLEL_DOWNLOADS=true
CREATE_SNAPSHOT=true
SNAPSHOT_TOOL="" # auto-detect: timeshift or snapper
SEND_NOTIFICATION=true
CHECK_BATTERY=true
MIN_BATTERY_LEVEL=30

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================
mkdir -p "$LOGDIR" "$BACKUP_DIR"

print_header() {
    echo -e "\n${BOLD}${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${BOLD}Manjaro/Arch System Upgrade Manager Pro v${VERSION}${NC}      ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════════════════════╝${NC}\n"
}

log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp="[$(date +'%F %T')]"
    
    case "$level" in
        INFO)  echo -e "${timestamp} ${BLUE}[INFO]${NC} $msg" | tee -a "$LOGFILE" ;;
        SUCCESS) echo -e "${timestamp} ${GREEN}[✓]${NC} $msg" | tee -a "$LOGFILE" ;;
        WARN)  echo -e "${timestamp} ${YELLOW}[⚠]${NC} $msg" | tee -a "$LOGFILE" ;;
        ERROR) echo -e "${timestamp} ${RED}[✗]${NC} $msg" | tee -a "$LOGFILE" ;;
        STEP)  echo -e "\n${BOLD}${MAGENTA}▶${NC} ${BOLD}$msg${NC}" | tee -a "$LOGFILE" ;;
    esac
}

ask_user() {
    local prompt="$1"
    local default="${2:-n}"
    
    if [[ "$INTERACTIVE_MODE" == false ]]; then
        [[ "$default" == "y" ]] && return 0 || return 1
    fi
    
    local answer
    echo -ne "${YELLOW}[?]${NC} $prompt [y/N]: "
    read -r answer
    answer="${answer:-$default}"
    [[ "${answer,,}" =~ ^y(es)?$ ]]
}

run_cmd() {
    local cmd="$*"
    log INFO "Executing: $cmd"
    if [[ "$DRY_RUN" == true ]]; then
        log WARN "DRY RUN - Command not executed"
        return 0
    fi
    eval "$cmd" 2>&1 | tee -a "$LOGFILE"
    return "${PIPESTATUS[0]}"
}

detect_managers() {
    declare -gA MGR
    local managers=(pacman pamac yay paru flatpak snap npm pip)
    
    log STEP "Detecting package managers..."
    for mgr in "${managers[@]}"; do
        if command -v "$mgr" >/dev/null 2>&1; then
            MGR[$mgr]=1
            log SUCCESS "Found: $mgr"
        fi
    done
    
    if [[ ${#MGR[@]} -eq 0 ]]; then
        log ERROR "No package managers detected!"
        exit 1
    fi
    
    # Detect snapshot tools
    log INFO "Detecting snapshot tools..."
    if command -v timeshift >/dev/null 2>&1; then
        SNAPSHOT_TOOL="timeshift"
        log SUCCESS "Found: Timeshift"
    elif command -v snapper >/dev/null 2>&1; then
        SNAPSHOT_TOOL="snapper"
        log SUCCESS "Found: Snapper"
    else
        log WARN "No snapshot tool detected (timeshift/snapper)"
        SNAPSHOT_TOOL=""
    fi
    
    # Check if BTRFS is used
    if [[ -n "$SNAPSHOT_TOOL" ]]; then
        local root_fs=$(findmnt -n -o FSTYPE /)
        if [[ "$root_fs" == "btrfs" ]]; then
            log SUCCESS "BTRFS filesystem detected - snapshots available"
        else
            log WARN "Root filesystem is $root_fs (not BTRFS)"
            if [[ "$SNAPSHOT_TOOL" == "snapper" ]]; then
                log WARN "Snapper works best with BTRFS"
            fi
        fi
    fi
}

create_system_snapshot() {
    log STEP "Creating system snapshot..."
    
    local snapshot_file="$BACKUP_DIR/pkglist_$(date +%Y%m%d_%H%M%S).txt"
    local snapshot_full="$BACKUP_DIR/pkglist_full_$(date +%Y%m%d_%H%M%S).txt"
    
    if [[ ${MGR[pacman]+_} ]]; then
        # Explicit packages (user-installed)
        pacman -Qqe > "$snapshot_file"
        # All packages with versions
        pacman -Q > "$snapshot_full"
        log SUCCESS "Package list saved to: $snapshot_file"
        
        # CRITICAL: Save current database state
        log INFO "Backing up pacman database..."
        sudo tar -czf "$BACKUP_DIR/pacman_db_$(date +%Y%m%d_%H%M%S).tar.gz" \
            /var/lib/pacman/local 2>/dev/null || log WARN "Could not backup pacman database"
    fi
    
    # Backup important configs
    if ask_user "Backup /etc/pacman.conf and mirrorlist?" "y"; then
        cp /etc/pacman.conf "$BACKUP_DIR/pacman.conf.backup_$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
        cp /etc/pacman.d/mirrorlist "$BACKUP_DIR/mirrorlist.backup_$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
        
        # CRITICAL: Backup modified configs
        if [[ -d /etc/pacman.d/hooks ]]; then
            cp -r /etc/pacman.d/hooks "$BACKUP_DIR/hooks_backup_$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
        fi
        
        log SUCCESS "Configuration files backed up"
    fi
    
    # Create filesystem snapshot if available
    if [[ "$CREATE_SNAPSHOT" == true ]] && [[ -n "$SNAPSHOT_TOOL" ]]; then
        create_filesystem_snapshot
    fi
    
    # Create restore script
    cat > "$BACKUP_DIR/restore_packages.sh" << 'EOFSCRIPT'
#!/bin/bash
# Auto-generated package restore script
LATEST_LIST=$(ls -t pkglist_*.txt | head -n1)
echo "Restoring packages from: $LATEST_LIST"
sudo pacman -S --needed - < "$LATEST_LIST"
EOFSCRIPT
    chmod +x "$BACKUP_DIR/restore_packages.sh"
    log INFO "Created restore script: $BACKUP_DIR/restore_packages.sh"
}

create_filesystem_snapshot() {
    log STEP "Creating filesystem snapshot with $SNAPSHOT_TOOL..."
    
    local snapshot_desc="pre-upgrade-$(date +%Y%m%d-%H%M%S)"
    
    case "$SNAPSHOT_TOOL" in
        timeshift)
            if systemctl is-active --quiet cronie || systemctl is-active --quiet crond; then
                log INFO "Creating Timeshift snapshot..."
                
                # Check Timeshift configuration
                if [[ ! -f /etc/timeshift/timeshift.json ]]; then
                    log WARN "Timeshift not configured. Run 'sudo timeshift --create' manually"
                    return 1
                fi
                
                if ask_user "Create Timeshift snapshot? (Recommended)" "y"; then
                    if sudo timeshift --create --comments "$snapshot_desc" --scripted 2>&1 | tee -a "$LOGFILE"; then
                        log SUCCESS "Timeshift snapshot created: $snapshot_desc"
                        echo "$snapshot_desc" > "$BACKUP_DIR/latest_snapshot.txt"
                    else
                        log ERROR "Failed to create Timeshift snapshot"
                        if ! ask_user "Continue without snapshot?" "n"; then
                            exit 1
                        fi
                    fi
                fi
            else
                log WARN "Cron service not running - Timeshift may not work properly"
            fi
            ;;
            
        snapper)
            log INFO "Creating Snapper snapshot..."
            
            # Check if snapper is configured for root
            if ! sudo snapper list >/dev/null 2>&1; then
                log WARN "Snapper not configured. Run 'sudo snapper -c root create-config /' first"
                return 1
            fi
            
            if ask_user "Create Snapper snapshot? (Recommended)" "y"; then
                # Pre-snapshot
                local pre_num=$(sudo snapper create --type pre --cleanup-algorithm number --print-number --description "$snapshot_desc" 2>&1 | tail -n1)
                
                if [[ "$pre_num" =~ ^[0-9]+$ ]]; then
                    log SUCCESS "Snapper pre-snapshot created: #$pre_num"
                    echo "$pre_num" > "$BACKUP_DIR/snapper_pre_number.txt"
                    
                    # We'll create post-snapshot after upgrade
                    export SNAPPER_PRE_NUM="$pre_num"
                else
                    log ERROR "Failed to create Snapper snapshot"
                    if ! ask_user "Continue without snapshot?" "n"; then
                        exit 1
                    fi
                fi
            fi
            ;;
            
        *)
            log INFO "No snapshot tool configured, skipping filesystem snapshot"
            ;;
    esac
}

create_post_snapshot() {
    if [[ "$SNAPSHOT_TOOL" == "snapper" ]] && [[ -n "$SNAPPER_PRE_NUM" ]]; then
        log STEP "Creating Snapper post-snapshot..."
        
        local post_num=$(sudo snapper create --type post --pre-number "$SNAPPER_PRE_NUM" --print-number --description "post-upgrade-$(date +%Y%m%d-%H%M%S)" 2>&1 | tail -n1)
        
        if [[ "$post_num" =~ ^[0-9]+$ ]]; then
            log SUCCESS "Snapper post-snapshot created: #$post_num"
            log INFO "To rollback: sudo snapper rollback $pre_num"
        fi
    fi
}

check_disk_space() {
    log STEP "Checking disk space..."
    
    local root_avail=$(df -h / | awk 'NR==2 {print $4}')
    local cache_size=$(du -sh /var/cache/pacman/pkg 2>/dev/null | cut -f1)
    
    log INFO "Available space on /: $root_avail"
    log INFO "Package cache size: ${cache_size:-Unknown}"
    
    # Check if less than 2GB available
    local avail_mb=$(df -m / | awk 'NR==2 {print $4}')
    if [[ $avail_mb -lt 2048 ]]; then
        log WARN "Low disk space detected (< 2GB)"
        if ask_user "Clean package cache now?" "y"; then
            run_cmd "sudo pacman -Sc --noconfirm"
        fi
    fi
    
    # Estimate update size
    if command -v checkupdates >/dev/null 2>&1; then
        log INFO "Estimating download size..."
        local estimate=$(checkupdates 2>/dev/null | wc -l)
        if [[ $estimate -gt 0 ]]; then
            log INFO "Approximately $estimate packages to update"
            # Rough estimate: 50MB per package average
            local est_size=$((estimate * 50))
            if [[ $avail_mb -lt $est_size ]]; then
                log ERROR "Insufficient disk space for estimated update size"
                log ERROR "Available: ${avail_mb}MB, Estimated need: ${est_size}MB"
                if ! ask_user "Continue anyway? (Not recommended)" "n"; then
                    exit 1
                fi
            fi
        fi
    fi
}

check_system_resources() {
    log STEP "Checking system resources..."
    
    # Check if running on laptop
    if [[ -d /sys/class/power_supply/BAT* ]] && [[ "$CHECK_BATTERY" == true ]]; then
        log INFO "Laptop detected, checking battery..."
        
        local battery_path=$(ls -d /sys/class/power_supply/BAT* 2>/dev/null | head -n1)
        if [[ -n "$battery_path" ]]; then
            local battery_level=$(cat "$battery_path/capacity" 2>/dev/null || echo "unknown")
            local ac_online=$(cat /sys/class/power_supply/AC*/online 2>/dev/null || echo "1")
            
            log INFO "Battery level: ${battery_level}%"
            
            if [[ "$ac_online" == "0" ]] && [[ "$battery_level" != "unknown" ]] && [[ $battery_level -lt $MIN_BATTERY_LEVEL ]]; then
                log ERROR "Battery level too low: ${battery_level}% (minimum: ${MIN_BATTERY_LEVEL}%)"
                log ERROR "Please connect AC power before system upgrade"
                if ! ask_user "Continue anyway? (Risk of partial upgrade if battery dies)" "n"; then
                    exit 1
                fi
            elif [[ "$ac_online" == "0" ]]; then
                log WARN "Running on battery power - consider connecting AC adapter"
            else
                log SUCCESS "AC power connected"
            fi
        fi
    fi
    
    # Check network stability
    log INFO "Checking network connectivity..."
    if ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        log ERROR "No internet connectivity detected"
        log ERROR "Network connection is required for system upgrade"
        exit 1
    fi
    
    # Test download speed (simple)
    local test_url="https://archlinux.org/static/archlinux.svg"
    local start_time=$(date +%s%N)
    if curl -s --max-time 5 "$test_url" > /dev/null 2>&1; then
        local end_time=$(date +%s%N)
        local duration=$(( (end_time - start_time) / 1000000 ))
        log INFO "Network latency: ${duration}ms"
        
        if [[ $duration -gt 1000 ]]; then
            log WARN "Slow network detected (${duration}ms latency)"
            log WARN "Upgrade may take longer than usual"
        fi
    else
        log WARN "Could not test network speed"
    fi
    
    # Check RAM usage
    local mem_available=$(free -m | awk 'NR==2 {print $7}')
    log INFO "Available RAM: ${mem_available}MB"
    
    if [[ $mem_available -lt 512 ]]; then
        log WARN "Low available RAM (< 512MB)"
        log WARN "Consider closing applications before upgrade"
    fi
}

check_updates_available() {
    log STEP "Checking for available updates..."
    
    local updates_found=false
    
    if [[ ${MGR[pacman]+_} ]]; then
        if command -v checkupdates >/dev/null 2>&1; then
            local pkg_updates=$(checkupdates 2>/dev/null | wc -l)
            if [[ $pkg_updates -gt 0 ]]; then
                log INFO "Official repositories: $pkg_updates packages"
                updates_found=true
            fi
        fi
    fi
    
    if [[ ${MGR[yay]+_} ]] && [[ "$UPDATE_AUR" == true ]]; then
        local aur_updates=$(yay -Qua 2>/dev/null | wc -l)
        if [[ $aur_updates -gt 0 ]]; then
            log INFO "AUR packages: $aur_updates packages"
            updates_found=true
        fi
    fi
    
    if [[ ${MGR[flatpak]+_} ]] && [[ "$UPDATE_FLATPAK" == true ]]; then
        local flatpak_updates=$(flatpak remote-ls --updates 2>/dev/null | wc -l)
        if [[ $flatpak_updates -gt 0 ]]; then
            log INFO "Flatpak apps: $flatpak_updates packages"
            updates_found=true
        fi
    fi
    
    if [[ "$updates_found" == false ]]; then
        log SUCCESS "System is up to date!"
        return 1
    fi
    
    return 0
}

check_and_enable_parallel_downloads() {
    if [[ "$ENABLE_PARALLEL_DOWNLOADS" != true ]]; then
        return
    fi
    
    log STEP "Checking pacman parallel downloads..."
    
    if [[ ${MGR[pacman]+_} ]]; then
        if grep -q "^#ParallelDownloads" /etc/pacman.conf 2>/dev/null; then
            log INFO "ParallelDownloads is commented in pacman.conf"
            if ask_user "Enable parallel downloads? (5 simultaneous)" "y"; then
                log INFO "Enabling ParallelDownloads in pacman.conf..."
                sudo sed -i 's/^#ParallelDownloads = .*/ParallelDownloads = 5/' /etc/pacman.conf
                
                # Backup the modified config
                sudo cp /etc/pacman.conf "$BACKUP_DIR/pacman.conf.modified_$(date +%Y%m%d_%H%M%S)"
                log SUCCESS "ParallelDownloads enabled (5 connections)"
            fi
        elif grep -q "^ParallelDownloads" /etc/pacman.conf 2>/dev/null; then
            local current=$(grep "^ParallelDownloads" /etc/pacman.conf | grep -oP '\d+')
            log SUCCESS "ParallelDownloads already enabled: $current connections"
        else
            log INFO "Adding ParallelDownloads to pacman.conf..."
            if ask_user "Add ParallelDownloads = 5 to pacman.conf?" "y"; then
                sudo sed -i '/^\[options\]/a ParallelDownloads = 5' /etc/pacman.conf
                log SUCCESS "ParallelDownloads added to config"
            fi
        fi
    fi
}
    log STEP "Checking for partial upgrades..."
    
    # Critical: Detect if system has mixed old/new libraries
    if [[ ${MGR[pacman]+_} ]]; then
        local foreign_libs=$(ldd /usr/bin/* 2>/dev/null | grep "not found" | wc -l)
        if [[ $foreign_libs -gt 0 ]]; then
            log ERROR "Detected broken library links! System may be partially upgraded."
            log WARN "This usually happens after incomplete upgrades or power failures."
            log INFO "Recommendation: Full system upgrade with -Syyu is REQUIRED"
            
            if ask_user "Try emergency system recovery?" "y"; then
                run_cmd "sudo pacman -Syyu --noconfirm"
            fi
            return 1
        fi
    fi
    return 0
}

check_mirror_health() {
    log STEP "Checking mirror health..."
    
    if [[ ${MGR[pacman]+_} ]]; then
        # Check if mirrors are accessible
        if ! curl -s --connect-timeout 5 https://archlinux.org > /dev/null; then
            log WARN "Cannot reach Arch mirrors. Check internet connection."
        fi
        
        # For Manjaro: check if mirrors need refresh
        if command -v pacman-mirrors >/dev/null 2>&1; then
            local mirror_age=$(find /var/lib/pacman-mirrors -name "status.json" -mtime +30 2>/dev/null | wc -l)
            if [[ $mirror_age -gt 0 ]]; then
                log WARN "Mirrors list is older than 30 days"
                if ask_user "Update Manjaro mirrors?" "y"; then
                    run_cmd "sudo pacman-mirrors --fasttrack && sudo pacman -Syy"
                fi
            fi
        fi
    fi
}

refresh_keyrings() {
    log STEP "Refreshing package keyrings..."
    
    if [[ ${MGR[pacman]+_} ]]; then
        # Check if keyring is corrupted
        if ! sudo pacman-key --list-keys >/dev/null 2>&1; then
            log ERROR "Keyring appears corrupted!"
            if ask_user "Reinitialize keyring? (May take several minutes)" "y"; then
                run_cmd "sudo rm -rf /etc/pacman.d/gnupg"
                run_cmd "sudo pacman-key --init"
                run_cmd "sudo pacman-key --populate archlinux manjaro"
            fi
        fi
        
        if ask_user "Refresh Arch/Manjaro keyrings?" "n"; then
            run_cmd "sudo pacman -Sy archlinux-keyring manjaro-keyring --noconfirm --needed" || true
            run_cmd "sudo pacman-key --populate archlinux manjaro" || true
            run_cmd "sudo pacman-key --refresh-keys" || true
        fi
    fi
}

perform_system_upgrade() {
    log STEP "Performing system upgrade..."
    
    local upgrade_cmd=""
    local mgr_name=""
    local retry_count=0
    local max_retries=3
    
    # Priority: pamac > yay > paru > pacman
    if [[ ${MGR[pamac]+_} ]]; then
        mgr_name="pamac"
        upgrade_cmd="sudo pamac upgrade --no-confirm"
    elif [[ ${MGR[yay]+_} ]]; then
        mgr_name="yay"
        upgrade_cmd="yay -Syu --noconfirm"
    elif [[ ${MGR[paru]+_} ]]; then
        mgr_name="paru"
        upgrade_cmd="paru -Syu --noconfirm"
    else
        mgr_name="pacman"
        upgrade_cmd="sudo pacman -Syu --noconfirm"
    fi
    
    log INFO "Using $mgr_name for system upgrade..."
    
    while [[ $retry_count -lt $max_retries ]]; do
        if eval "$upgrade_cmd" 2>"$TMPERR" | tee -a "$LOGFILE"; then
            log SUCCESS "System upgrade completed successfully"
            
            # CRITICAL: Check if important packages were updated
            check_critical_packages_updated
            return 0
        else
            retry_count=$((retry_count + 1))
            log WARN "Upgrade attempt $retry_count failed"
            
            if [[ $retry_count -lt $max_retries ]]; then
                log INFO "Retrying in 5 seconds..."
                sleep 5
            else
                log ERROR "Upgrade failed after $max_retries attempts"
                return 1
            fi
        fi
    done
}

check_critical_packages_updated() {
    log INFO "Verifying critical system components..."
    
    local critical_pkgs=("linux" "systemd" "glibc" "gcc-libs" "pacman")
    local needs_reboot=false
    
    for pkg in "${critical_pkgs[@]}"; do
        if grep -q "$pkg" "$LOGFILE" 2>/dev/null; then
            case "$pkg" in
                linux*)
                    log WARN "Kernel updated - REBOOT REQUIRED"
                    needs_reboot=true
                    ;;
                systemd)
                    log WARN "systemd updated - REBOOT RECOMMENDED"
                    needs_reboot=true
                    ;;
                glibc|gcc-libs)
                    log WARN "$pkg updated - Consider restarting active services"
                    ;;
            esac
        fi
    done
    
    if [[ "$needs_reboot" == true ]]; then
        echo -e "\n${BOLD}${RED}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}${RED}║  ⚠️  SYSTEM REBOOT REQUIRED  ⚠️                           ║${NC}"
        echo -e "${BOLD}${RED}╚════════════════════════════════════════════════════════════╝${NC}\n"
        
        if ask_user "Reboot now?" "n"; then
            log INFO "Rebooting system..."
            sudo systemctl reboot
        fi
    fi
}

parse_and_fix_conflicts() {
    log STEP "Analyzing package conflicts..."
    
    if [[ ! -s "$TMPERR" ]]; then
        log INFO "No errors to analyze"
        return 0
    fi
    
    # Display error summary
    log WARN "Errors detected during upgrade:"
    tail -n 30 "$TMPERR" | tee -a "$LOGFILE"
    
    # Parse conflicts
    local conflicts=$(grep -oP "required by \K[^\n']+" "$TMPERR" 2>/dev/null | sed 's/[:,]$//' | sort -u)
    
    if [[ -z "$conflicts" ]]; then
        log WARN "No explicit package conflicts found in error output"
        
        # Check for file conflicts
        if grep -q "exists in filesystem" "$TMPERR"; then
            log WARN "File conflicts detected"
            if ask_user "Try to resolve file conflicts with --overwrite?" "n"; then
                log INFO "Re-running upgrade with --overwrite..."
                if [[ ${MGR[pacman]+_} ]]; then
                    run_cmd "sudo pacman -Syu --overwrite '*' --noconfirm"
                fi
            fi
        fi
        return 1
    fi
    
    log INFO "Conflicting packages found:"
    echo "$conflicts" | while read -r pkg; do
        echo "  • $pkg"
    done | tee -a "$LOGFILE"
    
    # Handle each conflict
    for pkg in $conflicts; do
        handle_conflict_package "$pkg"
    done
    
    # Retry upgrade
    log STEP "Retrying system upgrade after conflict resolution..."
    perform_system_upgrade
}

handle_conflict_package() {
    local pkg="$1"
    
    log INFO "Handling conflict: $pkg"
    
    # CRITICAL FIX: Check if package is essential before removal
    local essential_pkgs=("base" "base-devel" "linux" "systemd" "pacman" "bash" "glibc" "gcc-libs")
    for essential in "${essential_pkgs[@]}"; do
        if [[ "$pkg" == "$essential" ]]; then
            log ERROR "CRITICAL: Cannot remove essential package '$pkg'"
            log ERROR "This would break your system. Manual intervention required."
            return 1
        fi
    done
    
    # Try to identify problematic libraries
    local libs=$(grep -i "$pkg" "$TMPERR" 2>/dev/null | \
                 grep -oP "'\K[^']+(?='.*required by)" | \
                 sort -u)
    
    if [[ -n "$libs" ]]; then
        log INFO "Required libraries for $pkg:"
        echo "$libs" | while read -r lib; do
            echo "  • $lib"
        done | tee -a "$LOGFILE"
    fi
    
    # Strategy 1: Try to rebuild AUR package
    if [[ ${MGR[yay]+_} ]] || [[ ${MGR[paru]+_} ]]; then
        if pacman -Qm "$pkg" >/dev/null 2>&1; then
            if ask_user "Rebuild AUR package '$pkg'?" "y"; then
                log INFO "Attempting to rebuild from AUR..."
                if [[ ${MGR[yay]+_} ]]; then
                    if run_cmd "yay -S --rebuild --noconfirm $pkg"; then
                        log SUCCESS "Successfully rebuilt $pkg"
                        return 0
                    fi
                elif [[ ${MGR[paru]+_} ]]; then
                    if run_cmd "paru -S --rebuild --noconfirm $pkg"; then
                        log SUCCESS "Successfully rebuilt $pkg"
                        return 0
                    fi
                fi
            fi
        fi
    fi
    
    # Strategy 2: Try to find and install compatible version
    if try_find_compatible_version "$pkg"; then
        return 0
    fi
    
    # Strategy 3: Downgrade from cache
    if try_downgrade_from_cache "$pkg"; then
        return 0
    fi
    
    # Strategy 4: Check if package can be temporarily ignored
    log WARN "Could not automatically resolve conflict for $pkg"
    
    # Strategy 5: Remove package (LAST RESORT)
    if [[ "$AUTO_REMOVE_CONFLICTS" == true ]] || \
       ask_user "Remove '$pkg' to resolve conflict? (LAST RESORT)" "n"; then
        log WARN "Removing package: $pkg"
        
        # Check dependencies before removal
        local deps=$(pactree -r "$pkg" 2>/dev/null | tail -n +2)
        if [[ -n "$deps" ]]; then
            log WARN "Packages that depend on $pkg:"
            echo "$deps" | tee -a "$LOGFILE"
            if ! ask_user "These packages will also be affected. Continue?" "n"; then
                log INFO "Skipping removal of $pkg"
                return 1
            fi
        fi
        
        run_cmd "sudo pacman -Rdd --noconfirm $pkg"
        echo "$pkg" >> "$BACKUP_DIR/removed_packages.txt"
        log INFO "Package logged for potential reinstallation"
    else
        log INFO "Skipping removal of $pkg"
        return 1
    fi
}

try_find_compatible_version() {
    local pkg="$1"
    
    # Check Arch Linux Archive for previous versions
    log INFO "Checking for compatible versions in repositories..."
    
    # This would require network access to ALA, simplified for now
    return 1
}

try_downgrade_from_cache() {
    local pkg="$1"
    
    log INFO "Searching package cache for: $pkg"
    
    local cached=$(find /var/cache/pacman/pkg/ -name "${pkg}-*.pkg.tar.*" 2>/dev/null | sort -V)
    
    if [[ -z "$cached" ]]; then
        log WARN "No cached versions found"
        return 1
    fi
    
    local count=$(echo "$cached" | wc -l)
    log INFO "Found $count cached version(s)"
    
    if [[ $count -gt 1 ]]; then
        # Offer to downgrade to previous version
        local latest=$(echo "$cached" | tail -n 1)
        local previous=$(echo "$cached" | tail -n 2 | head -n 1)
        
        if ask_user "Downgrade to previous cached version?" "y"; then
            run_cmd "sudo pacman -U --noconfirm $previous"
            return $?
        fi
    fi
    
    return 1
}

update_other_managers() {
    # Flatpak
    if [[ ${MGR[flatpak]+_} ]] && [[ "$UPDATE_FLATPAK" == true ]]; then
        log STEP "Updating Flatpak applications..."
        run_cmd "flatpak update -y" || true
    fi
    
    # Snap
    if [[ ${MGR[snap]+_} ]] && [[ "$UPDATE_SNAP" == true ]]; then
        log STEP "Updating Snap applications..."
        run_cmd "sudo snap refresh" || true
    fi
    
    # NPM global packages
    if [[ ${MGR[npm]+_} ]]; then
        if ask_user "Update global NPM packages?" "n"; then
            log STEP "Updating NPM packages..."
            run_cmd "npm -g update" || true
        fi
    fi
    
    # Pip packages
    if [[ ${MGR[pip]+_} ]]; then
        if ask_user "Show outdated pip packages?" "n"; then
            log STEP "Checking pip packages..."
            pip list --outdated 2>&1 | tee -a "$LOGFILE" || true
        fi
    fi
}

perform_cleanup() {
    log STEP "System cleanup..."
    
    # CRITICAL: Check for failed systemd services first
    log INFO "Checking for failed systemd services..."
    local failed_services=$(systemctl --failed --no-pager --no-legend | wc -l)
    if [[ $failed_services -gt 0 ]]; then
        log WARN "Found $failed_services failed service(s):"
        systemctl --failed --no-pager | tee -a "$LOGFILE"
    fi
    
    # Clean package cache
    if [[ "$CLEAN_CACHE_AFTER" == true ]] || ask_user "Clean package cache?" "y"; then
        # Keep last 3 versions instead of 1
        if command -v paccache >/dev/null 2>&1; then
            log INFO "Keeping last 3 versions of installed packages..."
            run_cmd "paccache -rk3"
            log INFO "Removing all cached versions of uninstalled packages..."
            run_cmd "paccache -ruk0"
        else
            run_cmd "sudo pacman -Sc --noconfirm"
        fi
    fi
    
    # Remove orphaned packages
    if ask_user "Remove orphaned packages?" "y"; then
        local orphans=$(pacman -Qtdq 2>/dev/null)
        if [[ -n "$orphans" ]]; then
            log INFO "Found orphaned packages:"
            echo "$orphans" | tee -a "$LOGFILE"
            
            # SAFETY: Save orphan list before removal
            echo "$orphans" > "$BACKUP_DIR/orphans_$(date +%Y%m%d_%H%M%S).txt"
            
            run_cmd "sudo pacman -Rns --noconfirm $orphans"
        else
            log SUCCESS "No orphaned packages found"
        fi
    fi
    
    # CRITICAL: Check for .pacnew/.pacsave files
    log INFO "Checking for .pacnew and .pacsave files..."
    local pacnew_files=$(find /etc -name "*.pacnew" 2>/dev/null)
    local pacsave_files=$(find /etc -name "*.pacsave" 2>/dev/null)
    
    if [[ -n "$pacnew_files" ]]; then
        log WARN "Found .pacnew files that need attention:"
        echo "$pacnew_files" | tee -a "$LOGFILE"
        
        if command -v pacdiff >/dev/null 2>&1; then
            if ask_user "Run pacdiff to merge .pacnew files?" "n"; then
                log INFO "Running pacdiff (interactive)..."
                sudo DIFFPROG=vimdiff pacdiff
            fi
        else
            log INFO "Install 'pacman-contrib' for pacdiff tool to easily merge configs"
        fi
    fi
    
    if [[ -n "$pacsave_files" ]]; then
        log INFO "Found .pacsave files (old configs from removed packages):"
        echo "$pacsave_files" | tee -a "$LOGFILE"
    fi
    
    # CRITICAL: Clean package database
    log INFO "Verifying and cleaning package database..."
    run_cmd "sudo pacman -Dk" || log WARN "Database check found issues"
    
    # Clean journal logs if too large
    local journal_size=$(journalctl --disk-usage 2>/dev/null | grep -oP '\d+\.\d+[GM]' | head -n1)
    if [[ -n "$journal_size" ]]; then
        log INFO "Journal size: $journal_size"
        if ask_user "Limit journal to last 7 days?" "n"; then
            run_cmd "sudo journalctl --vacuum-time=7d"
        fi
    fi
}

verify_system_integrity() {
    log STEP "Verifying system integrity..."
    
    if [[ ${MGR[pacman]+_} ]]; then
        run_cmd "sudo pacman -Dk" || true
    fi
    
    # Check for partial upgrades
    log INFO "Checking for partial upgrades..."
    if command -v checkrebuild >/dev/null 2>&1; then
        checkrebuild 2>&1 | tee -a "$LOGFILE" || true
    fi
}

show_summary() {
    echo -e "\n${BOLD}${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${GREEN}║${NC}  ${BOLD}UPGRADE SUMMARY${NC}                                          ${BOLD}${GREEN}║${NC}"
    echo -e "${BOLD}${GREEN}╠════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}${GREEN}║${NC}  Log file: ${LOGFILE:0:40}${NC}"
    echo -e "${BOLD}${GREEN}║${NC}  Backup dir: ${BACKUP_DIR:0:37}${NC}"
    
    if [[ -f "$BACKUP_DIR/removed_packages.txt" ]]; then
        local removed=$(wc -l < "$BACKUP_DIR/removed_packages.txt")
        echo -e "${BOLD}${GREEN}║${NC}  Removed packages: $removed (see removed_packages.txt)${NC}"
    fi
    
    if [[ -f "$BACKUP_DIR/latest_snapshot.txt" ]]; then
        local snapshot=$(cat "$BACKUP_DIR/latest_snapshot.txt")
        echo -e "${BOLD}${GREEN}║${NC}  Snapshot: $snapshot${NC}"
    elif [[ -f "$BACKUP_DIR/snapper_pre_number.txt" ]]; then
        local snap_num=$(cat "$BACKUP_DIR/snapper_pre_number.txt")
        echo -e "${BOLD}${GREEN}║${NC}  Snapper snapshot: #$snap_num${NC}"
    fi
    
    echo -e "${BOLD}${GREEN}╚════════════════════════════════════════════════════════════╝${NC}\n"
    
    log SUCCESS "System upgrade completed!"
    log INFO "Review the log file for details: $LOGFILE"
    
    # Send notification if enabled
    send_notification "System Upgrade Complete" "All packages updated successfully. Check log for details."
}

send_notification() {
    local title="$1"
    local message="$2"
    
    if [[ "$SEND_NOTIFICATION" != true ]]; then
        return
    fi
    
    # For i3wm, use notify-send if available
    if command -v notify-send >/dev/null 2>&1; then
        # Check if we're in a graphical session
        if [[ -n "$DISPLAY" ]] || [[ -n "$WAYLAND_DISPLAY" ]]; then
            notify-send -u normal -t 10000 -i system-software-update "$title" "$message" 2>/dev/null || true
            log INFO "Desktop notification sent"
        fi
    fi
    
    # Alternative: dunst
    if command -v dunstify >/dev/null 2>&1; then
        dunstify -u normal -t 10000 -i system-software-update "$title" "$message" 2>/dev/null || true
    fi
    
    # For terminal-only: use wall or write
    if [[ -z "$DISPLAY" ]] && [[ -z "$WAYLAND_DISPLAY" ]]; then
        echo "$title: $message" | wall 2>/dev/null || true
    fi
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        log INFO "Loading configuration from $CONFIG_FILE"
        source "$CONFIG_FILE"
    fi
}

show_help() {
    cat << EOF
Manjaro/Arch System Upgrade Manager Pro v${VERSION}

Usage: $0 [OPTIONS]

OPTIONS:
    -h, --help              Show this help message
    -i, --interactive       Enable interactive mode (default)
    -a, --auto              Automatic mode (no prompts)
    -d, --dry-run          Show what would be done without executing
    --no-aur               Skip AUR updates
    --no-flatpak           Skip Flatpak updates
    --no-snap              Skip Snap updates
    --no-backup            Skip creating backup
    --no-snapshot          Skip filesystem snapshot (timeshift/snapper)
    --no-parallel          Disable parallel downloads
    --no-notification      Disable desktop notifications
    --auto-remove          Automatically remove conflicting packages
    --config FILE          Load configuration from FILE

EXAMPLES:
    $0                     # Interactive upgrade with all features
    $0 --auto              # Fully automatic upgrade
    $0 --dry-run           # Preview what would be done
    $0 --no-aur --no-snap  # Skip AUR and Snap updates
    $0 --no-snapshot       # Skip filesystem snapshot

CONFIGURATION FILE:
    Default location: $CONFIG_FILE
    
    Example content:
        INTERACTIVE_MODE=false
        AUTO_REMOVE_CONFLICTS=true
        UPDATE_AUR=true
        UPDATE_FLATPAK=true
        CREATE_SNAPSHOT=true
        ENABLE_PARALLEL_DOWNLOADS=true
        SEND_NOTIFICATION=true
        CHECK_BATTERY=true
        MIN_BATTERY_LEVEL=30

SNAPSHOT TOOLS:
    Supported: Timeshift (BTRFS/RSYNC) or Snapper (BTRFS)
    Auto-detected at runtime
    
    Timeshift:
        - Configure: sudo timeshift-gtk or sudo timeshift --create
        - Restore: sudo timeshift --restore
    
    Snapper:
        - Configure: sudo snapper -c root create-config /
        - List: sudo snapper list
        - Rollback: sudo snapper rollback <snapshot_number>

FOR i3WM USERS:
    - Desktop notifications via notify-send/dunstify
    - Bind to key: bindsym \$mod+u exec --no-startup-id ~/.local/bin/manjaro-upgrade-pro.sh
    - Add to i3status/i3blocks for update notifications

EOF
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================
main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help) show_help; exit 0 ;;
            -i|--interactive) INTERACTIVE_MODE=true ;;
            -a|--auto) INTERACTIVE_MODE=false ;;
            -d|--dry-run) DRY_RUN=true ;;
            --no-aur) UPDATE_AUR=false ;;
            --no-flatpak) UPDATE_FLATPAK=false ;;
            --no-snap) UPDATE_SNAP=false ;;
            --no-backup) CREATE_BACKUP=false ;;
            --auto-remove) AUTO_REMOVE_CONFLICTS=true ;;
            --config) CONFIG_FILE="$2"; shift ;;
            *) log ERROR "Unknown option: $1"; show_help; exit 1 ;;
        esac
        shift
    done
    
    load_config
    print_header
    
    log INFO "Starting system upgrade process..."
    log INFO "Mode: $([ "$INTERACTIVE_MODE" == true ] && echo "Interactive" || echo "Automatic")"
    [[ "$DRY_RUN" == true ]] && log WARN "DRY RUN MODE - No changes will be made"
    
    check_for_partial_upgrades
    check_mirror_health
    detect_managers
    
    if [[ "$CREATE_BACKUP" == true ]]; then
        create_system_snapshot
    fi
    
    check_disk_space
    
    if ! check_updates_available; then
        exit 0
    fi
    
    if ! ask_user "Proceed with system upgrade?" "y"; then
        log INFO "Upgrade cancelled by user"
        exit 0
    fi
    
    refresh_keyrings
    
    if ! perform_system_upgrade; then
        parse_and_fix_conflicts
    fi
    
    update_other_managers
    perform_cleanup
    verify_system_integrity
    show_summary
    
    log SUCCESS "All operations completed!"
}

# Run main function
main "$@"
