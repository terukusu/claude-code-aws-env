variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "ap-northeast-1"
}

variable "instance_type" {
  description = "EC2 instance type for development environment"
  type        = string
  default     = "t3.medium"
  validation {
    condition = contains([
      "t3.small", "t3.medium", "t3.large", "t3.xlarge",
      "t3.2xlarge", "c5.large", "c5.xlarge", "m5.large", "m5.xlarge"
    ], var.instance_type)
    error_message = "Instance type must be a valid EC2 instance type."
  }
}

variable "key_name" {
  description = "Name of the AWS key pair for SSH access. Leave empty to auto-generate from environment_name"
  type        = string
  default     = ""
}

variable "ssh_port" {
  description = "Custom SSH port (default 22 is not recommended for security)"
  type        = number
  default     = 10022
  validation {
    condition     = var.ssh_port >= 1024 && var.ssh_port <= 65535
    error_message = "SSH port must be between 1024 and 65535."
  }
}

variable "enable_fail2ban" {
  description = "Enable fail2ban for additional security"
  type        = bool
  default     = true
}

variable "github_username" {
  description = "GitHub username for Git configuration"
  type        = string
  default     = ""
}

variable "github_email" {
  description = "GitHub email for Git configuration"
  type        = string
  default     = ""
}

variable "node_versions" {
  description = "List of Node.js versions to install (1-10 versions allowed)"
  type        = list(string)
  default     = ["latest"]
  validation {
    condition     = length(var.node_versions) >= 1 && length(var.node_versions) <= 10
    error_message = "Between 1 and 10 Node.js versions can be specified."
  }
  validation {
    condition = alltrue([
      for version in var.node_versions : 
      version == "latest" || can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", version))
    ])
    error_message = "Node.js versions must be 'latest' or in format 'x.y.z' (e.g., '20.16.0')."
  }
}

variable "python_versions" {
  description = "List of Python versions to install (1-10 versions allowed)"
  type        = list(string)
  default     = ["latest"]
  validation {
    condition     = length(var.python_versions) >= 1 && length(var.python_versions) <= 10
    error_message = "Between 1 and 10 Python versions can be specified."
  }
  validation {
    condition = alltrue([
      for version in var.python_versions : 
      version == "latest" || can(regex("^[0-9]+\\.[0-9]+(?:\\.[0-9]+)?$", version))
    ])
    error_message = "Python versions must be 'latest' or in format 'x.y' or 'x.y.z' (e.g., '3.11' or '3.11.7')."
  }
}

variable "default_node_version" {
  description = "Default Node.js version (must be one of the node_versions)"
  type        = string
  default     = "latest"
}

variable "default_python_version" {
  description = "Default Python version (must be one of the python_versions)"
  type        = string
  default     = "latest"
}

variable "environment_name" {
  description = "Name to identify this environment (e.g., 'dev', 'test', 'project-a')"
  type        = string
  default     = "dev"
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.environment_name))
    error_message = "Environment name must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "ssh_key_algorithm" {
  description = "SSH key algorithm for auto-generated key names"
  type        = string
  default     = "ed25519"
  validation {
    condition     = contains(["rsa", "ed25519", "ecdsa"], var.ssh_key_algorithm)
    error_message = "SSH key algorithm must be one of: rsa, ed25519, ecdsa."
  }
}