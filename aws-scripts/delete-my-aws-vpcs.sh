#!/usr/bin/env bash

set -u
set -o pipefail

VPC_NAME="my-aws-vpc"
REGION="us-east-1"
ALL_REGIONS=false
DRY_RUN=false

usage() {
    cat <<EOF
Usage: ./delete-my-aws-vpcs.sh [options]

Deletes VPCs tagged Name=${VPC_NAME} and their common dependencies, including
EC2 Instance Connect Endpoints and eligible EC2 network interfaces.

Options:
  --region REGION     AWS region to clean. Default: ${REGION}
  --all-regions       Scan and clean every enabled AWS region.
  --name NAME         VPC Name tag to delete. Default: ${VPC_NAME}
  --dry-run           Print commands without executing them.
  -h, --help          Show this help.
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
    if [ "$DRY_RUN" = true ]; then
        printf '[DRY-RUN] %q ' "$@" >&2
        printf '\n' >&2
        return 0
    fi

    "$@"
}

read_words() {
    tr '\t' '\n' | tr ' ' '\n' | sed '/^$/d'
}

delete_instance_connect_endpoints() {
    local region=$1
    local vpc_id=$2
    local endpoint_ids

    endpoint_ids=$(aws ec2 describe-instance-connect-endpoints \
        --region "$region" \
        --filters "Name=vpc-id,Values=${vpc_id}" \
        --query 'InstanceConnectEndpoints[].InstanceConnectEndpointId' \
        --output text 2>/dev/null | read_words)

    for endpoint_id in $endpoint_ids; do
        log "Deleting EC2 Instance Connect Endpoint: ${endpoint_id}"
        run aws ec2 delete-instance-connect-endpoint --region "$region" --instance-connect-endpoint-id "$endpoint_id" >/dev/null || true
    done

    if [ -n "$endpoint_ids" ] && [ "$DRY_RUN" = false ]; then
        for endpoint_id in $endpoint_ids; do
            for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do
                state=$(aws ec2 describe-instance-connect-endpoints \
                    --region "$region" \
                    --instance-connect-endpoint-ids "$endpoint_id" \
                    --query 'InstanceConnectEndpoints[0].State' \
                    --output text 2>/dev/null || true)
                [ "$state" = "delete-complete" ] || [ -z "$state" ] || [ "$state" = "None" ] && break
                sleep 10
            done
        done
    fi
}

delete_vpc_dependencies() {
    local region=$1
    local vpc_id=$2

    log "Cleaning dependencies for ${vpc_id} in ${region}"

    local instance_ids
    instance_ids=$(aws ec2 describe-instances \
        --region "$region" \
        --filters "Name=vpc-id,Values=${vpc_id}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text | read_words)

    if [ -n "$instance_ids" ]; then
        log "Terminating EC2 instances: ${instance_ids}"
        run aws ec2 terminate-instances --region "$region" --instance-ids $instance_ids >/dev/null
        if [ "$DRY_RUN" = false ]; then
            aws ec2 wait instance-terminated --region "$region" --instance-ids $instance_ids
        fi
    fi

    local nat_gateway_ids
    nat_gateway_ids=$(aws ec2 describe-nat-gateways \
        --region "$region" \
        --filter "Name=vpc-id,Values=${vpc_id}" "Name=state,Values=pending,available,failed" \
        --query 'NatGateways[].NatGatewayId' \
        --output text | read_words)

    if [ -n "$nat_gateway_ids" ]; then
        for nat_gateway_id in $nat_gateway_ids; do
            log "Deleting NAT gateway: ${nat_gateway_id}"
            run aws ec2 delete-nat-gateway --region "$region" --nat-gateway-id "$nat_gateway_id" >/dev/null
        done
        if [ "$DRY_RUN" = false ]; then
            log "Waiting for NAT gateways to delete"
            for nat_gateway_id in $nat_gateway_ids; do
                while true; do
                    state=$(aws ec2 describe-nat-gateways --region "$region" --nat-gateway-ids "$nat_gateway_id" --query 'NatGateways[0].State' --output text 2>/dev/null || true)
                    [ "$state" = "deleted" ] || [ -z "$state" ] || [ "$state" = "None" ] && break
                    sleep 10
                done
            done
        fi
    fi

    local igw_ids
    igw_ids=$(aws ec2 describe-internet-gateways \
        --region "$region" \
        --filters "Name=attachment.vpc-id,Values=${vpc_id}" \
        --query 'InternetGateways[].InternetGatewayId' \
        --output text | read_words)

    for igw_id in $igw_ids; do
        log "Detaching and deleting internet gateway: ${igw_id}"
        run aws ec2 detach-internet-gateway --region "$region" --internet-gateway-id "$igw_id" --vpc-id "$vpc_id" >/dev/null || true
        run aws ec2 delete-internet-gateway --region "$region" --internet-gateway-id "$igw_id" >/dev/null || true
    done

    local route_table_ids
    route_table_ids=$(aws ec2 describe-route-tables \
        --region "$region" \
        --filters "Name=vpc-id,Values=${vpc_id}" \
        --query 'RouteTables[?Associations[?Main!=`true`]].RouteTableId' \
        --output text | read_words)

    for route_table_id in $route_table_ids; do
        local association_ids
        association_ids=$(aws ec2 describe-route-tables \
            --region "$region" \
            --route-table-ids "$route_table_id" \
            --query 'RouteTables[].Associations[?Main!=`true`].RouteTableAssociationId' \
            --output text | read_words)

        for association_id in $association_ids; do
            log "Disassociating route table association: ${association_id}"
            run aws ec2 disassociate-route-table --region "$region" --association-id "$association_id" >/dev/null || true
        done

        log "Deleting route table: ${route_table_id}"
        run aws ec2 delete-route-table --region "$region" --route-table-id "$route_table_id" >/dev/null || true
    done

    delete_instance_connect_endpoints "$region" "$vpc_id"

    local network_interface_ids
    network_interface_ids=$(aws ec2 describe-network-interfaces \
        --region "$region" \
        --filters "Name=vpc-id,Values=${vpc_id}" \
        --query 'NetworkInterfaces[].NetworkInterfaceId' \
        --output text | read_words)

    for network_interface_id in $network_interface_ids; do
        requester_managed=$(aws ec2 describe-network-interfaces \
            --region "$region" \
            --network-interface-ids "$network_interface_id" \
            --query 'NetworkInterfaces[0].RequesterManaged' \
            --output text 2>/dev/null || true)
        if [ "$requester_managed" = "True" ]; then
            warn "Skipping requester-managed network interface: ${network_interface_id}"
            continue
        fi

        attachment_id=$(aws ec2 describe-network-interfaces \
            --region "$region" \
            --network-interface-ids "$network_interface_id" \
            --query 'NetworkInterfaces[0].Attachment.AttachmentId' \
            --output text 2>/dev/null || true)

        if [ -n "$attachment_id" ] && [ "$attachment_id" != "None" ]; then
            log "Detaching network interface: ${network_interface_id}"
            run aws ec2 detach-network-interface --region "$region" --attachment-id "$attachment_id" --force >/dev/null || true
            if [ "$DRY_RUN" = false ]; then
                for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
                    status=$(aws ec2 describe-network-interfaces \
                        --region "$region" \
                        --network-interface-ids "$network_interface_id" \
                        --query 'NetworkInterfaces[0].Status' \
                        --output text 2>/dev/null || true)
                    [ "$status" = "available" ] && break
                    sleep 5
                done
            fi
        fi

        log "Deleting network interface: ${network_interface_id}"
        run aws ec2 delete-network-interface --region "$region" --network-interface-id "$network_interface_id" >/dev/null || true
    done

    local subnet_ids
    subnet_ids=$(aws ec2 describe-subnets \
        --region "$region" \
        --filters "Name=vpc-id,Values=${vpc_id}" \
        --query 'Subnets[].SubnetId' \
        --output text | read_words)

    for subnet_id in $subnet_ids; do
        log "Deleting subnet: ${subnet_id}"
        run aws ec2 delete-subnet --region "$region" --subnet-id "$subnet_id" >/dev/null || true
    done

    local security_group_ids
    security_group_ids=$(aws ec2 describe-security-groups \
        --region "$region" \
        --filters "Name=vpc-id,Values=${vpc_id}" \
        --query "SecurityGroups[?GroupName!='default'].GroupId" \
        --output text | read_words)

    for security_group_id in $security_group_ids; do
        log "Deleting security group: ${security_group_id}"
        run aws ec2 delete-security-group --region "$region" --group-id "$security_group_id" >/dev/null || true
    done
}

delete_matching_vpcs_in_region() {
    local region=$1
    log "Searching ${region} for VPCs tagged Name=${VPC_NAME}"

    local vpc_ids
    vpc_ids=$(aws ec2 describe-vpcs \
        --region "$region" \
        --filters "Name=tag:Name,Values=${VPC_NAME}" \
        --query 'Vpcs[].VpcId' \
        --output text 2>/dev/null | read_words)

    if [ -z "$vpc_ids" ]; then
        log "No matching VPCs found in ${region}"
        return 0
    fi

    for vpc_id in $vpc_ids; do
        log "Preparing to delete VPC: ${vpc_id}"
        delete_vpc_dependencies "$region" "$vpc_id"
        log "Deleting VPC: ${vpc_id}"
        if run aws ec2 delete-vpc --region "$region" --vpc-id "$vpc_id" >/dev/null; then
            log "Deleted VPC: ${vpc_id}"
        else
            err "Failed to delete VPC: ${vpc_id}"
        fi
    done
}

while [ $# -gt 0 ]; do
    case "$1" in
        --region)
            REGION=${2:?Missing region}
            shift 2
            ;;
        --all-regions)
            ALL_REGIONS=true
            shift
            ;;
        --name)
            VPC_NAME=${2:?Missing VPC name}
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
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

if [ "$ALL_REGIONS" = true ]; then
    regions=$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text | read_words)
else
    regions=$REGION
fi

for region in $regions; do
    delete_matching_vpcs_in_region "$region"
done

log "Cleanup complete"
