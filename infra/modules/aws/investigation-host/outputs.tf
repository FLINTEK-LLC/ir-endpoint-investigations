output "instance_id" {
  description = "EC2 instance ID - used with `aws ssm start-session` to connect."
  value       = aws_instance.host.id
}

output "role_arn" {
  description = "IAM role ARN attached to this host."
  value       = aws_iam_role.host.arn
}
