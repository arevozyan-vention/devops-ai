output "asg_name" {
  value = aws_autoscaling_group.this.name
}

output "launch_template_id" {
  value = aws_launch_template.this.id
}

output "instance_security_group_id" {
  value = aws_security_group.instance.id
}
