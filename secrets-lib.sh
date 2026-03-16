#!/bin/bash
# secrets.sh — Source this file in any script to load secrets from AWS Secrets Manager
#
# Usage:
#   source "$(dirname "$0")/lib/secrets.sh"
#   API_KEY=$(get_secret "myproject/my-api-key")

get_secret() {
    local name="$1"
    local region="${AWS_REGION:-us-east-1}"
    aws secretsmanager get-secret-value \
        --secret-id "$name" \
        --region "$region" \
        --query 'SecretString' \
        --output text 2>/dev/null
}

require_secret() {
    local name="$1"
    local val
    val=$(get_secret "$name")
    if [ -z "$val" ]; then
        echo "FATAL: Required secret '$name' not found in AWS Secrets Manager." >&2
        echo "Run: secret-store create '$name'" >&2
        exit 1
    fi
    echo "$val"
}
