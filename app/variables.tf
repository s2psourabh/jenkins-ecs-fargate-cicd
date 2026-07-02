variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "environment" {
  description = "Target environment"
  type        = string

  validation {
    condition     = contains(["dev", "qa", "prod"], var.environment)
    error_message = "Environment must be dev, qa, or prod."
  }
}

variable "app_name" {
  description = "Application name"
  type        = string
}

variable "image_tag" {
  description = "Docker image tag to deploy"
  type        = string
}

variable "container_port" {
  description = "Container port"
  type        = number
  default     = 80
}

variable "task_cpu" {
  description = "Fargate task CPU"
  type        = string
  default     = "256"
}

variable "task_memory" {
  description = "Fargate task memory"
  type        = string
  default     = "512"
}

variable "desired_count" {
  description = "Number of running containers"
  type        = number
  default     = 1
}