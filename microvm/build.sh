#!/usr/bin/env bash
# Package the operative MicroVM image context and create/update the image in Lambda.
#
#   microvm/build.sh            # package + upload + create or update image
#   microvm/build.sh --local    # only rebuild the local finch image for testing
#   microvm/build.sh --bump [--local]  # pin the newest KAS bundle first
#
# Needs: AWS_PROFILE=<your profile>, a local Kiro CLI install (for the
# KAS bundle), finch (for --local). Idempotent: re-running updates the image.
set -euo pipefail
cd "$(dirname "$0")"

REGION="${AWS_REGION:-eu-central-1}"
# --local needs no AWS at all; everything else does
if [[ "${1:-}" != "--local" ]]; then
  ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
else
  ACCOUNT="local"
fi
BUCKET="${MICROVM_BUCKET:-wraith-microvm-${ACCOUNT}-${REGION}}"
IMAGE_NAME="${MICROVM_IMAGE_NAME:-wraith-studio}"
IMAGE_ARN="arn:aws:lambda:${REGION}:${ACCOUNT}:microvm-image:${IMAGE_NAME}"
BUILD_ROLE="${MICROVM_BUILD_ROLE:-WraithMicrovmBuildRole}"
BASE_IMAGE="arn:aws:lambda:${REGION}:aws:microvm-image:al2023-1"

KIRO_DIR="$HOME/Library/Application Support/kiro-cli"
PIN_FILE="$(dirname "$0")/KAS_VERSION"
LATEST="$(cd "$KIRO_DIR" && ls -d kas/2.*/ | sort -V | tail -1 | sed 's#kas/##; s#/##')"

# The KAS bundle is pinned in microvm/KAS_VERSION so an image never ships
# "whatever Kiro CLI last auto-updated". `--bump` moves the pin to the newest
# bundle on this machine (then re-run the spikes and the e2e before publishing).
if [[ "${1:-}" == "--bump" ]]; then
  echo "$LATEST" > "$PIN_FILE"
  echo "▸ pinned KAS $LATEST in $PIN_FILE"
  shift
fi
KAS_VERSION="$(cat "$PIN_FILE")"
KAS_SRC="$KIRO_DIR/kas/$KAS_VERSION/node_modules"
if [[ ! -d "$KAS_SRC" ]]; then
  echo "KAS bundle $KAS_VERSION is not on this machine (newest here: $LATEST)." >&2
  echo "Run \`kiro-cli\` once to fetch it, or \`$0 --bump\` to pin the newest." >&2
  exit 1
fi
[[ "$KAS_VERSION" != "$LATEST" ]] && echo "▸ note: newer KAS on this machine ($LATEST); pin is $KAS_VERSION"

echo "▸ KAS bundle $KAS_VERSION"
mkdir -p build/kas
rsync -a --delete \
  --exclude '_preserved-licenses' \
  --exclude '@img/sharp-darwin-arm64' --exclude '@img/sharp-libvips-darwin-arm64' \
  --exclude 'onnxruntime-node/bin/napi-v3/darwin' \
  "$KAS_SRC" build/kas/
echo "$KAS_VERSION" > build/kas/VERSION
rsync -a --delete shim/ build/shim/
cp Dockerfile build/

if [[ "${1:-}" == "--local" ]]; then
  finch build --platform linux/arm64 -t wraith-studio:dev build
  exit 0
fi

echo "▸ zip"
rm -f build/context.zip
(cd build && zip -qr -X context.zip Dockerfile shim kas)
SHA="$(shasum -a 256 build/context.zip | cut -c1-12)"
KEY="operative/${KAS_VERSION}-${SHA}.zip"
ls -lh build/context.zip

echo "▸ s3://$BUCKET/$KEY"
aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null || {
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
  aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
}
aws s3 cp --only-show-errors build/context.zip "s3://$BUCKET/$KEY"

echo "▸ build role $BUILD_ROLE"
ROLE_ARN="$(aws iam get-role --role-name "$BUILD_ROLE" --query Role.Arn --output text 2>/dev/null || true)"
if [[ -z "$ROLE_ARN" ]]; then
  ROLE_ARN="$(aws iam create-role --role-name "$BUILD_ROLE" --query Role.Arn --output text \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"]}]}')"
  aws iam put-role-policy --role-name "$BUILD_ROLE" --policy-name build --policy-document "{
    \"Version\":\"2012-10-17\",\"Statement\":[
      {\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\"],\"Resource\":\"arn:aws:s3:::${BUCKET}/*\"},
      {\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogGroup\",\"logs:CreateLogStream\",\"logs:PutLogEvents\"],\"Resource\":\"arn:aws:logs:*:*:*\"}]}"
  sleep 10 # IAM propagation
fi

echo "▸ journal bucket + execution role"
JOURNAL_BUCKET="${MICROVM_JOURNAL_BUCKET:-wraith-journal-${ACCOUNT}-${REGION}}"
EXEC_ROLE="${MICROVM_EXEC_ROLE:-WraithMicrovmExecutionRole}"
aws s3api head-bucket --bucket "$JOURNAL_BUCKET" 2>/dev/null || {
  aws s3api create-bucket --bucket "$JOURNAL_BUCKET" --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
  aws s3api put-public-access-block --bucket "$JOURNAL_BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-versioning --bucket "$JOURNAL_BUCKET" --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption --bucket "$JOURNAL_BUCKET" --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
}
EXEC_ROLE_ARN="$(aws iam get-role --role-name "$EXEC_ROLE" --query Role.Arn --output text 2>/dev/null || true)"
if [[ -z "$EXEC_ROLE_ARN" ]]; then
  EXEC_ROLE_ARN="$(aws iam create-role --role-name "$EXEC_ROLE" --query Role.Arn --output text \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"]}]}')"
  aws iam put-role-policy --role-name "$EXEC_ROLE" --policy-name journal --policy-document "{
    \"Version\":\"2012-10-17\",\"Statement\":[
      {\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:PutObject\"],\"Resource\":\"arn:aws:s3:::${JOURNAL_BUCKET}/companies/*\"},
      {\"Effect\":\"Allow\",\"Action\":\"s3:ListBucket\",\"Resource\":\"arn:aws:s3:::${JOURNAL_BUCKET}\",\"Condition\":{\"StringLike\":{\"s3:prefix\":\"companies/*\"}}},
      {\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogGroup\",\"logs:CreateLogStream\",\"logs:PutLogEvents\"],\"Resource\":\"arn:aws:logs:*:*:*\"}]}"
  sleep 10
fi
echo "  WRAITH_MICROVM_IMAGE_ARN=$IMAGE_ARN"
echo "  WRAITH_MICROVM_IMAGE_VERSION=<the version printed below>"
echo "  WRAITH_MICROVM_EXECUTION_ROLE_ARN=$EXEC_ROLE_ARN"
echo "  WRAITH_JOURNAL_BUCKET=$JOURNAL_BUCKET"

DESC="kas ${KAS_VERSION} ctx ${SHA}"
HOOKS='{"port":8080,"microvmImageHooks":{"ready":"ENABLED","readyTimeoutInSeconds":300,"validate":"ENABLED","validateTimeoutInSeconds":120},"microvmHooks":{"run":"ENABLED","runTimeoutInSeconds":60,"resume":"ENABLED","resumeTimeoutInSeconds":30,"suspend":"ENABLED","suspendTimeoutInSeconds":30,"terminate":"ENABLED","terminateTimeoutInSeconds":30}}'
if aws lambda-microvms get-microvm-image --image-identifier "$IMAGE_ARN" >/dev/null 2>&1; then
  echo "▸ update-microvm-image $IMAGE_NAME"
  aws lambda-microvms update-microvm-image --image-identifier "$IMAGE_ARN" \
    --code-artifact "uri=s3://$BUCKET/$KEY" --base-image-arn "$BASE_IMAGE" --build-role-arn "$ROLE_ARN" \
    --description "$DESC" --hooks "$HOOKS" --output table --query '{state:state,version:imageVersion}'
else
  echo "▸ create-microvm-image $IMAGE_NAME"
  aws lambda-microvms create-microvm-image --name "$IMAGE_NAME" \
    --code-artifact "uri=s3://$BUCKET/$KEY" --base-image-arn "$BASE_IMAGE" --build-role-arn "$ROLE_ARN" \
    --description "$DESC" --hooks "$HOOKS" --resources minimumMemoryInMiB=2048 --output table --query '{state:state,arn:imageArn}'
fi
echo "▸ watch: aws lambda-microvms get-microvm-image --image-identifier $IMAGE_ARN --query '{state:state,reason:stateReason}'"
