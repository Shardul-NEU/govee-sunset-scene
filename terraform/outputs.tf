output "function_name" {
  value = aws_lambda_function.govee_sunset_scene.function_name
}

output "function_arn" {
  value = aws_lambda_function.govee_sunset_scene.arn
}

output "lambda_role_arn" {
  value = aws_iam_role.lambda.arn
}

output "scheduler_role_arn" {
  value = aws_iam_role.scheduler.arn
}
