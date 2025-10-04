#!/usr/bin/env bash
# quick-setup-upgrade-manager.sh
# One-command installer for System Upgrade Manager + i3wm integration

set -e

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${BOLD}${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║  System Upgrade Manager - Quick Setup for i3wm           ║${NC}"
echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════════════════════╝${NC}\n"

# Check if running on Arch-based system
if ! command -v pacman >/dev/null 2>&1; then
    echo -e "${YELLOW}Warning: This script is designed for Arch-based systems${NC}"
    read -p "Continue anyway? [y/N] " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

echo -e "${BOLD}[1/8] Installing dependencies...${NC}"
sudo pacman -S --needed --noconfirm \
    libnotify \
    dunst \
    pacman-contrib \
    reflector \
    cronie \
    alacritty 2>/dev/null || true

# Optional: rofi for menu
if ! command -v rofi >/dev/null 2>&1; then
    read -p "Install rofi for interactive menu? [Y/n] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
        sudo pacman -S --needed rofi
    fi
fi

# Check for snapshot tools
echo -e "\n${BOLD}[2/8] Checking snapshot tools...${NC}"
if ! command -v timeshift >/dev/null 2>&1 && ! command -v snapper >/dev/null 2>&1; then
    echo -e "${YELLOW}No snapshot tool detected${NC}"
    echo "Snapshot tools protect your system by creating restore points"
    echo ""
    echo "Available options:"
    echo "  1) Timeshift (recommended for beginners, works with BTRFS and ext4)"
    echo "  2) Snapper (advanced, BTRFS only)"
    echo "  3) Skip snapshot tools"
    read -p "Choose [1/2/3]: " choice
    
    case $choice in
        1)
            if command -v yay >/dev/null 2>&1; then
                yay -S --needed timeshift
            else
                sudo pacman -S --needed timeshift
            fi
            ;;
        2)
            sudo pacman -S --needed snapper
            # Check if root is BTRFS
            if findmnt -n -o FSTYPE / | grep -q btrfs; then
                echo -e "${GREEN}BTRFS detected - configuring snapper...${NC}"
                sudo snapper -c root create-config / 2>/dev/null || true
            else
                echo -e "${YELLOW}Warning: Root is not BTRFS. Snapper may not work properly.${NC}"
            fi
            ;;
        3)
            echo "Skipping snapshot tools (not recommended)"
            ;;
    esac
fi

echo -e "\n${BOLD}[3/8] Creating directory structure...${NC}"
mkdir -p ~/.local/bin
mkdir -p ~/.config/i3/scripts
mkdir -p ~/.config/system-upgrade-logs
mkdir -p ~/.system-upgrade-backups
mkdir -p ~/.config/i3blocks/blocks 2>/dev/null || true
mkdir -p ~/.config/polybar/scripts 2>/dev/null || true

echo -e "\n${BOLD}[4/8] Installing main upgrade script...${NC}"
SCRIPT_URL="https://raw.githubusercontent.com/your-repo/manjaro-upgrade-pro.sh"

# If script exists locally, use it
if [[ -f "manjaro-upgrade-pro.sh" ]]; then
    cp manjaro-upgrade-pro.sh ~/.local/bin/
    chmod +x ~/.local/bin/manjaro-upgrade-pro.sh
    echo -e "${GREEN}✓ Installed from local file${NC}"
else
    echo -e "${YELLOW}Please place manjaro-upgrade-pro.sh in current directory${NC}"
    exit 1
fi

echo -e "\n${BOLD}[5/8] Creating configuration file...${NC}"
cat > ~/.config/system-upgrade.conf << 'EOF'
# System Upgrade Manager Configuration

# Behavior
INTERACTIVE_MODE=true
AUTO_REMOVE_CONFLICTS=false
DRY_RUN=false

# Features
CREATE_BACKUP=true
CREATE_SNAPSHOT=true
ENABLE_PARALLEL_DOWNLOADS=true
CLEAN_CACHE_AFTER=true

# Updates
UPDATE_AUR=true
UPDATE_FLATPAK=true
UPDATE_SNAP=false

# Notifications
SEND_NOTIFICATION=true

# Safety
CHECK_BATTERY=true
MIN_BATTERY_LEVEL=30
EOF
echo -e "${GREEN}✓ Created ~/.config/system-upgrade.conf${NC}"

echo -e "\n${BOLD}[6/8] Creating i3wm helper scripts...${NC}"

# Update checker
cat > ~/.config/i3/scripts/check-updates.sh << 'EOF'
#!/bin/bash
CACHE_FILE="$HOME/.cache/system-updates"
CHECK_INTERVAL=3600

touch "$CACHE_FILE"
last_check=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)
current_time=$(date +%s)
time_diff=$((current_time - last_check))

if [[ $time_diff -gt $CHECK_INTERVAL ]]; then
    updates=$(checkupdates 2>/dev/null | wc -l)
    aur_updates=0
    
    if command -v yay >/dev/null 2>&1; then
        aur_updates=$(yay -Qua 2>/dev/null | wc -l)
    fi
    
    total=$((updates + aur_updates))
    
    if [[ $total -gt 0 ]]; then
        notify-send -u normal -i system-software-update \
            "System Updates Available" \
            "$updates official + $aur_updates AUR packages\nRun upgrade manager to install"
        echo "$total" > "$CACHE_FILE"
    else
        echo "0" > "$CACHE_FILE"
    fi
    
    touch "$CACHE_FILE"
fi
EOF
chmod +x ~/.config/i3/scripts/check-updates.sh

# Upgrade menu (if rofi available)
if command -v rofi >/dev/null 2>&1; then
    cat > ~/.config/i3/scripts/upgrade-menu.sh << 'EOF'
#!/bin/bash
OPTIONS="🔄 Full System Upgrade
📦 Check Updates Only
🔍 View Last Log
📸 Create Snapshot Only
🧹 Clean Cache
🔙 Rollback Snapshot
❌ Cancel"

CHOICE=$(echo -e "$OPTIONS" | rofi -dmenu -i -p "System Upgrade" -theme-str 'window {width: 400px;}')

case "$CHOICE" in
    "🔄 Full System Upgrade")
        alacritty -e bash -c "$HOME/.local/bin/manjaro-upgrade-pro.sh; read -p 'Press enter to close'"
        ;;
    "📦 Check Updates Only")
        alacritty -e bash -c "checkupdates; echo ''; yay -Qua 2>/dev/null; read -p 'Press enter to close'"
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
        if command -v timeshift >/dev/null; then
            alacritty -e bash -c "sudo timeshift --create --comments 'Manual snapshot'; read -p 'Press enter to close'"
        elif command -v snapper >/dev/null; then
            alacritty -e bash -c "sudo snapper create --description 'Manual snapshot'; read -p 'Press enter to close'"
        fi
        ;;
    "🧹 Clean Cache")
        alacritty -e bash -c "sudo pacman -Sc; paccache -rk3 2>/dev/null; read -p 'Press enter to close'"
        ;;
    "🔙 Rollback Snapshot")
        if command -v timeshift >/dev/null; then
            alacritty -e sudo timeshift-gtk
        elif command -v snapper >/dev/null; then
            alacritty -e bash -c "sudo snapper list; echo ''; read -p 'Enter snapshot number to rollback: ' NUM; sudo snapper rollback \$NUM"
        fi
        ;;
esac
EOF
    chmod +x ~/.config/i3/scripts/upgrade-menu.sh
    echo -e "${GREEN}✓ Created rofi upgrade menu${NC}"
fi

# i3blocks module
cat > ~/.config/i3blocks/blocks/updates << 'EOF'
#!/bin/bash
updates=$(checkupdates 2>/dev/null | wc -l)
aur=0

if command -v yay >/dev/null 2>&1; then
    aur=$(yay -Qua 2>/dev/null | wc -l)
fi

total=$((updates + aur))

if [[ $total -gt 0 ]]; then
    echo "📦 $total"
    echo "📦 $total"
    echo "#FF6B6B"
else
    echo ""
fi
EOF
chmod +x ~/.config/i3blocks/blocks/updates

echo -e "${GREEN}✓ Created i3blocks module${NC}"

# Polybar module script
cat > ~/.config/polybar/scripts/check-updates.sh << 'EOF'
#!/bin/bash
updates=$(checkupdates 2>/dev/null | wc -l)
aur=0

if command -v yay >/dev/null 2>&1; then
    aur=$(yay -Qua 2>/dev/null | wc -l)
fi

total=$((updates + aur))

if [[ $total -gt 0 ]]; then
    echo "$total updates"
else
    echo ""
fi
EOF
chmod +x ~/.config/polybar/scripts/check-updates.sh

echo -e "\n${BOLD}[7/8] Configuring i3wm keybindings...${NC}"

if [[ -f ~/.config/i3/config ]]; then
    if ! grep -q "manjaro-upgrade-pro" ~/.config/i3/config; then
        echo "" >> ~/.config/i3/config
        echo "# System Upgrade Manager" >> ~/.config/i3/config
        echo "bindsym \$mod+u exec --no-startup-id alacritty -e $HOME/.local/bin/manjaro-upgrade-pro.sh" >> ~/.config/i3/config
        
        if command -v rofi >/dev/null 2>&1; then
            echo "bindsym \$mod+Shift+u exec --no-startup-id $HOME/.config/i3/scripts/upgrade-menu.sh" >> ~/.config/i3/config
        fi
        
        echo "exec_always --no-startup-id $HOME/.config/i3/scripts/check-updates.sh" >> ~/.config/i3/config
        
        echo -e "${GREEN}✓ Added keybindings to i3 config${NC}"
        echo -e "  ${CYAN}Mod+u${NC} - Run upgrade manager"
        if command -v rofi >/dev/null 2>&1; then
            echo -e "  ${CYAN}Mod+Shift+u${NC} - Open upgrade menu"
        fi
    else
        echo -e "${YELLOW}⚠ Keybindings already exist in i3 config${NC}"
    fi
else
    echo -e "${YELLOW}⚠ i3 config not found at ~/.config/i3/config${NC}"
fi

echo -e "\n${BOLD}[8/8] Enabling services...${NC}"

# Enable dunst
if command -v dunst >/dev/null 2>&1; then
    systemctl --user enable --now dunst 2>/dev/null || true
    echo -e "${GREEN}✓ Enabled dunst notification daemon${NC}"
fi

# Enable cronie (for timeshift)
if command -v timeshift >/dev/null 2>&1; then
    sudo systemctl enable --now cronie 2>/dev/null || true
    echo -e "${GREEN}✓ Enabled cronie service${NC}"
fi

echo -e "\n${BOLD}${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║  Installation Complete!                                   ║${NC}"
echo -e "${BOLD}${GREEN}╚════════════════════════════════════════════════════════════╝${NC}\n"

echo -e "${BOLD}Next Steps:${NC}"
echo ""
echo -e "1. ${CYAN}Reload i3 config:${NC} Press \$mod+Shift+r"
echo -e "2. ${CYAN}Run upgrade manager:${NC} Press \$mod+u"
echo -e "3. ${CYAN}Test notification:${NC}"
echo -e "   notify-send 'Test' 'Notification working!'"
echo ""

if command -v timeshift >/dev/null 2>&1; then
    echo -e "4. ${CYAN}Configure Timeshift:${NC}"
    echo -e "   sudo timeshift-gtk"
    echo ""
elif command -v snapper >/dev/null 2>&1; then
    echo -e "4. ${CYAN}Configure Snapper:${NC}"
    echo -e "   sudo snapper list"
    echo ""
fi

echo -e "${BOLD}Keybindings:${NC}"
echo -e "  ${CYAN}\$mod+u${NC}         - Open upgrade manager"
if command -v rofi >/dev/null 2>&1; then
    echo -e "  ${CYAN}\$mod+Shift+u${NC}   - Open upgrade menu (rofi)"
fi
echo ""

echo -e "${BOLD}Configuration:${NC}"
echo -e "  Edit: ${CYAN}~/.config/system-upgrade.conf${NC}"
echo -e "  Logs: ${CYAN}~/.system-upgrade-logs/${NC}"
echo -e "  Backups: ${CYAN}~/.system-upgrade-backups/${NC}"
echo ""

echo -e "${BOLD}${YELLOW}Optional:${NC}"
echo -e "  • Add i3blocks module (see documentation)"
echo -e "  • Set up systemd timer for auto-updates"
echo -e "  • Customize rofi theme"
echo ""

read -p "Open documentation? [Y/n] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "https://github.com/your-repo/docs" 2>/dev/null || \
        echo "View documentation at: https://github.com/your-repo/docs"
    fi
fi

echo -e "\n${GREEN}Setup complete! Enjoy your automated system upgrades! 🚀${NC}"
