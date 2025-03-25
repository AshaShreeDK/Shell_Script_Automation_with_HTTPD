#!/bin/bash
SERVER_LINES=$(grep -E 'server[123]' /etc/hosts | awk '{print $1, $2}')
[ -z "$SERVER_LINES" ] && { echo "No child servers found in /etc/hosts."; exit 1; }

echo "Select authentication for 'automation' user:"
echo "1) Password Authentication"
echo "2) SSH Key-Based Authentication"
read -p "Choice: " AUTH_CHOICE

if [ "$AUTH_CHOICE" = "1" ]; then
  read -sp "Enter password for 'automation': " USER_PASS; echo ""
  USE_PASS=true
elif [ "$AUTH_CHOICE" = "2" ]; then
  USE_PASS=false
else
  echo "Invalid option"; exit 1
fi

read -p "Enter path to private key for root login (.pem): " KEY_PATH
[ ! -f "$KEY_PATH" ] && { echo "Private key not found at: $KEY_PATH"; exit 1; }

for SERVER_INFO in $SERVER_LINES; do
  IP=$(echo "$SERVER_INFO" | awk '{print $1}')
  SERVER=$(echo "$SERVER_INFO" | awk '{print $2}')

  echo "Configuring $SERVER ($IP)..."

  USER_EXISTS=$(ssh -o StrictHostKeyChecking=no -i "$KEY_PATH" ec2-user@"$IP" "id -u automation >/dev/null 2>&1 && echo 'exists'" 2>/dev/null)

  if [ "$USER_EXISTS" = "exists" ]; then
    echo "Automation user already exists on $SERVER ($IP)"
  else
    ssh -o StrictHostKeyChecking=no -i "$KEY_PATH" ec2-user@"$IP" "sudo useradd -m -d /home/automation automation" >/dev/null 2>&1
    echo "Automation user created on $SERVER ($IP)"
  fi

  ssh -o StrictHostKeyChecking=no -i "$KEY_PATH" ec2-user@"$IP" "
    sudo mkdir -p /home/automation/.ssh;
    sudo touch /home/automation/.ssh/authorized_keys;
    sudo chown -R automation:automation /home/automation/.ssh;
    sudo chmod 700 /home/automation/.ssh;
    sudo chmod 600 /home/automation/.ssh/authorized_keys;
    echo 'automation ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/automation;
    sudo chmod 0440 /etc/sudoers.d/automation
  " >/dev/null 2>&1

  if [ "$USE_PASS" = true ]; then
    ssh -o StrictHostKeyChecking=no -i "$KEY_PATH" ec2-user@"$IP" "
      echo 'automation:$USER_PASS' | sudo chpasswd;
      sudo sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config;
      sudo systemctl restart sshd
    " >/dev/null 2>&1
  else
    PUB_KEY=$(cat "$KEY_PATH".pub 2>/dev/null)
    [ -z "$PUB_KEY" ] && { echo "Failed to read public key from $KEY_PATH.pub"; exit 1; }
    ssh -o StrictHostKeyChecking=no -i "$KEY_PATH" ec2-user@"$IP" "
      echo '$PUB_KEY' | sudo tee /home/automation/.ssh/authorized_keys;
      sudo chmod 600 /home/automation/.ssh/authorized_keys
    " >/dev/null 2>&1
  fi

  ssh -o StrictHostKeyChecking=no -i "$KEY_PATH" ec2-user@"$IP" "
    if rpm -q httpd >/dev/null 2>&1; then
      echo 'Apache already installed on $SERVER ($IP)';
    else
      sudo yum -y install httpd && sudo systemctl enable httpd && sudo systemctl start httpd;
      echo 'Apache installed on $SERVER ($IP)';
    fi
  "

  echo "Configuration completed on $SERVER ($IP)"
done

echo "All servers are configured."

