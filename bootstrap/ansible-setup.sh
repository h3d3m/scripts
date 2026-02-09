#!/usr/bin/env bash
# =============================================================================
# Ansible Pull Bootstrap Script
#
# Bootstraps a fresh server for 'ansible-pull' architecture.
# Automates setup of: dependencies, dedicated user, SSH keys, Vault pass,
# and Systemd timer for periodic playbook execution (every 10 min).
#
# Usage: sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/h3d3m/scripts/refs/heads/main/bootstrap/ansible-setup.sh)"
#
# Supports: Debian/Ubuntu, RHEL/CentOS/Alma/Rocky.
# =============================================================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

GIT_HOST=""
ANSIBLE_USER="ansible"
ANSIBLE_HOME="/home/$ANSIBLE_USER"
ANSIBLE_VAULT_PASS_FILE="$ANSIBLE_HOME/.ansible/.vault_pass"
ANSIBLE_FACTS_DIR="/etc/ansible/facts.d"

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

confirm() {
    while true; do
        read -p "$1 [Y/n]: " -n 1 -r
        echo
        case "$REPLY" in
            [Yy]|"") return 0 ;;
            [Nn])    return 1 ;;
            *)       echo "Invalid input: '$REPLY'!" >&2 ;;
        esac
    done
}

install_dependencies() {
	log_info "Checking and installing dependencies..."
	
	if [ -f /etc/debian_version ]; then
		apt-get -qq update
		apt-get -qq install -y git python3 python3-pip ansible software-properties-common
	elif [ -f /etc/redhat-release ]; then
		if ! rpm -q epel-release >/dev/null; then
             dnf install -y epel-release
        fi
        dnf install -y git python3 python3-pip ansible
	else
		log_err "Unsupported distribution!"
		exit 1
	fi

	log_info "Dependencies have been installed."
}

setup_user() {
	log_info "Configuring the '$ANSIBLE_USER' user..."

	if id "$ANSIBLE_USER" &>/dev/null; then
		log_warn "The user '$ANSIBLE_USER' already exists."
	else
		useradd -m -s /bin/bash "$ANSIBLE_USER"
		log_info "The user '$ANSIBLE_USER' has been created."
	fi

	local sudo_file="/etc/sudoers.d/$ANSIBLE_USER"

	if [ ! -f "$sudo_file" ]; then
		echo "$ANSIBLE_USER ALL=(ALL) NOPASSWD: ALL" | tee "$sudo_file" > /dev/null
		chmod 0440 "$sudo_file"
		log_info "Password-free sudo is configured for the user '$ANSIBLE_USER'."
	else
		log_warn "The sudoers file for the user '$ANSIBLE_USER' already exists."
	fi
}

setup_ssh() {
	local ssh_dir="$ANSIBLE_HOME/.ssh"
	local ssh_key_file="$ssh_dir/id_ed25519"
	local ssh_config_file="$ssh_dir/config"

	if confirm "Generate SSH keys for the user '$ANSIBLE_USER'?"; then
		if [ -f "$ssh_key_file" ]; then
			log_warn "SSH keys already exists."
		else
			sudo -u "$ANSIBLE_USER" ssh-keygen -t ed25519 -f "$ssh_key_file" -N "" -C "${ANSIBLE_USER}@$(hostname)" > /dev/null
			log_info "SSH keys have been generated. Copy the public key below."
			cat "$ssh_key_file.pub"
		fi
	fi

	if confirm "Configure SSH config for a git host?"; then
		read -p "Enter a domain name (default: gitlab.com): " GIT_HOST
		
		GIT_HOST=${GIT_HOST:-gitlab.com}

		sudo -u "$ANSIBLE_USER" bash -c "cat > $ssh_config_file" <<EOF
Host $GIT_HOST
    IdentityFile $ssh_key_file
    StrictHostKeyChecking accept-new
EOF
	
		sudo -u "$ANSIBLE_USER" chmod 600 "$ssh_config_file"
		log_info "SSH config has been updated."
	fi
}

setup_vault_pass() {
	local ansible_vault_dir=$(dirname "$ANSIBLE_VAULT_PASS_FILE")

	while true; do
		if confirm "Do you want to enter the vault password?"; then
			read -p "Enter vault password (input will be hidden): " -s ANSIBLE_VAULT_PASS
			echo

			if [ -n "$ANSIBLE_VAULT_PASS" ]; then
				if [ ! -d "$ansible_vault_dir" ]; then
					sudo -u "$ANSIBLE_USER" mkdir -p "$ansible_vault_dir"
					log_info "Created directory $ansible_vault_dir."
				fi

				echo "$ANSIBLE_VAULT_PASS" | sudo -u "$ANSIBLE_USER" tee "$ANSIBLE_VAULT_PASS_FILE" > /dev/null 
				sudo -u "$ANSIBLE_USER" chmod 0400 "$ANSIBLE_VAULT_PASS_FILE"

				log_info "Vault password saved to $ANSIBLE_VAULT_PASS_FILE"

				break
			else
				echo "Vault password can't be empty!" >&2
			fi
		else
			log_warn "Vault password setup skipped. Don't forget to create it manually at $ANSIBLE_VAULT_PASS_FILE."

			break
		fi
	done
}

setup_custom_facts() {
	while true; do
		if confirm "Do you want to set specific roles/facts for this host?"; then
			read -p "Enter host roles (e.g. webserver, db, k8s-worker): " ANSIBLE_HOST_ROLES
			if [ -n "$ANSIBLE_HOST_ROLES" ]; then
				if [ ! -d "$ANSIBLE_FACTS_DIR" ]; then
					mkdir -p "$ANSIBLE_FACTS_DIR"
					chmod 0755 "$ANSIBLE_FACTS_DIR"
				fi
				
				local ansible_facts_file="$ANSIBLE_FACTS_DIR/custom.fact"
				echo "{\"role\": \"$ANSIBLE_HOST_ROLES\"}" > "$ansible_facts_file"
				chmod 0644 "$ansible_facts_file"

				log_info "Custom facts written to $ansible_facts_file"

				break
			else
				echo "Input can't be empty!" >&2
			fi
		else
			break
		fi
	done
}

setup_systemd() {
	if confirm "Configure and enable systemd timer?"; then
		while true; do
			read -p "Enter git repository URL (e.g. git@gitlab.com:user/infra.git): " REPO_URL
			if [ -z "$REPO_URL" ]; then
				echo "Repository URL is required!" >&2
			else
				break
			fi
		done

		read -p "Enter git branch name (default: main): " GIT_BRANCH
		GIT_BRANCH=${GIT_BRANCH:-main}

		read -p "Enter playbook name (default: local.yml): " ANSIBLE_PLAYBOOK_NAME
		ANSIBLE_PLAYBOOK_NAME=${ANSIBLE_PLAYBOOK_NAME:-local.yml}

		local ansible_vault_arg=""
		if [ -f "$ANSIBLE_VAULT_PASS_FILE" ]; then
			ansible_vault_arg="--vault-password-file $ANSIBLE_VAULT_PASS_FILE"
		else
			log_warn "Vault password file not found. Service will run WITHOUT vault decryption!"
		fi

		local systemd_service_file="/etc/systemd/system/ansible-pull.service"
		cat > "$systemd_service_file" <<EOF
[Unit]
Description=Ansible Pull Infrastructure Update
After=network-online.target
Wants=network-online.target

[Service]
User=$ANSIBLE_USER
ExecStart=/usr/bin/ansible-pull -U $REPO_URL -C $GIT_BRANCH -i localhost, $ansible_vault_arg $ANSIBLE_PLAYBOOK_NAME
TimeoutStopSec=600
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
		log_info "Systemd service created at $systemd_service_file"

		local systemd_timer_file="/etc/systemd/system/ansible-pull.timer"
		cat > "$systemd_timer_file" <<EOF
[Unit]
Description=Run ansible-pull every 10 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=10min
RandomizedDelaySec=60
Unit=ansible-pull.service

[Install]
WantedBy=timers.target
EOF
		log_info "Systemd timer created at $systemd_timer_file"

		systemctl daemon-reload
		systemctl enable --now ansible-pull.timer
		log_info "Systemd timer enabled and started."
        log_info "Check status with: systemctl status ansible-pull.timer"
	fi
}

check_environment() {
	if id "$ANSIBLE_USER" &> /dev/null; then
		log_info "User '$ANSIBLE_USER' is ${GREEN}OK${NC}"
	else
		log_warn "User '$ANSIBLE_USER' doesn't exist."
	fi

	if [[ -f "$ANSIBLE_HOME/.ssh/id_ed25519" && -f "$ANSIBLE_HOME/.ssh/id_ed25519.pub" ]]; then
		log_info "SSH keys are ${GREEN}OK${NC}"
	else
		log_warn "Can't find SSH keys at $ANSIBLE_HOME/.ssh"
	fi

    if [ ! -f "$ANSIBLE_HOME/.ssh/config" ]; then
        log_warn "Can't find SSH config at $ANSIBLE_HOME/.ssh"
    else
        log_info "SSH config is ${GREEN}OK${NC}"
        
		if [ -z "$GIT_HOST" ]; then
            GIT_HOST=$(sudo -u "$ANSIBLE_USER" sed -n 's/^Host \([^*].*\)/\1/p' "$ANSIBLE_HOME/.ssh/config" | head -n 1)
        fi

        if [ -z "$GIT_HOST" ]; then
            log_warn "Skipping SSH connection check (Host not found in config)."
        else
            log_info "Testing SSH access to $GIT_HOST..."
            if sudo -u "$ANSIBLE_USER" ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T "git@$GIT_HOST" 2>&1 | grep -qE "Welcome|Hi"; then
                log_info "SSH connection to $GIT_HOST is ${GREEN}OK${NC}"
            else
                log_warn "SSH connection to $GIT_HOST FAILED."
            fi
        fi
    fi

	if [ -f "$ANSIBLE_VAULT_PASS_FILE" ]; then
		log_info "Vault password is ${GREEN}OK${NC}"
	else
		log_warn "Can't find vault password at $ANSIBLE_VAULT_PASS_FILE. Service might fail if your playbook is encrypted."
	fi

	if systemctl is-active --quiet ansible-pull.timer; then
		log_info "Systemd timer is ${GREEN}OK${NC}"
	else
		log_err "Systemd timer failed to start"
	fi
}

main() {
    if [ "$EUID" -ne 0 ]; then
        log_err "Please, execute the script with sudo."
	exit 1
    fi

	install_dependencies

	if confirm "Whether to start set up this environment for ansible-pull?"; then
		setup_user
		setup_ssh
		setup_vault_pass
		setup_custom_facts
		setup_systemd
		
		log_info "Configuration is complete."
	fi

	log_info "Performing environment check..."
	check_environment

	echo -e "${GREEN}Done${NC}"
}

main
