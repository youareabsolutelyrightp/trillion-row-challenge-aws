#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"
AWS_PROFILE="${AWS_PROFILE:?AWS_PROFILE is required}"
AWS_REGION="${AWS_REGION:-us-east-1}"
IMAGE_TAG="${IMAGE_TAG:?IMAGE_TAG is required}"
IAC_CMD="${IAC_CMD:-tofu}"

ecr_url="$("$IAC_CMD" -chdir="$ROOT_DIR" output -raw ecr_repository_url)"
registry="${ecr_url%/*}"

aws --profile "$AWS_PROFILE" --region "$AWS_REGION" ecr get-login-password \
  | docker login --username AWS --password-stdin "$registry"

docker buildx build \
  --platform linux/arm64 \
  -t "$ecr_url:$IMAGE_TAG" \
  --push \
  "$PROJECT_ROOT/implementations/batch-rust"

echo "Pushed $ecr_url:$IMAGE_TAG"
