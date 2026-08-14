#!/usr/bin/env bash
# Explicit ECS deploy for Tracking-Proxy (Tracking-ProxyCluster, us-west-2).
#
# Replaces the old ":latest + force-new-deployment" flow. Every deploy:
#   1. builds the image from the current commit, tagged with the git SHA
#   2. pushes that immutable tag to ECR (never :latest)
#   3. registers a new task-definition revision pinned to the pushed image digest
#   4. points the service at the new revision and waits for it to stabilize
#
# An ECR push alone can no longer change what runs in prod. The deployment
# circuit breaker (enabled 2026-08) rolls the service back automatically if
# the new revision fails to start; this script detects that and exits nonzero.
#
# Usage:
#   ./deploy.sh                 deploy the current HEAD
#   ./deploy.sh --dry-run       build + print the plan; makes no writes to AWS
#   ./deploy.sh --rollback [N]  repoint the service at task-def revision N
#                               (default: the revision before the current one)
#
# Requires: aws CLI v2, docker (buildx), jq, git.
set -euo pipefail

AWS_REGION="us-west-2"
ACCOUNT_ID="228071332415"
ECR_REPO="tracking-proxy"
ECS_CLUSTER="Tracking-ProxyCluster"
ECS_SERVICE="Tracking-Proxy"
PLATFORM="linux/amd64"

REGISTRY="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
AWS=(aws --region "$AWS_REGION")

die() { echo "ERROR: $*" >&2; exit 1; }
command -v jq >/dev/null || die "jq is required (brew install jq)"

cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

DRY_RUN=false
ROLLBACK=false
ROLLBACK_REV=""
case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=true ;;
  --rollback) ROLLBACK=true; ROLLBACK_REV="${2:-}" ;;
  *) die "unknown argument: $1 (use --dry-run or --rollback [N])" ;;
esac

current_taskdef_arn() {
  "${AWS[@]}" ecs describe-services --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" \
    --query 'services[0].taskDefinition' --output text
}

wait_and_verify() { # $1 = task-def arn the service should end up on
  echo "Waiting for the service to stabilize (this can take several minutes)..."
  "${AWS[@]}" ecs wait services-stable --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE"
  local final
  final=$(current_taskdef_arn)
  if [[ "$final" != "$1" ]]; then
    die "service stabilized on $final instead of $1 — the circuit breaker rolled the deploy back. Check stopped-task errors: aws ecs describe-tasks (stoppedReason)."
  fi
  echo "Service is stable on $final"
}

CURRENT_ARN=$(current_taskdef_arn)
FAMILY="${CURRENT_ARN##*/}"; FAMILY="${FAMILY%%:*}"
CURRENT_REV="${CURRENT_ARN##*:}"

if $ROLLBACK; then
  TARGET_REV="${ROLLBACK_REV:-$((CURRENT_REV - 1))}"
  [[ "$TARGET_REV" -ge 1 ]] || die "no revision to roll back to (service is on revision $CURRENT_REV)"
  STATUS=$("${AWS[@]}" ecs describe-task-definition --task-definition "$FAMILY:$TARGET_REV" \
    --query 'taskDefinition.status' --output text) || die "revision $FAMILY:$TARGET_REV not found"
  [[ "$STATUS" == "ACTIVE" ]] || die "revision $FAMILY:$TARGET_REV is $STATUS; deregistered revisions cannot be deployed"
  echo "Rolling back $ECS_SERVICE: revision $CURRENT_REV -> $TARGET_REV"
  "${AWS[@]}" ecs update-service --cluster "$ECS_CLUSTER" --service "$ECS_SERVICE" \
    --task-definition "$FAMILY:$TARGET_REV" --query 'service.taskDefinition' --output text
  wait_and_verify "$(echo "$CURRENT_ARN" | sed "s/:$CURRENT_REV\$/:$TARGET_REV/")"
  exit 0
fi

# --- deploy ---
[[ -z "$(git status --porcelain)" ]] || die "working tree is dirty; commit or stash first so the image tag matches a real commit"
GIT_SHA=$(git rev-parse --short=12 HEAD)
IMAGE_TAG="$GIT_SHA"
IMAGE_URI="$REGISTRY/$ECR_REPO:$IMAGE_TAG"

echo "Deploying $ECS_CLUSTER/$ECS_SERVICE from commit $GIT_SHA"
echo "Current task definition: $FAMILY:$CURRENT_REV"

EXISTING_DIGEST=$("${AWS[@]}" ecr describe-images --repository-name "$ECR_REPO" \
  --image-ids imageTag="$IMAGE_TAG" --query 'imageDetails[0].imageDigest' --output text 2>/dev/null || true)

if [[ -n "$EXISTING_DIGEST" && "$EXISTING_DIGEST" != "None" ]]; then
  echo "Tag $IMAGE_TAG already exists in ECR ($EXISTING_DIGEST) — reusing it, skipping build & push."
  DIGEST="$EXISTING_DIGEST"
else
  echo "Building $IMAGE_URI for $PLATFORM..."
  docker buildx build --load --platform "$PLATFORM" -t "$IMAGE_URI" .
  if $DRY_RUN; then
    echo
    echo "[dry-run] Would push $IMAGE_URI"
    echo "[dry-run] Would register $FAMILY revision $((CURRENT_REV + 1)) with the image pinned to the pushed digest (replacing $(
      "${AWS[@]}" ecs describe-task-definition --task-definition "$CURRENT_ARN" \
        --query 'taskDefinition.containerDefinitions[0].image' --output text))"
    echo "[dry-run] Would run: aws ecs update-service --cluster $ECS_CLUSTER --service $ECS_SERVICE --task-definition $FAMILY:<new-rev>"
    echo "[dry-run] Would wait for services-stable and verify the revision stuck"
    exit 0
  fi
  echo "Logging in to ECR..."
  "${AWS[@]}" ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"
  echo "Pushing $IMAGE_URI..."
  docker push "$IMAGE_URI"
  DIGEST=$("${AWS[@]}" ecr describe-images --repository-name "$ECR_REPO" \
    --image-ids imageTag="$IMAGE_TAG" --query 'imageDetails[0].imageDigest' --output text)
fi

if $DRY_RUN; then
  echo "[dry-run] Would pin $FAMILY to $REGISTRY/$ECR_REPO@$DIGEST and update the service."
  exit 0
fi

PINNED_IMAGE="$REGISTRY/$ECR_REPO@$DIGEST"
echo "Registering new task-definition revision pinned to $PINNED_IMAGE"
TASKDEF_JSON=$("${AWS[@]}" ecs describe-task-definition --task-definition "$CURRENT_ARN" --query 'taskDefinition')
[[ $(jq '.containerDefinitions | length' <<<"$TASKDEF_JSON") == 1 ]] || die "expected exactly one container in $FAMILY; update this script before deploying"
NEW_TASKDEF=$(jq --arg img "$PINNED_IMAGE" '
  del(.taskDefinitionArn, .revision, .status, .requiresAttributes,
      .compatibilities, .registeredAt, .registeredBy, .deregisteredAt)
  | .containerDefinitions[0].image = $img' <<<"$TASKDEF_JSON")
NEW_REV=$("${AWS[@]}" ecs register-task-definition --cli-input-json "$NEW_TASKDEF" \
  --query 'taskDefinition.revision' --output text)
echo "Registered $FAMILY:$NEW_REV"

echo "Updating service..."
"${AWS[@]}" ecs update-service --cluster "$ECS_CLUSTER" --service "$ECS_SERVICE" \
  --task-definition "$FAMILY:$NEW_REV" --query 'service.taskDefinition' --output text
wait_and_verify "$(echo "$CURRENT_ARN" | sed "s/:$CURRENT_REV\$/:$NEW_REV/")"

echo
echo "Deployed commit $GIT_SHA as $FAMILY:$NEW_REV ($PINNED_IMAGE)"
echo "Roll back with: ./$(basename "$0") --rollback $CURRENT_REV"
