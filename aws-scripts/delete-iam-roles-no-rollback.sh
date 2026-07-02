#!/usr/bin/env bash

set -u
set -o pipefail

CONFIRM=false
INCLUDE_SERVICE_LINKED=false
NAME_PATTERN=""
EXCLUDE_NAME_PATTERN=""
OLDER_THAN_DAYS=""

usage() {
    cat <<EOF
Usage: ./delete-iam-roles-no-rollback.sh [options]

Deletes IAM roles after removing attached managed policies, inline policies,
and instance profile associations. This version does not create a rollback
manifest.

Default mode is dry-run. Nothing is deleted unless --confirm-delete is provided.

Options:
  --confirm-delete          Actually delete roles.
  --name-pattern REGEX      Only delete role names matching this regex.
  --exclude-name-pattern REGEX
                            Skip role names matching this regex.
  --older-than-days DAYS    Only delete roles created more than DAYS ago.
  --older-than-one-year     Only delete roles older than 365 days.
  --include-service-linked  Also attempt service-linked role deletion.
  -h, --help                Show this help.

Examples:
  ./delete-iam-roles-no-rollback.sh
  ./delete-iam-roles-no-rollback.sh --name-pattern '^my-lab-' --confirm-delete
  ./delete-iam-roles-no-rollback.sh --exclude-name-pattern 'roc|AWSReservedSSO' --confirm-delete
EOF
}

log() {
    printf '[INFO] %s\n' "$*" >&2
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

err() {
    printf '[ERROR] %s\n' "$*" >&2
}

run() {
    if [ "$CONFIRM" != true ]; then
        printf '[DRY-RUN] '
        printf '%q ' "$@" >&2
        printf '\n' >&2
        return 0
    fi

    "$@"
}

words() {
    tr '\t' '\n' | tr ' ' '\n' | sed '/^$/d'
}

should_delete_role() {
    local role_name=$1
    local role_path=$2
    local create_date=$3

    if [ "$INCLUDE_SERVICE_LINKED" != true ] && [[ "$role_path" == /aws-service-role/* ]]; then
        warn "Skipping service-linked role: ${role_name}"
        return 1
    fi

    if [ -n "$NAME_PATTERN" ] && ! printf '%s\n' "$role_name" | grep -Eiq "$NAME_PATTERN"; then
        log "Skipping role because it does not match --name-pattern: ${role_name}"
        return 1
    fi

    if [ -n "$EXCLUDE_NAME_PATTERN" ] && printf '%s\n' "$role_name" | grep -Eiq "$EXCLUDE_NAME_PATTERN"; then
        warn "Skipping role because it matches --exclude-name-pattern: ${role_name}"
        return 1
    fi

    if [ -n "$OLDER_THAN_DAYS" ]; then
        if ! python3 - "$create_date" "$OLDER_THAN_DAYS" <<'PY'
import sys
from datetime import datetime, timezone, timedelta

create_date = sys.argv[1].replace("Z", "+00:00")
older_than_days = int(sys.argv[2])
created = datetime.fromisoformat(create_date)
if created.tzinfo is None:
    created = created.replace(tzinfo=timezone.utc)
cutoff = datetime.now(timezone.utc) - timedelta(days=older_than_days)
sys.exit(0 if created < cutoff else 1)
PY
        then
            log "Skipping role because it is not older than ${OLDER_THAN_DAYS} days: ${role_name}"
            return 1
        fi
    fi

    return 0
}

delete_role_dependencies() {
    local role_name=$1
    local managed_policy_arns
    local inline_policy_names
    local instance_profile_names

    managed_policy_arns=$(aws iam list-attached-role-policies \
        --role-name "$role_name" \
        --query 'AttachedPolicies[].PolicyArn' \
        --output text 2>/dev/null | words)

    for policy_arn in $managed_policy_arns; do
        log "Detaching managed policy from ${role_name}: ${policy_arn}"
        run aws iam detach-role-policy --role-name "$role_name" --policy-arn "$policy_arn" >/dev/null || true
    done

    inline_policy_names=$(aws iam list-role-policies \
        --role-name "$role_name" \
        --query 'PolicyNames[]' \
        --output text 2>/dev/null | words)

    for policy_name in $inline_policy_names; do
        log "Deleting inline policy from ${role_name}: ${policy_name}"
        run aws iam delete-role-policy --role-name "$role_name" --policy-name "$policy_name" >/dev/null || true
    done

    instance_profile_names=$(aws iam list-instance-profiles-for-role \
        --role-name "$role_name" \
        --query 'InstanceProfiles[].InstanceProfileName' \
        --output text 2>/dev/null | words)

    for instance_profile_name in $instance_profile_names; do
        log "Removing ${role_name} from instance profile: ${instance_profile_name}"
        run aws iam remove-role-from-instance-profile \
            --instance-profile-name "$instance_profile_name" \
            --role-name "$role_name" >/dev/null || true
    done
}

delete_role() {
    local role_name=$1
    local role_path=$2

    delete_role_dependencies "$role_name"

    if [[ "$role_path" == /aws-service-role/* ]]; then
        log "Deleting service-linked role: ${role_name}"
        run aws iam delete-service-linked-role --role-name "$role_name" >/dev/null || true
        return
    fi

    log "Deleting IAM role: ${role_name}"
    if run aws iam delete-role --role-name "$role_name" >/dev/null; then
        log "Deleted IAM role: ${role_name}"
    else
        err "Failed to delete IAM role: ${role_name}"
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --confirm-delete)
            CONFIRM=true
            shift
            ;;
        --name-pattern)
            NAME_PATTERN=${2:?Missing name pattern}
            shift 2
            ;;
        --exclude-name-pattern)
            EXCLUDE_NAME_PATTERN=${2:?Missing exclude name pattern}
            shift 2
            ;;
        --older-than-days)
            OLDER_THAN_DAYS=${2:?Missing day count}
            shift 2
            ;;
        --older-than-one-year)
            OLDER_THAN_DAYS=365
            shift
            ;;
        --include-service-linked)
            INCLUDE_SERVICE_LINKED=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            err "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

if ! command -v aws >/dev/null 2>&1; then
    err "AWS CLI is not installed or not on PATH"
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    err "python3 is required"
    exit 1
fi

if ! aws sts get-caller-identity >/dev/null 2>&1; then
    err "AWS credentials are not configured or are invalid"
    exit 1
fi

if [ "$CONFIRM" != true ]; then
    warn "Dry-run mode. Add --confirm-delete to actually delete IAM roles."
fi

roles_json=$(aws iam list-roles \
    --query 'Roles[].{RoleName:RoleName,Path:Path,CreateDate:CreateDate}' \
    --output json)

role_lines=$(python3 - "$roles_json" <<'PY'
import json
import sys

roles = json.loads(sys.argv[1])
for role in roles:
    print(f"{role['RoleName']}\t{role['Path']}\t{role['CreateDate']}")
PY
)

if [ -z "$role_lines" ]; then
    log "No IAM roles found"
    exit 0
fi

while IFS=$'\t' read -r role_name role_path create_date; do
    [ -z "$role_name" ] && continue
    if should_delete_role "$role_name" "$role_path" "$create_date"; then
        delete_role "$role_name" "$role_path"
    fi
done <<< "$role_lines"

log "IAM role cleanup complete"
