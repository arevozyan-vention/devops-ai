# environments/dev/env.hcl

inputs = {
  env = "dev"

  lambda_memory  = 512
  lambda_timeout = 30
  lambda_reserved_concurrency = -1  # -1 means unreserved

  dynamo_pitr = false
  secrets_recovery_days = 0
}
