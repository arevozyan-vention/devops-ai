data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_security_group" "instance" {
  name        = "${var.name_prefix}-asg"
  description = "Allow inbound from ALB on app port"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = var.app_port
    to_port         = var.app_port
    protocol        = "tcp"
    security_groups = [var.alb_security_group_id]
    description     = "From ALB"
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = var.common_tags
}

locals {
  user_data = base64encode(<<-USERDATA
    #!/bin/bash
    set -euxo pipefail
    dnf install -y amazon-cloudwatch-agent unzip awscli
    systemctl enable --now amazon-cloudwatch-agent

    install -d -m 755 /opt/${var.project_name}
    aws --region ${var.region} s3 cp \
      "s3://${var.artifact_bucket}/${var.project_name}/current.tar.gz" \
      /tmp/release.tar.gz
    tar -xzf /tmp/release.tar.gz -C /opt/${var.project_name}

    # TODO(devops-ai): generate the systemd unit from the overview's start
    # command and required env vars.
    cat > /etc/systemd/system/${var.project_name}.service <<UNIT
    [Unit]
    Description=${var.project_name}
    After=network.target

    [Service]
    Type=simple
    WorkingDirectory=/opt/${var.project_name}
    ExecStart=/opt/${var.project_name}/start.sh
    Restart=on-failure

    [Install]
    WantedBy=multi-user.target
    UNIT
    systemctl daemon-reload
    systemctl enable --now ${var.project_name}.service
  USERDATA
  )
}

resource "aws_launch_template" "this" {
  name_prefix   = "${var.name_prefix}-"
  image_id      = data.aws_ssm_parameter.al2023.value
  instance_type = var.instance_type
  user_data     = local.user_data

  iam_instance_profile {
    name = var.instance_profile_name
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.instance.id]
  }

  tag_specifications {
    resource_type = "instance"
    tags          = var.common_tags
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_autoscaling_group" "this" {
  name                = "${var.name_prefix}-asg"
  vpc_zone_identifier = var.subnet_ids

  min_size         = var.min_size
  desired_capacity = var.desired_size
  max_size         = var.max_size

  health_check_type         = "ELB"
  health_check_grace_period = 120

  target_group_arns = [var.alb_target_group_arn]

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  dynamic "tag" {
    for_each = var.common_tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle { create_before_destroy = true }
}
