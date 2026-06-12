output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.ros2_dev.id
}

output "public_ip" {
  description = "Public IP address of the instance"
  value       = aws_instance.ros2_dev.public_ip
}

output "public_dns" {
  description = "Public DNS name of the instance"
  value       = aws_instance.ros2_dev.public_dns
}

output "ami_id" {
  description = "AMI used for the instance"
  value       = data.aws_ami.ubuntu.id
}

output "ssh_command" {
  description = "SSH command to connect to the instance"
  value       = "ssh -i ${local_file.ssh_private_key.filename} ubuntu@${aws_instance.ros2_dev.public_ip}"
}

output "ssh_private_key_path" {
  description = "Path to the generated SSH private key"
  value       = local_file.ssh_private_key.filename
}

output "nice_dcv_url" {
  description = "NICE DCV remote desktop URL"
  value       = "https://${aws_instance.ros2_dev.public_ip}:8443"
}

output "cursor_remote_ssh_host" {
  description = "Add this as a Host entry in ~/.ssh/config for Cursor Remote-SSH"
  value       = "ubuntu@${aws_instance.ros2_dev.public_ip}"
}
