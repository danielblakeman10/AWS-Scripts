#!/usr/bin/env bash

set -u
set -o pipefail

CONFIRM=false
ARN_PATTERN=""
EXCLUDE_ARN_PATTERN=""

usage() {
    cat <<EOF
Usage: ./delete-iam-identity-providers.sh [options]

Deletes IAM SAML and OpenID Connect identity providers.

Default mode is dry-run. Nothing is deleted unless --confirm-delete is provided.

Options:
  --confirm-delete          Actually delete identity providers.
  --arn-pattern REGEX       Only delete provider ARNs matching this regex.
  --exclude-arn-pattern REGEX
                            Skip provider ARNs matching this regex.
  -h, --help                Show this help.

Examples:
  ./delete-iam-identity-providers.sh
  ./delete-iam-identity-providers.sh --arn-pattern 'token.actions.githubusercontent.com' --confirm-delete
  ./delete-iam-identity-providers.sh --exclude-arn-pattern 'roc|production' --confirm-delete
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

should_delete_provider() {
    local provider_arn=$1

    if [ -n "$ARN_PATTERN" ] && ! printf '%s\n' "$provider_arn" | grep -Eiq "$ARN_PATTERN"; then
        log "Skipping provider because it does not match --arn-pattern: ${provider_arn}"
        return 1
    fi

    if [ -n "$EXCLUDE_ARN_PATTERN" ] && printf '%s\n' "$provider_arn" | grep -Eiq "$EXCLUDE_ARN_PATTERN"; then
        warn "Skipping provider because it matches --exclude-arn-pattern: ${provider_arn}"
        return 1
    fi

    return 0
}

delete_oidc_providers() {
    local provider_arns

    provider_arns=$(aws iam list-open-id-connect-providers \
        --query 'OpenIDConnectProviderList[].Arn' \
        --output text 2>/dev/null | words)

    if [ -z "$provider_arns" ]; then
        log "No IAM OpenID Connect providers found"
        return 0
    fi

    for provider_arn in $provider_arns; do
        if should_delete_provider "$provider_arn"; then
            log "Deleting IAM OpenID Connect provider: ${provider_arn}"
            if run aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$provider_arn" >/dev/null; then
                log "Deleted IAM OpenID Connect provider: ${provider_arn}"
            else
                err "Failed to delete IAM OpenID Connect provider: ${provider_arn}"
            fi
        fi
    done
}

delete_saml_providers() {
    local provider_arns

    provider_arns=$(aws iam list-saml-providers \
        --query 'SAMLProviderList[].Arn' \
        --output text 2>/dev/null | words)

    if [ -z "$provider_arns" ]; then
        log "No IAM SAML providers found"
        return 0
    fi

    for provider_arn in $provider_arns; do
        if should_delete_provider "$provider_arn"; then
            log "Deleting IAM SAML provider: ${provider_arn}"
            if run aws iam delete-saml-provider --saml-provider-arn "$provider_arn" >/dev/null; then
                log "Deleted IAM SAML provider: ${provider_arn}"
            else
                err "Failed to delete IAM SAML provider: ${provider_arn}"
            fi
        fi
    done
}

while [ $# -gt 0 ]; do
    case "$1" in
        --confirm-delete)
            CONFIRM=true
            shift
            ;;
        --arn-pattern)
            ARN_PATTERN=${2:?Missing ARN pattern}
            shift 2
            ;;
        --exclude-arn-pattern)
            EXCLUDE_ARN_PATTERN=${2:?Missing exclude ARN pattern}
            shift 2
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

if ! aws sts get-caller-identity >/dev/null 2>&1; then
    err "AWS credentials are not configured or are invalid"
    exit 1
fi

if [ "$CONFIRM" != true ]; then
    warn "Dry-run mode. Add --confirm-delete to actually delete identity providers."
fi

delete_oidc_providers
delete_saml_providers

log "IAM identity provider cleanup complete"
