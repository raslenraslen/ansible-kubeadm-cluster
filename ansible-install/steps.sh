#!/bin/bash
# Installs Ansible on the control node (Ubuntu) and gives the current user passwordless sudo.

# Add the official Ansible PPA
sudo apt-add-repository ppa:ansible/ansible -y

# Refresh the package index
sudo apt update

# Install Ansible (includes the community.general collection)
sudo apt install ansible -y
echo "$USER ALL=(ALL) NOPASSWD: ALL" | sudo EDITOR='tee -a' visudo

# Check the installation
ansible --version
