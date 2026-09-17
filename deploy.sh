#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SERVICE_NAME="${SERVICE_NAME:-copilot-review-poller}"
AWS_PROFILE="${AWS_PROFILE:-default}"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"
TARGET_REPOSITORY="${TARGET_REPOSITORY:?TARGET_REPOSITORY is required}"
GH_TOKEN="${GH_TOKEN:?GH_TOKEN is required}"

export AWS_PAGER=""

aws_cli=(aws --profile "$AWS_PROFILE" --region "$AWS_REGION")
role_name="${SERVICE_NAME}-role"
log_group_name="/aws/lambda/${SERVICE_NAME}"
policy_name="AWSLambdaBasicExecutionRole"
permission_statement_id="EventBridgeInvokeCopilotReviewPoller"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT

command -v aws >/dev/null
command -v docker >/dev/null

account_id="$("${aws_cli[@]}" sts get-caller-identity --query Account --output text)"
registry="${account_id}.dkr.ecr.${AWS_REGION}.amazonaws.com"
image_uri="${registry}/${SERVICE_NAME}:latest"
role_arn="arn:aws:iam::${account_id}:role/service-role/${role_name}"

if ! "${aws_cli[@]}" ecr describe-repositories \
  --repository-names "$SERVICE_NAME" >/dev/null 2>&1; then
  "${aws_cli[@]}" ecr create-repository \
    --repository-name "$SERVICE_NAME" \
    --image-tag-mutability MUTABLE \
    --image-scanning-configuration scanOnPush=false \
    --encryption-configuration encryptionType=AES256 >/dev/null
fi

"${aws_cli[@]}" ecr get-login-password \
  | docker login --username AWS --password-stdin "$registry"
docker build --platform linux/arm64 --tag "$image_uri" .
docker push "$image_uri"

cat >"$temporary_directory/trust-policy.json" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"Service": "lambda.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON

cat >"$temporary_directory/log-policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:${AWS_REGION}:${account_id}:log-group:${log_group_name}:*"
    }
  ]
}
JSON

if ! "${aws_cli[@]}" iam get-role --role-name "$role_name" >/dev/null 2>&1; then
  "${aws_cli[@]}" iam create-role \
    --path /service-role/ \
    --role-name "$role_name" \
    --assume-role-policy-document "file://$temporary_directory/trust-policy.json" \
    >/dev/null
fi

"${aws_cli[@]}" iam put-role-policy \
  --role-name "$role_name" \
  --policy-name "$policy_name" \
  --policy-document "file://$temporary_directory/log-policy.json"
sleep 5

log_group_count="$("${aws_cli[@]}" logs describe-log-groups \
  --log-group-name-prefix "$log_group_name" \
  --query "length(logGroups[?logGroupName=='${log_group_name}'])" \
  --output text)"
if [ "$log_group_count" = "0" ]; then
  "${aws_cli[@]}" logs create-log-group \
    --log-group-name "$log_group_name"
fi

lambda_environment="Variables={GH_TOKEN=${GH_TOKEN},TARGET_REPOSITORY=${TARGET_REPOSITORY}}"
function_arn="$("${aws_cli[@]}" lambda get-function \
  --function-name "$SERVICE_NAME" \
  --query 'Configuration.FunctionArn' \
  --output text 2>/dev/null || true)"

if [ -z "$function_arn" ] || [ "$function_arn" = "None" ]; then
  "${aws_cli[@]}" lambda create-function \
    --function-name "$SERVICE_NAME" \
    --package-type Image \
    --code "ImageUri=${image_uri}" \
    --role "$role_arn" \
    --architectures arm64 \
    --memory-size 128 \
    --timeout 30 \
    --environment "$lambda_environment" \
    >/dev/null
  "${aws_cli[@]}" lambda wait function-active \
    --function-name "$SERVICE_NAME"
else
  "${aws_cli[@]}" lambda update-function-code \
    --function-name "$SERVICE_NAME" \
    --image-uri "$image_uri" \
    --publish \
    >/dev/null
  "${aws_cli[@]}" lambda wait function-updated \
    --function-name "$SERVICE_NAME"
  "${aws_cli[@]}" lambda update-function-configuration \
    --function-name "$SERVICE_NAME" \
    --memory-size 128 \
    --timeout 30 \
    --environment "$lambda_environment" \
    >/dev/null
  "${aws_cli[@]}" lambda wait function-updated \
    --function-name "$SERVICE_NAME"
fi

function_arn="$("${aws_cli[@]}" lambda get-function \
  --function-name "$SERVICE_NAME" \
  --query 'Configuration.FunctionArn' \
  --output text)"
rule_arn="$("${aws_cli[@]}" events put-rule \
  --name "$SERVICE_NAME" \
  --schedule-expression 'rate(5 minutes)' \
  --state ENABLED \
  --description 'Request GitHub Copilot reviews for open pull requests' \
  --query RuleArn \
  --output text)"

"${aws_cli[@]}" events put-targets \
  --rule "$SERVICE_NAME" \
  --targets "Id=${SERVICE_NAME},Arn=${function_arn}" \
  >/dev/null

current_policy="$("${aws_cli[@]}" lambda get-policy \
  --function-name "$SERVICE_NAME" \
  --query Policy \
  --output text 2>/dev/null || true)"
if ! printf '%s' "$current_policy" | rg -q "$permission_statement_id"; then
  "${aws_cli[@]}" lambda add-permission \
    --function-name "$SERVICE_NAME" \
    --statement-id "$permission_statement_id" \
    --action lambda:InvokeFunction \
    --principal events.amazonaws.com \
    --source-arn "$rule_arn" \
    >/dev/null
fi

printf 'Deployed %s to %s using AWS profile %s.\n' \
  "$SERVICE_NAME" "$AWS_REGION" "$AWS_PROFILE"
