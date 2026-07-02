#!/usr/bin/env bash

set -u
set -o pipefail

CONFIRM=false
MANIFEST=""

usage() {
    cat <<EOF
Usage: ./rollback-iam-roles.sh --manifest FILE [options]

Restores IAM roles from a manifest created by delete-iam-roles.sh.

Default mode is dry-run. Nothing is created unless --confirm-restore is provided.

Options:
  --manifest FILE      IAM rollback manifest JSON file.
  --confirm-restore    Actually recreate roles and role relationships.
  -h, --help           Show this help.

Limitations:
  - Existing roles with the same names are skipped.
  - Attached managed policies are reattached only if those policy ARNs still exist.
  - Instance profile associations are restored only if the instance profiles still exist.
  - Service-linked roles are not recreated directly; AWS services normally recreate them.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --manifest)
            MANIFEST=${2:?Missing manifest path}
            shift 2
            ;;
        --confirm-restore)
            CONFIRM=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf '[ERROR] Unknown option: %s\n' "$1" >&2
            usage
            exit 1
            ;;
    esac
done

if [ -z "$MANIFEST" ]; then
    printf '[ERROR] --manifest is required\n' >&2
    usage
    exit 1
fi

if [ ! -f "$MANIFEST" ]; then
    printf '[ERROR] Manifest not found: %s\n' "$MANIFEST" >&2
    exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
    printf '[ERROR] AWS CLI is not installed or not on PATH\n' >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    printf '[ERROR] python3 is required\n' >&2
    exit 1
fi

if ! aws sts get-caller-identity >/dev/null 2>&1; then
    printf '[ERROR] AWS credentials are not configured or are invalid\n' >&2
    exit 1
fi

if [ "$CONFIRM" != true ]; then
    printf '[WARN] Dry-run mode. Add --confirm-restore to actually restore IAM roles.\n' >&2
fi

python3 - "$MANIFEST" "$CONFIRM" <<'PY'
import json
import subprocess
import sys
import tempfile
from pathlib import Path

manifest_path = sys.argv[1]
confirm = sys.argv[2].lower() == "true"

with open(manifest_path, "r", encoding="utf-8") as handle:
    manifest = json.load(handle)

def log(message):
    print(f"[INFO] {message}", file=sys.stderr)

def warn(message):
    print(f"[WARN] {message}", file=sys.stderr)

def run(args, capture=True, allow_fail=False):
    if not confirm:
        print("[DRY-RUN] " + " ".join(subprocess.list2cmdline([arg]) for arg in args))
        return None

    proc = subprocess.run(args, text=True, capture_output=capture)
    if proc.returncode != 0 and not allow_fail:
        raise RuntimeError(f"command failed: {' '.join(args)}\n{proc.stderr}")
    if proc.returncode != 0:
        warn(proc.stderr.strip())
        return None
    if capture:
        text = proc.stdout.strip()
        return json.loads(text) if text else None
    return None

def aws(args, capture=True, allow_fail=False):
    return run(["aws", *args], capture=capture, allow_fail=allow_fail)

def write_json_file(obj, prefix):
    temp = tempfile.NamedTemporaryFile("w", encoding="utf-8", prefix=prefix, suffix=".json", delete=False)
    with temp:
        json.dump(obj, temp, indent=2, sort_keys=True)
        temp.write("\n")
    return temp.name

def role_exists(role_name):
    proc = subprocess.run(
        ["aws", "iam", "get-role", "--role-name", role_name],
        text=True,
        capture_output=True
    )
    return proc.returncode == 0

def policy_exists(policy_arn):
    proc = subprocess.run(
        ["aws", "iam", "get-policy", "--policy-arn", policy_arn],
        text=True,
        capture_output=True
    )
    return proc.returncode == 0

def instance_profile_exists(profile_name):
    proc = subprocess.run(
        ["aws", "iam", "get-instance-profile", "--instance-profile-name", profile_name],
        text=True,
        capture_output=True
    )
    return proc.returncode == 0

for role in manifest.get("roles", []):
    role_name = role["RoleName"]
    role_path = role.get("Path", "/")

    if role_path.startswith("/aws-service-role/"):
        warn(f"Skipping service-linked role restore: {role_name}")
        continue

    if role_exists(role_name):
        warn(f"Skipping existing role: {role_name}")
        continue

    assume_policy_path = write_json_file(role["AssumeRolePolicyDocument"], f"{role_name}-trust-")
    args = [
        "iam", "create-role",
        "--role-name", role_name,
        "--path", role_path,
        "--assume-role-policy-document", f"file://{assume_policy_path}",
    ]
    if role.get("Description"):
        args.extend(["--description", role["Description"]])
    if role.get("MaxSessionDuration"):
        args.extend(["--max-session-duration", str(role["MaxSessionDuration"])])
    if role.get("PermissionsBoundary", {}).get("PermissionsBoundaryArn"):
        args.extend(["--permissions-boundary", role["PermissionsBoundary"]["PermissionsBoundaryArn"]])

    log(f"Creating IAM role: {role_name}")
    aws(args, allow_fail=True)

    tags = role.get("RoleTags", [])
    if tags:
        tag_args = []
        for tag in tags:
            if tag.get("Key"):
                tag_args.append(f"Key={tag['Key']},Value={tag.get('Value', '')}")
        if tag_args:
            aws(["iam", "tag-role", "--role-name", role_name, "--tags", *tag_args], allow_fail=True)

    for policy in role.get("AttachedManagedPolicies", []):
        policy_arn = policy.get("PolicyArn")
        if not policy_arn:
            continue
        if not policy_exists(policy_arn):
            warn(f"Managed policy no longer exists, skipping attachment for {role_name}: {policy_arn}")
            continue
        log(f"Attaching managed policy to {role_name}: {policy_arn}")
        aws(["iam", "attach-role-policy", "--role-name", role_name, "--policy-arn", policy_arn], allow_fail=True)

    for policy in role.get("InlinePolicies", []):
        policy_name = policy.get("PolicyName")
        policy_document = policy.get("PolicyDocument")
        if not policy_name or not policy_document:
            continue
        policy_path = write_json_file(policy_document, f"{role_name}-{policy_name}-inline-")
        log(f"Restoring inline policy for {role_name}: {policy_name}")
        aws([
            "iam", "put-role-policy",
            "--role-name", role_name,
            "--policy-name", policy_name,
            "--policy-document", f"file://{policy_path}"
        ], allow_fail=True)

    for profile in role.get("InstanceProfiles", []):
        profile_name = profile.get("InstanceProfileName")
        if not profile_name:
            continue
        if not instance_profile_exists(profile_name):
            warn(f"Instance profile no longer exists, skipping association for {role_name}: {profile_name}")
            continue
        log(f"Adding {role_name} to instance profile: {profile_name}")
        aws([
            "iam", "add-role-to-instance-profile",
            "--instance-profile-name", profile_name,
            "--role-name", role_name
        ], allow_fail=True)

log("IAM role rollback restore pass complete")
PY
