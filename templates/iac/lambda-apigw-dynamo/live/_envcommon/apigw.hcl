# _envcommon/apigw.hcl — HTTP API in front of the Lambda.

terraform {
  source = "tfr:///terraform-aws-modules/apigateway-v2/aws?version=5.2.1"
}

dependency "lambda" {
  config_path = "../lambda"
  mock_outputs = {
    lambda_function_arn  = "arn:aws:lambda:us-east-1:000000000000:function:mock"
    lambda_function_name = "mock"
  }
}

inputs = {
  name          = ""  # filled per-env
  description   = "HTTP API for the application"
  protocol_type = "HTTP"

  cors_configuration = {
    allow_headers = ["content-type", "x-amz-date", "authorization", "x-api-key"]
    allow_methods = ["*"]
    allow_origins = ["*"]
  }

  create_domain_name = false  # external DNS / custom domain setup is operator's job

  routes = {
    "ANY /{proxy+}" = {
      integration = {
        uri                    = dependency.lambda.outputs.lambda_function_arn
        type                   = "AWS_PROXY"
        integration_method     = "POST"
        payload_format_version = "2.0"
      }
    }
  }
}
