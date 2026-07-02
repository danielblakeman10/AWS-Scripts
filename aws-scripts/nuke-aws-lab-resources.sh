#!/usr/bin/env bash

set -u
set -o pipefail

CONFIRM=false
REGION=""
ALL_REGIONS=true
INCLUDE_DEFAULT_VPCS=false
PROTECTED_TAG_PATTERN="roc"
MANIFEST_DIR="./rollback-manifests"

usage() {
    cat <<EOF
Usage: ./nuke-aws-lab-resources.sh [options]

Deletes EC2 instances, key pairs, VPC dependencies, network interfaces,
non-default security groups, subnets, internet gateways, NAT gateways, route tables,
and non-default VPCs.
Resources with tag keys or values containing "roc" are always skipped.

Default mode is dry-run. Nothing is deleted unless --confirm-delete is provided.

Options:
  --confirm-delete   Actually delete resources.
  --region REGION    Limit deletion to one AWS region.
  --all-regions      Scan all enabled regions. Default behavior.
  --include-default-vpcs
                     Also delete default VPCs. Default behavior preserves them.
  --manifest-dir DIR Write rollback manifests to this directory. Default: ${MANIFEST_DIR}
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

has_protected_tag() {
    local region=$1
    local resource_id=$2

    aws ec2 describe-tags \
        --region "$region" \
        --filters "Name=resource-id,Values=${resource_id}" \
        --query 'Tags[].{Key:Key,Value:Value}' \
        --output text 2>/dev/null | grep -qi "$PROTECTED_TAG_PATTERN"
}

key_pair_has_protected_tag() {
    local region=$1
    local key_name=$2

    aws ec2 describe-key-pairs \
        --region "$region" \
        --key-names "$key_name" \
        --query 'KeyPairs[].Tags[].{Key:Key,Value:Value}' \
        --output text 2>/dev/null | grep -qi "$PROTECTED_TAG_PATTERN"
}

write_rollback_manifest() {
    local manifest_path
    local timestamp

    timestamp=$(date -u '+%Y%m%dT%H%M%SZ')
    mkdir -p "$MANIFEST_DIR"
    manifest_path="${MANIFEST_DIR}/aws-cleanup-inventory-${timestamp}.json"

    log "Writing rollback inventory manifest: ${manifest_path}"
    python3 - "$manifest_path" "$INCLUDE_DEFAULT_VPCS" "$PROTECTED_TAG_PATTERN" $regions <<'PY'
import json
import subprocess
import sys
from datetime import datetime, timezone

manifest_path = sys.argv[1]
include_default_vpcs = sys.argv[2].lower() == "true"
protected_pattern = sys.argv[3].lower()
regions = sys.argv[4:]

def aws_json(args):
    proc = subprocess.run(["aws", *args, "--output", "json"], text=True, capture_output=True)
    if proc.returncode != 0:
        return None
    text = proc.stdout.strip()
    return json.loads(text) if text else None

def tag_has_pattern(tags):
    for tag in tags or []:
        if protected_pattern in str(tag.get("Key", "")).lower():
            return True
        if protected_pattern in str(tag.get("Value", "")).lower():
            return True
    return False

inventory = {
    "schema": "aws-scripts.rollback.v1",
    "createdAt": datetime.now(timezone.utc).isoformat(),
    "includeDefaultVpcs": include_default_vpcs,
    "protectedTagPattern": protected_pattern,
    "regions": []
}

for region in regions:
    region_data = {"region": region}

    vpcs = aws_json(["ec2", "describe-vpcs", "--region", region]) or {"Vpcs": []}
    selected_vpcs = []
    selected_vpc_ids = set()
    for vpc in vpcs.get("Vpcs", []):
        if not include_default_vpcs and vpc.get("IsDefault"):
            continue
        if tag_has_pattern(vpc.get("Tags", [])):
            continue
        selected_vpcs.append(vpc)
        selected_vpc_ids.add(vpc["VpcId"])

    if not selected_vpc_ids:
        region_data.update({
            "vpcs": [],
            "subnets": [],
            "internetGateways": [],
            "routeTables": [],
            "securityGroups": [],
            "instances": [],
            "keyPairs": []
        })
        inventory["regions"].append(region_data)
        continue

    subnets = aws_json(["ec2", "describe-subnets", "--region", region]) or {"Subnets": []}
    igws = aws_json(["ec2", "describe-internet-gateways", "--region", region]) or {"InternetGateways": []}
    route_tables = aws_json(["ec2", "describe-route-tables", "--region", region]) or {"RouteTables": []}
    security_groups = aws_json(["ec2", "describe-security-groups", "--region", region]) or {"SecurityGroups": []}
    network_interfaces = aws_json(["ec2", "describe-network-interfaces", "--region", region]) or {"NetworkInterfaces": []}
    instances = aws_json([
        "ec2", "describe-instances",
        "--region", region,
        "--filters", "Name=instance-state-name,Values=pending,running,stopping,stopped"
    ]) or {"Reservations": []}
    key_pairs = aws_json(["ec2", "describe-key-pairs", "--region", region, "--include-public-key"]) or {"KeyPairs": []}

    selected_subnets = [
        subnet for subnet in subnets.get("Subnets", [])
        if subnet.get("VpcId") in selected_vpc_ids and not tag_has_pattern(subnet.get("Tags", []))
    ]
    selected_igws = [
        igw for igw in igws.get("InternetGateways", [])
        if any(att.get("VpcId") in selected_vpc_ids for att in igw.get("Attachments", []))
        and not tag_has_pattern(igw.get("Tags", []))
    ]
    selected_route_tables = [
        rt for rt in route_tables.get("RouteTables", [])
        if rt.get("VpcId") in selected_vpc_ids and not tag_has_pattern(rt.get("Tags", []))
    ]
    selected_security_groups = [
        sg for sg in security_groups.get("SecurityGroups", [])
        if sg.get("VpcId") in selected_vpc_ids and sg.get("GroupName") != "default" and not tag_has_pattern(sg.get("Tags", []))
    ]
    selected_network_interfaces = [
        eni for eni in network_interfaces.get("NetworkInterfaces", [])
        if eni.get("VpcId") in selected_vpc_ids and not tag_has_pattern(eni.get("TagSet", []))
    ]

    selected_instances = []
    key_names = set()
    for reservation in instances.get("Reservations", []):
        for instance in reservation.get("Instances", []):
            if instance.get("VpcId") not in selected_vpc_ids:
                continue
            if tag_has_pattern(instance.get("Tags", [])):
                continue
            selected_instances.append(instance)
            if instance.get("KeyName"):
                key_names.add(instance["KeyName"])

    selected_key_pairs = [
        key for key in key_pairs.get("KeyPairs", [])
        if key.get("KeyName") in key_names and not tag_has_pattern(key.get("Tags", []))
    ]

    region_data.update({
        "vpcs": selected_vpcs,
        "subnets": selected_subnets,
        "internetGateways": selected_igws,
        "routeTables": selected_route_tables,
        "securityGroups": selected_security_groups,
        "networkInterfaces": selected_network_interfaces,
        "instances": selected_instances,
        "keyPairs": selected_key_pairs
    })
    inventory["regions"].append(region_data)

with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(inventory, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

delete_instances() {
    local region=$1
    local instance_ids
    local delete_ids=""

    instance_ids=$(aws ec2 describe-instances \
        --region "$region" \
        --filters "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text 2>/dev/null | words)

    if [ -z "$instance_ids" ]; then
        log "No EC2 instances found in ${region}"
        return 0
    fi

    for instance_id in $instance_ids; do
        if has_protected_tag "$region" "$instance_id"; then
            warn "Skipping EC2 instance with protected tag in ${region}: ${instance_id}"
            continue
        fi
        delete_ids="${delete_ids} ${instance_id}"
    done

    if [ -z "$(printf '%s' "$delete_ids" | words)" ]; then
        log "No unprotected EC2 instances found in ${region}"
        return 0
    fi

    log "Terminating EC2 instances in ${region}:${delete_ids}"
    run aws ec2 terminate-instances --region "$region" --instance-ids $delete_ids >/dev/null

    if [ "$CONFIRM" = true ]; then
        aws ec2 wait instance-terminated --region "$region" --instance-ids $delete_ids
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
        if key_pair_has_protected_tag "$region" "$key_name"; then
            warn "Skipping key pair with protected tag in ${region}: ${key_name}"
            continue
        fi
        log "Deleting key pair in ${region}: ${key_name}"
        run aws ec2 delete-key-pair --region "$region" --key-name "$key_name" >/dev/null
    done
}

delete_nat_gateways() {
    local region=$1
    local vpc_id=$2
    local nat_gateway_ids
    local delete_ids=""

    nat_gateway_ids=$(aws ec2 describe-nat-gateways \
        --region "$region" \
        --filter "Name=vpc-id,Values=${vpc_id}" "Name=state,Values=pending,available,failed" \
        --query 'NatGateways[].NatGatewayId' \
        --output text 2>/dev/null | words)

    for nat_gateway_id in $nat_gateway_ids; do
        if has_protected_tag "$region" "$nat_gateway_id"; then
            warn "Skipping NAT gateway with protected tag in ${region}: ${nat_gateway_id}"
            continue
        fi
        log "Deleting NAT gateway in ${region}: ${nat_gateway_id}"
        run aws ec2 delete-nat-gateway --region "$region" --nat-gateway-id "$nat_gateway_id" >/dev/null
        delete_ids="${delete_ids} ${nat_gateway_id}"
    done

    if [ -n "$(printf '%s' "$delete_ids" | words)" ] && [ "$CONFIRM" = true ]; then
        for nat_gateway_id in $delete_ids; do
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
        if has_protected_tag "$region" "$igw_id"; then
            warn "Skipping internet gateway with protected tag in ${region}: ${igw_id}"
            continue
        fi
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
        if has_protected_tag "$region" "$route_table_id"; then
            warn "Skipping route table with protected tag in ${region}: ${route_table_id}"
            continue
        fi
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

delete_network_interfaces() {
    local region=$1
    local vpc_id=$2
    local network_interface_ids

    network_interface_ids=$(aws ec2 describe-network-interfaces \
        --region "$region" \
        --filters "Name=vpc-id,Values=${vpc_id}" \
        --query 'NetworkInterfaces[].NetworkInterfaceId' \
        --output text 2>/dev/null | words)

    for network_interface_id in $network_interface_ids; do
        if has_protected_tag "$region" "$network_interface_id"; then
            warn "Skipping network interface with protected tag in ${region}: ${network_interface_id}"
            continue
        fi

        requester_managed=$(aws ec2 describe-network-interfaces \
            --region "$region" \
            --network-interface-ids "$network_interface_id" \
            --query 'NetworkInterfaces[0].RequesterManaged' \
            --output text 2>/dev/null || true)
        if [ "$requester_managed" = "True" ]; then
            warn "Skipping requester-managed network interface in ${region}: ${network_interface_id}"
            continue
        fi

        attachment_id=$(aws ec2 describe-network-interfaces \
            --region "$region" \
            --network-interface-ids "$network_interface_id" \
            --query 'NetworkInterfaces[0].Attachment.AttachmentId' \
            --output text 2>/dev/null || true)

        if [ -n "$attachment_id" ] && [ "$attachment_id" != "None" ]; then
            log "Detaching network interface in ${region}: ${network_interface_id}"
            run aws ec2 detach-network-interface --region "$region" --attachment-id "$attachment_id" --force >/dev/null || true
            if [ "$CONFIRM" = true ]; then
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

        log "Deleting network interface in ${region}: ${network_interface_id}"
        run aws ec2 delete-network-interface --region "$region" --network-interface-id "$network_interface_id" >/dev/null || true
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
        if has_protected_tag "$region" "$subnet_id"; then
            warn "Skipping subnet with protected tag in ${region}: ${subnet_id}"
            continue
        fi
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
        if has_protected_tag "$region" "$security_group_id"; then
            warn "Skipping security group with protected tag in ${region}: ${security_group_id}"
            continue
        fi
        log "Deleting security group in ${region}: ${security_group_id}"
        run aws ec2 delete-security-group --region "$region" --group-id "$security_group_id" >/dev/null || true
    done
}

delete_vpcs() {
    local region=$1
    local vpc_ids
    local query

    if [ "$INCLUDE_DEFAULT_VPCS" = true ]; then
        query='Vpcs[].VpcId'
    else
        query='Vpcs[?IsDefault==`false`].VpcId'
    fi

    vpc_ids=$(aws ec2 describe-vpcs \
        --region "$region" \
        --query "$query" \
        --output text 2>/dev/null | words)

    if [ -z "$vpc_ids" ]; then
        log "No matching VPCs found in ${region}"
        return 0
    fi

    for vpc_id in $vpc_ids; do
        if has_protected_tag "$region" "$vpc_id"; then
            warn "Skipping VPC with protected tag in ${region}: ${vpc_id}"
            continue
        fi
        log "Cleaning VPC in ${region}: ${vpc_id}"
        delete_nat_gateways "$region" "$vpc_id"
        delete_internet_gateways "$region" "$vpc_id"
        delete_route_tables "$region" "$vpc_id"
        delete_network_interfaces "$region" "$vpc_id"
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
        --include-default-vpcs)
            INCLUDE_DEFAULT_VPCS=true
            shift
            ;;
        --manifest-dir)
            MANIFEST_DIR=${2:?Missing manifest directory}
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
    warn "Dry-run mode. Add --confirm-delete to actually delete resources."
fi

if [ "$ALL_REGIONS" = true ]; then
    regions=$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text | words)
else
    regions=$REGION
fi

if [ "$CONFIRM" = true ]; then
    write_rollback_manifest
fi

for region in $regions; do
    log "Starting cleanup in ${region}"
    delete_instances "$region"
    delete_key_pairs "$region"
    delete_vpcs "$region"
done

log "Cleanup complete"
