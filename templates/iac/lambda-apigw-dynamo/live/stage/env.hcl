# live/stage/env.hcl

inputs = {
  env = "stage"

  lambda_memory  = 1024
  lambda_timeout = 60
  lambda_reserved_concurrency = -1

  dynamo_pitr = true
  secrets_recovery_days = 7
}
