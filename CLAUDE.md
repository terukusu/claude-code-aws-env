# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Terraform infrastructure project that provisions a secure Claude Code development environment on AWS EC2. The environment includes a fully configured Ubuntu instance with development tools, Japanese language support, and enhanced security features.

## Commands

### Terraform Operations
```bash
# Initialize Terraform (required before first use)
terraform init

# Preview infrastructure changes
terraform plan

# Deploy infrastructure
terraform apply

# Destroy infrastructure
terraform destroy
```

### Configuration Setup
Before deploying, ensure you have:
1. Created AWS key pair named `claude-dev-key` (or update in terraform.tfvars)
2. Copied `terraform.tfvars.sample` to `terraform.tfvars`
3. Updated `terraform.tfvars` with your GitHub username and email

### Connecting to EC2 Instance
After deployment, use the SSH command output by Terraform:
```bash
ssh -i ~/.ssh/claude-dev-key.pem -p 10022 ubuntu@<instance-ip>
```

## Architecture

### Infrastructure Components
- **EC2 Instance**: Ubuntu 22.04 LTS Minimal with encrypted root volume
- **Security Group**: Custom SSH port (10022) with minimal egress rules
- **Elastic IP**: Persistent public IP address
- **User Data Script**: Automated setup via cloud-init

### Security Design
- Custom SSH port (10022) instead of default 22
- UFW firewall with minimal allowed ports
- fail2ban for brute-force protection
- SSH key authentication only (password auth disabled)
- Encrypted EBS volumes

### Development Environment Setup
The user_data script automatically installs:
- **mise**: Version manager for Node.js and Python
- **Node.js**: Multiple versions via mise (configured in terraform.tfvars)
- **Python**: Multiple versions via mise
- **Claude Code**: Installed globally via npm
- **Japanese Support**: Full locale, timezone, and input method (uim-fep)
- **Git**: With convenient aliases and GitHub SSH setup script

## Important Files

- `main.tf`: Core infrastructure definition with user_data setup script
- `variables.tf`: Variable definitions with validation rules
- `terraform.tfvars`: Your environment-specific configuration (not in Git)
- `terraform.tfstate`: Current infrastructure state (sensitive - exclude from Git)

## Multiple Environment Support

To create multiple environments in the same AWS account:

1. **Set environment_name in terraform.tfvars**:
   ```hcl
   environment_name = "test"  # or "staging", "project-a", etc.
   ```

2. **Recommended: Use separate directories or Terraform workspaces**:
   ```bash
   # Option 1: Separate directories
   cp -r project-dir project-dir-test
   
   # Option 2: Terraform workspaces
   terraform workspace new test
   ```

3. **SSH keys are auto-generated** following SSH convention when `key_name` is empty. Algorithm configurable via `ssh_key_algorithm`.

## Key Considerations

1. **State Management**: terraform.tfstate contains sensitive information and should be excluded from version control. Consider using remote state storage for team environments.

2. **Security Group**: Currently allows SSH from 0.0.0.0/0 on custom port. For production, restrict to specific IP ranges.

3. **SSH Key**: The setup assumes `~/.ssh/{key_name}.pem` exists. If `key_name` is empty, it auto-generates following SSH convention: `id_{algorithm}_claude_{environment}_key` (e.g., `id_ed25519_claude_dev_key`).

4. **GitHub SSH**: After instance creation, run the generated `setup-github-ssh.sh` script on the instance to configure GitHub authentication.

5. **Japanese Environment**: The instance is configured for Japanese users with:
   - Locale: ja_JP.UTF-8
   - Timezone: Asia/Tokyo
   - Input method: uim-fep (activate with `jp` command, toggle with Ctrl+Space)