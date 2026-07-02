#!/usr/bin/env bash

set -u
set -o pipefail

CONFIRM=false
REGION=""
ALL_REGIONS=true

usage() {
    cat <<EOF
Usage: ./nuke-aws-lab-resources.sh [options]

Deletes EC2 instances, key pairs, VPC dependencies, non-default security groups,
subnets, internet gateways, NAT gateways, route tables, and non-default VPCs.

Default mode is dry-run. Nothing is deleted unless --confirm-delete is provided.

Options:
  --confirm-delete   Actually delete resources.
  --region REGION    Limit deletion to one AWS region.
  --all-regions      Scan all enabled regions. Default behavior.
  -h, --help         Show this help.
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
        printf '%q ' "$@"
        printf '\n'
        return 0
    fi

    "$@"
}

words() {
    tr '\t' '\n' | tr ' ' '\n' | sed '/^$/d'
}

delete_instances() {
    local region=$1
    local instance_ids

    instance_ids=$(aws ec2 describe-instances \
        --region "$region" \
        --filters "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text 2>/dev/null | words)

    if [ -z "$instance_ids" ]; then
        log "No EC2 instances found in ${region}"
        return 0
    fi

    log "Terminating EC2 instances in ${region}: ${instance_ids}"
    run aws ec2 terminate-instances --region "$region" --instance-ids $instance_ids >/dev/null

    if [ "$CONFIRM" = true ]; then
        aws ec2 wait instance-terminated --region "$region" --instance-ids $instance_ids
    fi
}

delete_key_pairs() {
    local region=$1
    local key_names

    key_names=$(aws ec2 describe-key-pairs \
        --region "$region" \
        --query 'KeyPairs[].KeyName' \
        --output text 2>/dev/null | words)

    if [ -z "$key_names" ]; then
        log "No EC2 key pairs found in ${region}"
        return 0
    fi

    for key_name in $key_names; do
        log "Deleting key pair in ${region}: ${key_name}"
        run aws ec2 delete-key-pair --region "$region" --key-name "$key_name" >/dev/null
    done
}

delete_nat_gateways() {
    local region=$1
    local vpc_id=$2
    local nat_gateway_ids

    nat_gateway_ids=$(aws ec2 describe-nat-gateways \
        --region "$region" \
        --filter "Name=vpc-id,Values=${vpc_id}" "Name=state,Values=pending,available,failed" \
        --query 'NatGateways[].NatGatewayId' \
        --output text 2>/dev/null | words)

    for nat_gateway_id in $nat_gateway_ids; do
        log "Deleting NAT gateway in ${region}: ${nat_gateway_id}"
        run aws ec2 delete-nat-gateway --region "$region" --nat-gateway-id "$nat_gateway_id" >/dev/null
    done

    if [ -n "$nat_gateway_ids" ] && [ "$CONFIRM" = true ]; then
        for nat_gateway_id in $nat_gateway_ids; do
            while true; do
                state=$(aws ec2 describe-nat-gateways \
                    --region "$region" \
                    --nat-gateway-ids "$nat_gateway_id" \
                    --query 'NatGateways[0].State' \
                    --output text 2>/dev/null || true)
                [ "$state" = "deleted" ] || [ -z "$state" ] || [ "$state" = "None" ] && break
                sleep 10
            done
        done
    fi
}

delete_internet_gateways() {
    local region=$1
    local vpc_id=$2
    local igw_ids

    igw_ids=$(aws ec2 describe-internet-gateways \
        --region "$region" \
        --filters "Name=attachment.vpc-id,Values=${vpc_id}" \
        --query 'InternetGateways[].InternetGatewayId' \
        --output text 2>/dev/null | words)

    for igw_id in $igw_ids; do
        log "Detaching and deleting internet gateway in ${region}: ${igw_id}"
        run aws ec2 detach-internet-gateway --region "$region" --internet-gateway-id "$igw_id" --vpc-id "$vpc_id" >/dev/null || true
        run aws ec2 delete-internet-gateway --region "$region" --internet-gateway-id "$igw_id" >/dev/null || true
    done
}

delete_route_tables() {
    local region=$1
    local vpc_id=$2
    local route_table_ids

    route_table_ids=$(aws ec2 describe-route-tables \
        --region "$region" \
        --filters "Name=vpc-id,Values=${vpc_id}" \
        --query 'RouteTables[?Associations[?Main!=`true`]].RouteTableId' \
        --output text 2>/dev/null | words)

    for route_table_id in $route_table_ids; do
        local association_ids
        association_ids=$(aws ec2 describe-route-tables \
            --region "$region" \
            --route-table-ids "$route_table_id" \
            --query 'RouteTables[].Associations[?Main!=`true`].RouteTableAssociationId' \
            --output text 2>/dev/null | words)

        for association_id in $association_ids; do
            log "Disassociating route table association in ${region}: ${association_id}"
            run aws ec2 disassociate-route-table --region "$region" --association-id "$association_id" >/dev/null || true
        done

        log "Deleting route table in ${region}: ${route_table_id}"
        run aws ec2 delete-route-table --region "$region" --route-table-id "$route_table_id" >/dev/null || true
    done
}

delete_subnets() {
    local region=$1
    local vpc_id=$2
    local subnet_ids

    subnet_ids=$(aws ec2 describe-subnets \
        --region "$region" \
        --filters "Name=vpc-id,Values=${vpc_id}" \
        --query 'Subnets[].SubnetId' \
        --output text 2>/dev/null | words)

    for subnet_id in $subnet_ids; do
        log "Deleting subnet in ${region}: ${subnet_id}"
        run aws ec2 delete-subnet --region "$region" --subnet-id "$subnet_id" >/dev/null || true
    done
}

delete_security_groups() {
    local region=$1
    local vpc_id=$2
    local security_group_ids

    security_group_ids=$(aws ec2 describe-security-groups \
        --region "$region" \
        --filters "Name=vpc-id,Values=${vpc_id}" \
        --query "SecurityGroups[?GroupName!='default'].GroupId" \
        --output text 2>/dev/null | words)

    for security_group_id in $security_group_ids; do
        log "Deleting security group in ${region}: ${security_group_id}"
        run aws ec2 delete-security-group --region "$region" --group-id "$security_group_id" >/dev/null || true
    done
}

delete_vpcs() {
    local region=$1
    local vpc_ids

    vpc_ids=$(aws ec2 describe-vpcs \
        --region "$region" \
        --query 'Vpcs[?IsDefault==`false`].VpcId' \
        --output text 2>/dev/null | words)

    if [ -z "$vpc_ids" ]; then
        log "No non-default VPCs found in ${region}"
        return 0
    fi

    for vpc_id in $vpc_ids; do
        log "Cleaning non-default VPC in ${region}: ${vpc_id}"
        delete_nat_gateways "$region" "$vpc_id"
        delete_internet_gateways "$region" "$vpc_id"
        delete_route_tables "$region" "$vpc_id"
        delete_subnets "$region" "$vpc_id"
        delete_security_groups "$region" "$vpc_id"

        log "Deleting VPC in ${region}: ${vpc_id}"
        run aws ec2 delete-vpc --region "$region" --vpc-id "$vpc_id" >/dev/null || true
    done
}

while [ $# -gt 0 ]; do
    case "$1" in
        --confirm-delete)
            CONFIRM=true
            shift
            ;;
        --region)
            REGION=${2:?Missing region}
            ALL_REGIONS=false
            shift 2
            ;;
        --all-regions)
            ALL_REGIONS=true
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

if ! aws sts get-caller-identity >/dev/null 2>&1; then
    err "AWS credentials are not configured or are invalid"
    exit 1
fi

if [ "$CONFIRM" != true ]; then
    warn "Dry-run mode. Add --confirm-delete to actually delete resources."
fi

if [ "$ALL_REGIONS" = true ]; then
    regions=$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text | words)
else
    regions=$REGION
fi

for region in $regions; do
    log "Starting cleanup in ${region}"
    delete_instances "$region"
    delete_key_pairs "$region"
    delete_vpcs "$region"
done

log "Cleanup complete"
