# live/prod/env.hcl

inputs = {
  env = "prod"

  lambda_memory  = 2048
  lambda_timeout = 60
  lambda_reserved_concurrency = 50

  dynamo_pitr = true
  secrets_recovery_days = 14
}
