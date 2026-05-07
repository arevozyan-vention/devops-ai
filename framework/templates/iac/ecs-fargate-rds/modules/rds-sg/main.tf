resource "aws_security_group" "this" {
  name        = var.name
  description = "Database ingress on port ${var.port}"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = var.port
    to_port     = var.port
    protocol    = "tcp"
    cidr_blocks = var.ingress_cidr_blocks
    description = "Allow database traffic from approved sources"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.common_tags
}
