# _envcommon/ecr.hcl — defaults for the ECR repository component.

terraform {
  source = "tfr:///terraform-aws-modules/ecr/aws?version=2.3.1"
}

inputs = {
  repository_image_tag_mutability     = "MUTABLE"
  repository_image_scan_on_push       = true
  repository_encryption_type          = "AES256"
  repository_force_delete             = false
  create_lifecycle_policy             = true

  repository_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 30 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 30
        }
        action = { type = "expire" }
      }
    ]
  })
}
