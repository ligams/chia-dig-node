#!/bin/bash

###############################################################################
#                       DIG Node Setup Script with SSL and Let's Encrypt
# This script installs and configures a DIG Node with Nginx reverse proxy,
# using HTTPS to communicate with the content server, and attaching client
# certificates. It also sets up Let's Encrypt SSL certificates if a hostname
# is provided and the user opts in. Please run this script as root.
###############################################################################

# Variables
USER_NAME=${SUDO_USER:-$(whoami)}             # User executing the script
USER_HOME=$(eval echo "~$USER_NAME")          # Home directory of the user
SERVICE_NAME="dig@$USER_NAME.service"         # Systemd service name
SERVICE_FILE_PATH="/etc/systemd/system/$SERVICE_NAME"
WORKING_DIR=$(pwd)                            # Current working directory

# Required software
REQUIRED_SOFTWARE=(docker docker-compose firewalld openssl certbot)

# Color codes
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
RED='\033[1;31m'
NC='\033[0m' # No Color

###############################################################################
#                         Function Definitions
###############################################################################

# Check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Stop the service if it's running
stop_existing_service() {
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "\n${YELLOW}Stopping the existing service $SERVICE_NAME...${NC}"
        systemctl stop "$SERVICE_NAME"
        echo -e "${GREEN}Service $SERVICE_NAME stopped.${NC}"
    fi
}

# Install missing software instructions
install_missing_software() {
    if [ -x "$(command -v yum)" ]; then
        echo -e "\n${YELLOW}To install missing software on Amazon Linux 2, run:${NC}"
        for SOFTWARE in "${MISSING_SOFTWARE[@]}"; do
            case "$SOFTWARE" in
                docker)
                    echo "sudo amazon-linux-extras install docker -y"
                    ;;
                docker-compose)
                    echo "sudo curl -L 'https://github.com/docker/compose/releases/download/v2.21.0/docker-compose-$(uname -s)-$(uname -m)' -o /usr/local/bin/docker-compose"
                    echo "sudo chmod +x /usr/local/bin/docker-compose"
                    ;;
                firewalld)
                    echo "sudo yum install firewalld -y"
                    echo "sudo systemctl start firewalld"
                    echo "sudo systemctl enable firewalld"
                    ;;
                certbot)
                    echo "sudo yum install certbot -y"
                    ;;
                *)
                    echo "sudo yum install $SOFTWARE -y"
                    ;;
            esac
        done
    else
        echo -e "${RED}Package manager not detected. Please manually install the missing software.${NC}"
    fi
}

# Open ports using firewalld
open_ports() {
    echo -e "\n${BLUE}This setup uses the following ports:${NC}"
    echo " - Port 4159: Propagation Server"
    echo " - Port 4160: Incentive Server"
    echo " - Port 4161: Content Server"
    echo " - Port 22: SSH (for remote access)"

    if [[ $INCLUDE_NGINX == "yes" ]]; then
        echo " - Port 80: Reverse Proxy (HTTP)"
        echo " - Port 443: Reverse Proxy (HTTPS)"
        PORTS=(22 80 443 4159 4160 4161)
    else
        PORTS=(22 4159 4160 4161)
    fi

    echo ""
    read -p "Do you want to open these ports (${PORTS[*]}) using firewalld? (y/n): " -n 1 -r
    echo    # Move to a new line

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo -e "\n${BLUE}Opening ports: ${PORTS[*]}...${NC}"
        for PORT in "${PORTS[@]}"; do
            sudo firewall-cmd --zone=public --add-port=${PORT}/tcp --permanent
        done
        sudo firewall-cmd --reload
        echo -e "${GREEN}Ports have been opened in firewalld.${NC}"
    else
        echo -e "${YELLOW}Skipping firewalld port opening.${NC}"
    fi
}

###############################################################################
#                         Script Execution Begins
###############################################################################

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
    echo -e "\n${RED}Please run this script as root.${NC}"
    exit 1
fi

# Display script header
echo -e "${GREEN}
###############################################################################
#                       DIG Node Setup Script with SSL and Let's Encrypt
###############################################################################
${NC}"

# Check for required software
echo -e "${BLUE}Checking for required software...${NC}"
MISSING_SOFTWARE=()
for SOFTWARE in "${REQUIRED_SOFTWARE[@]}"; do
    if ! command_exists "$SOFTWARE"; then
        MISSING_SOFTWARE+=("$SOFTWARE")
    fi
done

if [ ${#MISSING_SOFTWARE[@]} -ne 0 ]; then
    echo -e "\n${RED}The following required software is missing:${NC}"
    for SOFTWARE in "${MISSING_SOFTWARE[@]}"; do
        echo " - $SOFTWARE"
    done

    # Provide installation instructions
    install_missing_software

    echo -e "\n${RED}Please install the missing software and rerun the script.${NC}"
    exit 1
fi
echo -e "${GREEN}All required software is installed.${NC}"

# Start and enable firewalld if not already running
if ! systemctl is-active --quiet firewalld; then
    echo -e "\n${BLUE}Starting and enabling firewalld...${NC}"
    sudo systemctl start firewalld
    sudo systemctl enable firewalld
fi

# Stop the existing service if it is running
stop_existing_service

# Check if the current user is in the Docker group
if id -nG "$USER_NAME" | grep -qw "docker"; then
    echo -e "\n${GREEN}User $USER_NAME is already in the docker group.${NC}"
else
    echo -e "\n${YELLOW}To work properly, your user must be added to the docker group.${NC}"
    read -p "Would you like to add $USER_NAME to the docker group now? (y/n): " -n 1 -r
    echo    # Move to a new line

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        usermod -aG docker "$USER_NAME"
        echo -e "${GREEN}User $USER_NAME has been added to the docker group.${NC}"
    else
        echo -e "${RED}User $USER_NAME must be in the docker group to proceed. Exiting.${NC}"
        exit 1
    fi

    # Check again if the current user is in the Docker group
    if id -nG "$USER_NAME" | grep -qw "docker"; then
        echo -e "${GREEN}User $USER_NAME is now in the docker group.${NC}"
    else
        echo -e "${RED}Failed to add $USER_NAME to the docker group. Exiting.${NC}"
        exit 1
    fi
fi

# Generate DIG_USERNAME and DIG_PASSWORD
echo -e "\n${BLUE}Generating high-entropy DIG_USERNAME and DIG_PASSWORD...${NC}"
DIG_USERNAME=$(openssl rand -hex 16)
DIG_PASSWORD=$(openssl rand -hex 32)
echo -e "${GREEN}Credentials generated successfully.${NC}"

# Prompt for TRUSTED_FULLNODE
echo -e "\n${BLUE}Please enter the TRUSTED_FULLNODE (optional):${NC}"
read -p "Your personal full node's public IP for better performance (press Enter to skip): " TRUSTED_FULLNODE
TRUSTED_FULLNODE=${TRUSTED_FULLNODE:-"not-provided"}

# Prompt for PUBLIC_IP
echo -e "\n${BLUE}If needed, enter a PUBLIC_IP override (optional):${NC}"
read -p "Leave blank for auto-detection: " PUBLIC_IP
PUBLIC_IP=${PUBLIC_IP:-"not-provided"}

# Prompt for Mercenary Mode
echo -e "\n${BLUE}Enable Mercenary Mode?${NC}"
echo "This allows your node to hunt for mirror offers to earn rewards."
read -p "Do you want to enable Mercenary Mode? (y/n): " -n 1 -r
echo    # Move to a new line

if [[ $REPLY =~ ^[Yy]$ ]]; then
    MERCENARY_MODE="true"
else
    MERCENARY_MODE="false"
fi

# Prompt for DISK_SPACE_LIMIT_BYTES
echo -e "\n${BLUE}Enter DISK_SPACE_LIMIT_BYTES (optional):${NC}"
read -p "Leave blank for default (1 TB): " DISK_SPACE_LIMIT_BYTES
DISK_SPACE_LIMIT_BYTES=${DISK_SPACE_LIMIT_BYTES:-"1099511627776"}

# Display configuration summary
echo -e "\n${GREEN}Configuration Summary:${NC}"
echo "----------------------"
echo -e "DIG_USERNAME:           ${YELLOW}$DIG_USERNAME${NC}"
echo -e "DIG_PASSWORD:           ${YELLOW}$DIG_PASSWORD${NC}"
echo -e "TRUSTED_FULLNODE:       ${YELLOW}$TRUSTED_FULLNODE${NC}"
echo -e "PUBLIC_IP:              ${YELLOW}$PUBLIC_IP${NC}"
echo -e "MERCENARY_MODE:         ${YELLOW}$MERCENARY_MODE${NC}"
echo -e "DISK_SPACE_LIMIT_BYTES: ${YELLOW}$DISK_SPACE_LIMIT_BYTES${NC}"
echo "----------------------"

# Explain TRUSTED_FULLNODE and PUBLIC_IP
echo -e "\n${BLUE}Note:${NC}"
echo " - TRUSTED_FULLNODE is optional. It can be your own full node's public IP for better performance."
echo " - PUBLIC_IP should be set if your network setup requires an IP override."

# Ask if the user wants to include the Nginx reverse-proxy container
echo -e "\n${BLUE}Would you like to include the Nginx reverse-proxy container?${NC}"
read -p "(y/n): " -n 1 -r
echo    # Move to a new line

if [[ $REPLY =~ ^[Yy]$ ]]; then
    INCLUDE_NGINX="yes"
else
    INCLUDE_NGINX="no"
    echo -e "\n${YELLOW}Warning:${NC} You have chosen not to include the Nginx reverse-proxy container."
    echo -e "${YELLOW}Unless you plan on exposing port 80/443 in another way, your DIG Node's content server will be inaccessible to the browser.${NC}"
fi

# Open ports using firewalld
read -p "Do you want to configure firewalld to open necessary ports? (y/n): " -n 1 -r
echo    # Move to a new line
if [[ $REPLY =~ ^[Yy]$ ]]; then
    open_ports
else
    echo -e "${YELLOW}Skipping firewalld port configuration.${NC}"
fi

# Create docker-compose.yml
DOCKER_COMPOSE_FILE=./docker-compose.yml
echo -e "\n${BLUE}Creating docker-compose.yml at $DOCKER_COMPOSE_FILE...${NC}"

cat <<EOF > $DOCKER_COMPOSE_FILE
version: '3.8'

services:
  propagation-server:
    image: dignetwork/dig-propagation-server:latest-alpha
    ports:
      - "4159:4159"
    volumes:
      - $USER_HOME/.dig/remote:/.dig
    environment:
      - DIG_USERNAME=$DIG_USERNAME
      - DIG_PASSWORD=$DIG_PASSWORD
      - DIG_FOLDER_PATH=/.dig
      - PORT=4159
      - REMOTE_NODE=1
      - TRUSTED_FULLNODE=$TRUSTED_FULLNODE
    restart: always
    networks:
      - dig_network

  content-server:
    image: dignetwork/dig-content-server:latest-alpha
    ports:
      - "4161:4161"
    volumes:
      - $USER_HOME/.dig/remote:/.dig
    environment:
      - DIG_FOLDER_PATH=/.dig
      - PORT=4161
      - REMOTE_NODE=1
      - TRUSTED_FULLNODE=$TRUSTED_FULLNODE
    restart: always
    networks:
      - dig_network

  incentive-server:
    image: dignetwork/dig-incentive-server:latest-alpha
    ports:
      - "4160:4160"
    volumes:
      - $USER_HOME/.dig/remote:/.dig
    environment:
      - DIG_USERNAME=$DIG_USERNAME
      - DIG_PASSWORD=$DIG_PASSWORD
      - DIG_FOLDER_PATH=/.dig
      - PORT=4160
      - REMOTE_NODE=1
      - TRUSTED_FULLNODE=$TRUSTED_FULLNODE
      - PUBLIC_IP=$PUBLIC_IP
      - DISK_SPACE_LIMIT_BYTES=$DISK_SPACE_LIMIT_BYTES
      - MERCENARY_MODE=$MERCENARY_MODE
    restart: always
    networks:
      - dig_network
EOF

# Include Nginx reverse-proxy if selected
if [[ $INCLUDE_NGINX == "yes" ]]; then
    cat <<EOF >> $DOCKER_COMPOSE_FILE

  reverse-proxy:
    image: nginx:latest
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - $USER_HOME/.dig/remote/.nginx/conf.d:/etc/nginx/conf.d
      - $USER_HOME/.dig/remote/.nginx/certs:/etc/nginx/certs
    depends_on:
      - content-server
    networks:
      - dig_network
    restart: always

networks:
  dig_network:
    driver: bridge
EOF
else
    # Close docker-compose.yml without reverse-proxy
    cat <<EOF >> $DOCKER_COMPOSE_FILE

networks:
  dig_network:
    driver: bridge
EOF
fi

echo -e "${GREEN}docker-compose.yml created successfully.${NC}"

# Nginx setup if included
if [[ $INCLUDE_NGINX == "yes" ]]; then
    echo -e "\n${BLUE}Setting up Nginx reverse-proxy...${NC}"

    # Nginx directories
    NGINX_CONF_DIR="$USER_HOME/.dig/remote/.nginx/conf.d"
    NGINX_CERTS_DIR="$USER_HOME/.dig/remote/.nginx/certs"

    # Create directories
    mkdir -p "$NGINX_CONF_DIR"
    mkdir -p "$NGINX_CERTS_DIR"

    # Generate TLS client certificate and key
    echo -e "\n${BLUE}Generating TLS client certificate and key for Nginx...${NC}"

    # Paths to the CA certificate and key
    CA_CERT="./ssl/ca/chia_ca.crt"
    CA_KEY="./ssl/ca/chia_ca.key"

    # Check if CA certificate and key exist
    if [ ! -f "$CA_CERT" ] || [ ! -f "$CA_KEY" ]; then
        echo -e "${RED}Error: CA certificate or key not found in ./ssl/ca/${NC}"
        echo "Please ensure chia_ca.crt and chia_ca.key are present in ./ssl/ca/ directory."
        exit 1
    fi

    # Generate client key and certificate
    openssl genrsa -out "$NGINX_CERTS_DIR/client.key" 2048
    openssl req -new -key "$NGINX_CERTS_DIR/client.key" -subj "/CN=dig-nginx-client" -out "$NGINX_CERTS_DIR/client.csr"
    openssl x509 -req -in "$NGINX_CERTS_DIR/client.csr" -CA "$CA_CERT" -CAkey "$CA_KEY" \
    -CAcreateserial -out "$NGINX_CERTS_DIR/client.crt" -days 365 -sha256

    # Clean up CSR
    rm "$NGINX_CERTS_DIR/client.csr"
    cp "$CA_CERT" "$NGINX_CERTS_DIR/chia_ca.crt"

    echo -e "${GREEN}TLS client certificate and key generated.${NC}"

    # Prompt for hostname
    echo -e "\n${BLUE}Would you like to set a hostname for your server?${NC}"
    read -p "(y/n): " -n 1 -r
    echo    # Move to a new line

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        read -p "Please enter your hostname (e.g., example.com): " HOSTNAME
        USE_HOSTNAME="yes"
    else
        USE_HOSTNAME="no"
    fi

    # Generate Nginx configuration
    if [[ $USE_HOSTNAME == "yes" ]]; then
        SERVER_NAME="$HOSTNAME"
        LISTEN_DIRECTIVE="listen 80;"
    else
        SERVER_NAME="_"
        LISTEN_DIRECTIVE="listen 80 default_server;"
    fi

    cat <<EOF > "$NGINX_CONF_DIR/default.conf"
server {
    $LISTEN_DIRECTIVE
    server_name $SERVER_NAME;

    location / {
        proxy_pass http://content-server:4161;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_ssl_certificate /etc/nginx/certs/client.crt;
        proxy_ssl_certificate_key /etc/nginx/certs/client.key;
        proxy_ssl_trusted_certificate /etc/nginx/certs/chia_ca.crt;
        proxy_ssl_verify off;
    }
}
EOF

    echo -e "${GREEN}Nginx configuration has been set up at $NGINX_CONF_DIR/default.conf${NC}"

    if [[ $USE_HOSTNAME == "yes" ]]; then
        # Ask the user if they would like to set up Let's Encrypt
        echo -e "\n${BLUE}Would you like to set up Let's Encrypt SSL certificates for your hostname?${NC}"
        read -p "(y/n): " -n 1 -r
        echo    # Move to a new line

        if [[ $REPLY =~ ^[Yy]$ ]]; then
            SETUP_LETSENCRYPT="yes"

            while true; do
                # Provide requirements and ask for confirmation
                echo -e "\n${YELLOW}To successfully obtain Let's Encrypt SSL certificates, please ensure the following:${NC}"
                echo "1. Your domain name ($HOSTNAME) must be correctly configured to point to your server's public IP address."
                echo "2. Ports 80 and 443 must be open and accessible from the internet."
                echo "3. No other service is running on port 80 (e.g., Apache, another Nginx instance)."
                echo -e "\nPlease make sure these requirements are met before proceeding."

                read -p "Have you completed these steps? (y/n): " -n 1 -r
                echo    # Move to a new line

                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    echo -e "${RED}Please complete the required steps before proceeding.${NC}"
                    read -p "Would you like to skip Let's Encrypt setup? (y/n): " -n 1 -r
                    echo    # Move to a new line
                    if [[ $REPLY =~ ^[Yy]$ ]]; then
                        SETUP_LETSENCRYPT="no"
                        break
                    else
                        continue
                    fi
                fi

                # Prompt for email address for Let's Encrypt
                read -p "Please enter your email address for Let's Encrypt notifications: " LETSENCRYPT_EMAIL

                # Stop Nginx container before running certbot
                echo -e "\n${BLUE}Stopping Nginx container to set up Let's Encrypt...${NC}"
                docker-compose stop reverse-proxy

                # Obtain SSL certificate using certbot
                echo -e "${BLUE}Obtaining SSL certificate for $HOSTNAME...${NC}"
                if certbot certonly --standalone -d "$HOSTNAME" --non-interactive --agree-tos --email "$LETSENCRYPT_EMAIL"; then
                    echo -e "${GREEN}SSL certificate obtained successfully.${NC}"
                    break
                else
                    echo -e "${RED}Failed to obtain SSL certificate. Please check the requirements and try again.${NC}"
                    read -p "Would you like to try setting up Let's Encrypt again? (y/n): " -n 1 -r
                    echo    # Move to a new line
                    if [[ $REPLY =~ ^[Nn]$ ]]; then
                        SETUP_LETSENCRYPT="no"
                        break
                    else
                        continue
                    fi
                fi
            done

            if [[ $SETUP_LETSENCRYPT == "yes" ]]; then
                # Copy the certificates to the Nginx certs directory
                echo -e "${BLUE}Copying SSL certificates to Nginx certs directory...${NC}"
                cp /etc/letsencrypt/live/"$HOSTNAME"/fullchain.pem "$NGINX_CERTS_DIR/fullchain.pem"
                cp /etc/letsencrypt/live/"$HOSTNAME"/privkey.pem "$NGINX_CERTS_DIR/privkey.pem"

                # Modify Nginx configuration to use SSL
                echo -e "${BLUE}Updating Nginx configuration for SSL...${NC}"
                cat <<EOF > "$NGINX_CONF_DIR/default.conf"
server {
    listen 80;
    server_name $HOSTNAME;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $HOSTNAME;

    ssl_certificate /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;

    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    location / {
        proxy_pass http://content-server:4161;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_ssl_certificate /etc/nginx/certs/client.crt;
        proxy_ssl_certificate_key /etc/nginx/certs/client.key;
        proxy_ssl_trusted_certificate /etc/nginx/certs/chia_ca.crt;
        proxy_ssl_verify off;
    }
}
EOF

                echo -e "${GREEN}Nginx configuration updated for SSL.${NC}"

                # Start Nginx container
                echo -e "${BLUE}Starting Nginx container...${NC}"
                docker-compose up -d reverse-proxy

                # Ask if the user wants to set up auto-renewal
                echo -e "\n${BLUE}Would you like to set up automatic certificate renewal for Let's Encrypt?${NC}"
                read -p "(y/n): " -n 1 -r
                echo    # Move to a new line

                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    # Set up cron job for certificate renewal
                    echo -e "${BLUE}Setting up cron job for certificate renewal...${NC}"
                    (crontab -l 2>/dev/null; echo "0 0 * * * certbot renew --pre-hook 'docker-compose stop reverse-proxy' --post-hook 'docker-compose up -d reverse-proxy'") | crontab -

                    echo -e "${GREEN}Automatic certificate renewal has been set up.${NC}"
                else
                    echo -e "${YELLOW}Skipping automatic certificate renewal setup.${NC}"
                fi

                echo -e "${GREEN}Let's Encrypt SSL setup complete.${NC}"
            fi
        else
            SETUP_LETSENCRYPT="no"
        fi
    fi
fi

# Pull the latest Docker images
echo -e "\n${BLUE}Pulling the latest Docker images...${NC}"
docker-compose pull

# Create the systemd service file
echo -e "\n${BLUE}Creating systemd service file at $SERVICE_FILE_PATH...${NC}"
read -p "Do you want to create and enable the systemd service for DIG Node? (y/n): " -n 1 -r
echo    # Move to a new line
if [[ $REPLY =~ ^[Yy]$ ]]; then
    cat <<EOF > $SERVICE_FILE_PATH
[Unit]
Description=Dig Node Docker Compose
Documentation=https://dig.net
After=network.target docker.service
Requires=docker.service

[Service]
WorkingDirectory=$WORKING_DIR
ExecStart=$(command -v docker-compose) up
ExecStop=$(command -v docker-compose) down
Restart=always

User=$USER_NAME
Group=docker

# Time to wait before forcefully stopping the container
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

    # Reload systemd daemon
    echo -e "\n${BLUE}Reloading systemd daemon...${NC}"
    systemctl daemon-reload

    # Enable and start the service
    echo -e "\n${BLUE}Enabling and starting $SERVICE_NAME service...${NC}"
    systemctl enable "$SERVICE_NAME"
    systemctl start "$SERVICE_NAME"

    # Check the status of the service
    echo -e "\n${BLUE}Checking the status of the service...${NC}"
    systemctl --no-pager status "$SERVICE_NAME"

    echo -e "\n${GREEN}Service $SERVICE_NAME installed and activated successfully.${NC}"
else
    echo -e "${YELLOW}Skipping systemd service creation. You can manually start the DIG Node using 'docker-compose up'${NC}"
fi

echo -e "\n${YELLOW}Please log out and log back in for the Docker group changes to take effect.${NC}"
echo -e "${GREEN}Your DIG Node setup is complete!${NC}"

###############################################################################
#                                End of Script
###############################################################################
