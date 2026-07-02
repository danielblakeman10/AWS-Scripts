#!/usr/bin/env bash

set -u
set -o pipefail

CONFIRM=false
INCLUDE_SERVICE_LINKED=false
OLDER_THAN_DAYS=30
EXCLUDE_NAME_PATTERN=""

usage() {
    cat <<EOF
Usage: ./delete-inactive-or-old-iam-roles.sh [options]

Deletes IAM roles that either have no recorded RoleLastUsed activity or were
created more than 30 days ago. Attached managed policies, inline policies, and
instance profile associations are removed before each role is deleted.

Default mode is dry-run. Nothing is deleted unless --confirm-delete is provided.

Options:
  --confirm-delete          Actually delete matching roles.
  --older-than-days DAYS    Delete roles created more than DAYS ago. Default: ${OLDER_THAN_DAYS}
  --exclude-name-pattern REGEX
                            Skip role names matching this regex.
  --include-service-linked  Also attempt service-linked role deletion.
  -h, --help                Show this help.

Examples:
  ./delete-inactive-or-old-iam-roles.sh
  ./delete-inactive-or-old-iam-roles.sh --exclude-name-pattern 'roc|AWSReservedSSO'
  ./delete-inactive-or-old-iam-roles.sh --confirm-delete
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
        --older-than-days)
            OLDER_THAN_DAYS=${2:?Missing day count}
            shift 2
            ;;
        --exclude-name-pattern)
            EXCLUDE_NAME_PATTERN=${2:?Missing exclude name pattern}
            shift 2
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
    warn "Dry-run mode. Add --confirm-delete to actually delete matching IAM roles."
fi

roles_json=$(aws iam list-roles --output json)
roles_json_file=$(mktemp)
trap 'rm -f "$roles_json_file"' EXIT
printf '%s' "$roles_json" > "$roles_json_file"

role_lines=$(python3 - "$roles_json_file" "$OLDER_THAN_DAYS" "$INCLUDE_SERVICE_LINKED" "$EXCLUDE_NAME_PATTERN" <<'PY'
import json
import re
import sys
from datetime import datetime, timezone, timedelta

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    roles = json.load(handle).get("Roles", [])
older_than_days = int(sys.argv[2])
include_service_linked = sys.argv[3].lower() == "true"
exclude_pattern = sys.argv[4]
cutoff = datetime.now(timezone.utc) - timedelta(days=older_than_days)

def parse_dt(value):
    if not value:
        return None
    if not isinstance(value, str):
        return value
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed

for role in roles:
    name = role["RoleName"]
    path = role.get("Path", "")
    if not include_service_linked and path.startswith("/aws-service-role/"):
        continue
    if exclude_pattern and re.search(exclude_pattern, name, re.IGNORECASE):
        continue

    created = parse_dt(role.get("CreateDate"))
    last_used = parse_dt(role.get("RoleLastUsed", {}).get("LastUsedDate"))
    is_old = created is not None and created < cutoff
    has_no_activity = last_used is None

    if is_old or has_no_activity:
        reasons = []
        if has_no_activity:
            reasons.append("no-activity")
        if is_old:
            reasons.append(f"created-older-than-{older_than_days}-days")
        print(f"{name}\t{path}\t{created.isoformat() if created else ''}\t{last_used.isoformat() if last_used else ''}\t{','.join(reasons)}")
PY
)

if [ -z "$role_lines" ]; then
    log "No matching IAM roles found"
    exit 0
fi

while IFS=$'\t' read -r role_name role_path create_date last_used reasons; do
    [ -z "$role_name" ] && continue
    log "Matched IAM role: ${role_name} (${reasons}; created=${create_date:-unknown}; last_used=${last_used:-none})"
    delete_role "$role_name" "$role_path"
done <<< "$role_lines"

log "Inactive or old IAM role cleanup complete"
