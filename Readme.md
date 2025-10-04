# i3wm Integration Guide - System Upgrade Manager

## 📦 Installation

```bash
# 1. Install the main script
sudo cp manjaro-upgrade-pro.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/manjaro-upgrade-pro.sh

# Or for user-only:
mkdir -p ~/.local/bin
cp manjaro-upgrade-pro.sh ~/.local/bin/
chmod +x ~/.local/bin/manjaro-upgrade-pro.sh
```

## 🔧 Dependencies for i3wm

```bash
# Essential
sudo pacman -S --needed libnotify dunst

# Optional but recommended
sudo pacman -S --needed \
    timeshift \           # or snapper for BTRFS snapshots
    pacman-contrib \      # for paccache, pacdiff, checkupdates
    reflector \           # for mirror management
    cronie                # for timeshift scheduling

# Enable notification daemon
systemctl --user enable --now dunst
```

## ⚙️ Configuration File

Create `~/.config/system-upgrade.conf`:

```bash
# System Upgrade Configuration for i3wm

# Behavior
INTERACTIVE_MODE=true              # Ask before actions
AUTO_REMOVE_CONFLICTS=false        # Don't auto-remove conflicts
DRY_RUN=false                      # Execute commands (not just preview)

# Features
CREATE_BACKUP=true                 # Backup package lists
CREATE_SNAPSHOT=true               # Create filesystem snapshot
ENABLE_PARALLEL_DOWNLOADS=true    # 5 parallel downloads
CLEAN_CACHE_AFTER=true            # Clean cache after upgrade

# Updates
UPDATE_AUR=true                    # Include AUR packages
UPDATE_FLATPAK=true               # Update Flatpak apps
UPDATE_SNAP=false                 # Skip Snap (if not used)

# Notifications (important for i3wm)
SEND_NOTIFICATION=true            # Desktop notifications

# Safety
CHECK_BATTERY=true                # Check battery before upgrade
MIN_BATTERY_LEVEL=30              # Minimum 30% or AC required
```

## 🎨 i3 Config Integration

Add to `~/.config/i3/config`:

```bash
# System Upgrade Manager
bindsym $mod+u exec --no-startup-id alacritty -e ~/.local/bin/manjaro-upgrade-pro.sh

# Or with rofi menu
bindsym $mod+Shift+u exec --no-startup-id ~/.config/i3/scripts/upgrade-menu.sh

# Or background auto-update check (on login)
exec_always --no-startup-id ~/.config/i3/scripts/check-updates.sh
```

## 📜 Helper Scripts for i3wm

### 1. Update Check Script (`~/.config/i3/scripts/check-updates.sh`)

```bash
#!/bin/bash
# Check for updates periodically and notify

CACHE_FILE="$HOME/.cache/system-updates"
CHECK_INTERVAL=3600  # 1 hour

# Create cache file if not exists
touch "$CACHE_FILE"

last_check=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)
current_time=$(date +%s)
time_diff=$((current_time - last_check))

if [[ $time_diff -gt $CHECK_INTERVAL ]]; then
    # Check for updates
    updates=$(checkupdates 2>/dev/null | wc -l)
    aur_updates=$(yay -Qua 2>/dev/null | wc -l)
    total=$((updates + aur_updates))
    
    if [[ $total -gt 0 ]]; then
        notify-send -u normal -i system-software-update \
            "System Updates Available" \
            "$updates official + $aur_updates AUR packages\nPress \$mod+u to upgrade"
        
        echo "$total" > "$CACHE_FILE"
    else
        echo "0" > "$CACHE_FILE"
    fi
    
    touch "$CACHE_FILE"
fi
```

### 2. Interactive Menu (`~/.config/i3/scripts/upgrade-menu.sh`)

```bash
#!/bin/bash
# Rofi menu for upgrade options

OPTIONS="🔄 Full System Upgrade
📦 Check Updates Only
🔍 View Last Log
📸 Create Snapshot Only
🧹 Clean Cache
🔙 Rollback (Timeshift/Snapper)
❌ Cancel"

CHOICE=$(echo -e "$OPTIONS" | rofi -dmenu -i -p "System Upgrade" -theme-str 'window {width: 400px;}')

case "$CHOICE" in
    "🔄 Full System Upgrade")
        alacritty -e bash -c "~/.local/bin/manjaro-upgrade-pro.sh; read -p 'Press enter to close'"
        ;;
    "📦 Check Updates Only")
        alacritty -e bash -c "checkupdates; yay -Qua; read -p 'Press enter to close'"
        ;;
    "🔍 View Last Log")
        LOG=$(ls -t ~/.system-upgrade-logs/upgrade_*.log 2>/dev/null | head -n1)
        if [[ -n "$LOG" ]]; then
            alacritty -e less "$LOG"
        else
            notify-send "No Log Found" "No upgrade logs available"
        fi
        ;;
    "📸 Create Snapshot Only")
        alacritty -e bash -c "sudo timeshift --create --comments 'Manual snapshot'; read -p 'Press enter to close'"
        ;;
    "🧹 Clean Cache")
        alacritty -e bash -c "sudo pacman -Sc; paccache -rk3; read -p 'Press enter to close'"
        ;;
    "🔙 Rollback (Timeshift/Snapper)")
        if command -v timeshift >/dev/null; then
            alacritty -e sudo timeshift-gtk
        elif command -v snapper >/dev/null; then
            alacritty -e bash -c "sudo snapper list; read -p 'Enter snapshot number to rollback: ' NUM; sudo snapper rollback \$NUM"
        fi
        ;;
esac
```

### 3. i3blocks/i3status Module

For **i3blocks** (`~/.config/i3blocks/blocks/updates`):

```bash
#!/bin/bash
# Show available updates in i3blocks

updates=$(checkupdates 2>/dev/null | wc -l)
aur=$(yay -Qua 2>/dev/null | wc -l)
total=$((updates + aur))

if [[ $total -gt 0 ]]; then
    echo "📦 $total"  # Full text
    echo "📦 $total"  # Short text
    echo "#FF6B6B"   # Color (red-ish)
else
    echo ""
    echo ""
fi
```

Add to `~/.config/i3blocks/config`:

```ini
[updates]
command=~/.config/i3blocks/blocks/updates
interval=3600
signal=12
```

For **i3status** (add to `~/.config/i3status/config`):

```
order += "run_watch UPDATES"

run_watch UPDATES {
    pidfile = "/tmp/i3status-updates.pid"
    format = "📦 %title"
    format_down = ""
}
```

## 🎯 Usage Examples

### Basic Interactive Upgrade
```bash
manjaro-upgrade-pro.sh
```

### Automatic Upgrade (cron/systemd timer)
```bash
manjaro-upgrade-pro.sh --auto --no-notification
```

### Check What Would Happen (Dry Run)
```bash
manjaro-upgrade-pro.sh --dry-run
```

### Quick Upgrade (Skip AUR, No Snapshot)
```bash
manjaro-upgrade-pro.sh --no-aur --no-snapshot
```

## 🔔 Systemd Timer (Optional Auto-Updates)

Create `~/.config/systemd/user/system-upgrade.service`:

```ini
[Unit]
Description=Automatic System Upgrade
After=network-online.target

[Service]
Type=oneshot
ExecStart=%h/.local/bin/manjaro-upgrade-pro.sh --auto
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
```

Create `~/.config/systemd/user/system-upgrade.timer`:

```ini
[Unit]
Description=Run system upgrade weekly

[Timer]
OnCalendar=Sun 02:00
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
```

Enable:
```bash
systemctl --user enable --now system-upgrade.timer
systemctl --user status system-upgrade.timer
```

## 🛡️ Snapshot Management

### Timeshift Setup (BTRFS or RSYNC)

```bash
# Initial setup
sudo timeshift --create --comments "Initial snapshot"

# Configure automatic snapshots
sudo timeshift-gtk  # GUI
# or
sudo timeshift --list  # CLI
```

### Snapper Setup (BTRFS only)

```bash
# Create config for root
sudo snapper -c root create-config /

# Create config for home (if separate partition)
sudo snapper -c home create-config /home

# List snapshots
sudo snapper list

# Create manual snapshot
sudo snapper create --description "Before big changes"

# Rollback
sudo snapper rollback <snapshot_number>
```

## 🔍 Troubleshooting

### Notifications Not Working?
```bash
# Check dunst is running
systemctl --user status dunst

# Restart dunst
systemctl --user restart dunst

# Test notification
notify-send "Test" "This is a test notification"
```

### Updates Not Detected?
```bash
# Ensure checkupdates is available
sudo pacman -S pacman-contrib

# Check manually
checkupdates
yay -Qua
```

### Timeshift Fails?
```bash
# Check cron service
sudo systemctl status cronie
sudo systemctl enable --now cronie

# Check Timeshift config
sudo timeshift --list-devices
cat /etc/timeshift/timeshift.json
```

## ⌨️ Recommended i3 Keybindings

```bash
# System management
bindsym $mod+u exec --no-startup-id alacritty -e ~/.local/bin/manjaro-upgrade-pro.sh
bindsym $mod+Shift+u exec --no-startup-id ~/.config/i3/scripts/upgrade-menu.sh

# Quick actions
bindsym $mod+Ctrl+u exec --no-startup-id ~/.config/i3/scripts/check-updates.sh
bindsym $mod+Ctrl+s exec --no-startup-id alacritty -e sudo timeshift --create

# Package management
bindsym $mod+Shift+p exec --no-startup-id rofi -show run -run-command 'alacritty -e {cmd}'
```

## 📊 Monitoring with Conky (Optional)

Add to `~/.config/conky/conky.conf`:

```lua
${color lightgrey}System Updates:${color}
${execpi 3600 checkupdates | wc -l} official
${execpi 3600 yay -Qua | wc -l} AUR

${color lightgrey}Last Upgrade:${color}
${execi 3600 ls -t ~/.system-upgrade-logs/*.log | head -n1 | xargs stat -c %y | cut -d. -f1}
```

## 🎨 Polybar Module (Alternative to i3blocks)

Add to `~/.config/polybar/config`:

```ini
[module/updates]
type = custom/script
exec = ~/.config/polybar/scripts/check-updates.sh
interval = 3600
label = %output%
click-left = alacritty -e ~/.local/bin/manjaro-upgrade-pro.sh
click-right = ~/.config/i3/scripts/upgrade-menu.sh
format-prefix = "📦 "
format-prefix-foreground = ${colors.primary}
```

Script `~/.config/polybar/scripts/check-updates.sh`:

```bash
#!/bin/bash
updates=$(checkupdates 2>/dev/null | wc -l)
aur=$(yay -Qua 2>/dev/null | wc -l)
total=$((updates + aur))

if [[ $total -gt 0 ]]; then
    echo "$total updates"
else
    echo "Up to date"
fi
```

## 📝 Notes for i3wm Users

1. **Terminal Emulator**: Script tested with alacritty, kitty, termite, urxvt
2. **Notification Daemon**: Dunst recommended (lightweight)
3. **Rofi Version**: Works with rofi 1.7+
4. **Font Requirements**: Nerd Fonts for icons in polybar/i3blocks

---

**Pro Tip**: Bind the script to a dmenu/rofi launcher for quick access without memorizing keybindings!
