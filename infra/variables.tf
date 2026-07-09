variable "resource_prefix" {
  description = "Prefix for all AWS resource names (e.g. your username or team alias)"
  type        = string
  default     = "loki"
}

variable "aws_region" {
  description = "AWS region to deploy in"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type (t3.xlarge is sufficient for ROS2 learning with Gazebo software rendering)"
  type        = string
  default     = "t3.xlarge"
}

variable "instance_name" {
  description = "Base name for the EC2 instance (will be prefixed with resource_prefix)"
  type        = string
  default     = "ros2-gazebo-dev"
}

variable "volume_size" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 50
}

variable "allowed_ssh_cidrs" {
  description = "CIDR blocks allowed to SSH into the instance"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
