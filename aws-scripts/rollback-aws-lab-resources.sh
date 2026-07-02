#!/usr/bin/env bash

set -u
set -o pipefail

CONFIRM=false
MANIFEST=""

usage() {
    cat <<EOF
Usage: ./rollback-aws-lab-resources.sh --manifest FILE [options]

Restores AWS EC2/VPC lab infrastructure from a manifest created by
nuke-aws-lab-resources.sh.

Default mode is dry-run. Nothing is created unless --confirm-restore is passed.

Options:
  --manifest FILE      Rollback manifest JSON file.
  --confirm-restore    Actually recreate resources.
  -h, --help           Show this help.

Limitations:
  - Original AWS resource IDs cannot be restored.
  - Terminated EC2 instance disks/data cannot be restored unless separately backed up.
  - EC2 instances are relaunched from their original AMI, instance type, subnet, key name,
    security groups, and tags when possible.
  - Key pairs are restored only when the manifest contains public key material.
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
    printf '[WARN] Dry-run mode. Add --confirm-restore to actually recreate resources.\n' >&2
fi

python3 - "$MANIFEST" "$CONFIRM" <<'PY'
import json
import subprocess
import sys

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

def tag_specs(resource_type, tags):
    clean_tags = [
        {"Key": str(tag.get("Key", "")), "Value": str(tag.get("Value", ""))}
        for tag in tags or []
        if tag.get("Key")
    ]
    if not clean_tags:
        return []
    return ["--tag-specifications", f"ResourceType={resource_type},Tags={json.dumps(clean_tags, separators=(',', ':'))}"]

def create_tags(region, resource_id, tags):
    clean_tags = [
        {"Key": str(tag.get("Key", "")), "Value": str(tag.get("Value", ""))}
        for tag in tags or []
        if tag.get("Key")
    ]
    if not clean_tags:
        return
    aws([
        "ec2", "create-tags",
        "--region", region,
        "--resources", resource_id,
        "--tags", *[f"Key={tag['Key']},Value={tag['Value']}" for tag in clean_tags],
        "--output", "json"
    ], allow_fail=True)

def convert_permissions(permissions, sg_map):
    converted = []
    for perm in permissions or []:
        item = {}
        for key in ("IpProtocol", "FromPort", "ToPort"):
            if key in perm and perm[key] is not None:
                item[key] = perm[key]
        if perm.get("IpRanges"):
            item["IpRanges"] = [
                {k: v for k, v in ip_range.items() if k in ("CidrIp", "Description")}
                for ip_range in perm["IpRanges"]
            ]
        if perm.get("Ipv6Ranges"):
            item["Ipv6Ranges"] = [
                {k: v for k, v in ip_range.items() if k in ("CidrIpv6", "Description")}
                for ip_range in perm["Ipv6Ranges"]
            ]
        if perm.get("PrefixListIds"):
            item["PrefixListIds"] = [
                {k: v for k, v in prefix.items() if k in ("PrefixListId", "Description")}
                for prefix in perm["PrefixListIds"]
            ]
        pairs = []
        for pair in perm.get("UserIdGroupPairs", []):
            old_group_id = pair.get("GroupId")
            new_group_id = sg_map.get(old_group_id)
            if new_group_id:
                pairs.append({"GroupId": new_group_id})
        if pairs:
            item["UserIdGroupPairs"] = pairs
        converted.append(item)
    return converted

for region_data in manifest.get("regions", []):
    region = region_data["region"]
    log(f"Restoring region {region}")

    vpc_map = {}
    subnet_map = {}
    igw_map = {}
    route_table_map = {}
    sg_map = {}

    for vpc in region_data.get("vpcs", []):
        cidr = vpc.get("CidrBlock")
        if not cidr:
            warn(f"Skipping VPC without CidrBlock: {vpc.get('VpcId')}")
            continue
        result = aws(["ec2", "create-vpc", "--region", region, "--cidr-block", cidr, "--output", "json"])
        new_vpc_id = result["Vpc"]["VpcId"] if result else f"dry-run-{vpc['VpcId']}"
        vpc_map[vpc["VpcId"]] = new_vpc_id
        create_tags(region, new_vpc_id, vpc.get("Tags", []))

    for subnet in region_data.get("subnets", []):
        new_vpc_id = vpc_map.get(subnet.get("VpcId"))
        if not new_vpc_id:
            warn(f"Skipping subnet because VPC was not restored: {subnet.get('SubnetId')}")
            continue
        args = [
            "ec2", "create-subnet",
            "--region", region,
            "--vpc-id", new_vpc_id,
            "--cidr-block", subnet["CidrBlock"],
            "--availability-zone", subnet["AvailabilityZone"],
            "--output", "json",
        ]
        result = aws(args)
        new_subnet_id = result["Subnet"]["SubnetId"] if result else f"dry-run-{subnet['SubnetId']}"
        subnet_map[subnet["SubnetId"]] = new_subnet_id
        create_tags(region, new_subnet_id, subnet.get("Tags", []))

    for igw in region_data.get("internetGateways", []):
        result = aws(["ec2", "create-internet-gateway", "--region", region, "--output", "json"])
        new_igw_id = result["InternetGateway"]["InternetGatewayId"] if result else f"dry-run-{igw['InternetGatewayId']}"
        igw_map[igw["InternetGatewayId"]] = new_igw_id
        create_tags(region, new_igw_id, igw.get("Tags", []))
        for attachment in igw.get("Attachments", []):
            new_vpc_id = vpc_map.get(attachment.get("VpcId"))
            if new_vpc_id:
                aws([
                    "ec2", "attach-internet-gateway",
                    "--region", region,
                    "--internet-gateway-id", new_igw_id,
                    "--vpc-id", new_vpc_id,
                    "--output", "json"
                ], allow_fail=True)

    for sg in region_data.get("securityGroups", []):
        new_vpc_id = vpc_map.get(sg.get("VpcId"))
        if not new_vpc_id:
            warn(f"Skipping security group because VPC was not restored: {sg.get('GroupId')}")
            continue
        result = aws([
            "ec2", "create-security-group",
            "--region", region,
            "--group-name", sg["GroupName"],
            "--description", sg.get("Description", "Restored security group"),
            "--vpc-id", new_vpc_id,
            "--output", "json"
        ])
        new_group_id = result["GroupId"] if result else f"dry-run-{sg['GroupId']}"
        sg_map[sg["GroupId"]] = new_group_id
        create_tags(region, new_group_id, sg.get("Tags", []))

    for sg in region_data.get("securityGroups", []):
        new_group_id = sg_map.get(sg.get("GroupId"))
        if not new_group_id:
            continue
        ingress = convert_permissions(sg.get("IpPermissions", []), sg_map)
        egress = convert_permissions(sg.get("IpPermissionsEgress", []), sg_map)
        if ingress:
            aws([
                "ec2", "authorize-security-group-ingress",
                "--region", region,
                "--group-id", new_group_id,
                "--ip-permissions", json.dumps(ingress),
                "--output", "json"
            ], allow_fail=True)
        if egress:
            aws([
                "ec2", "authorize-security-group-egress",
                "--region", region,
                "--group-id", new_group_id,
                "--ip-permissions", json.dumps(egress),
                "--output", "json"
            ], allow_fail=True)

    for route_table in region_data.get("routeTables", []):
        is_main = any(assoc.get("Main") for assoc in route_table.get("Associations", []))
        if is_main:
            continue
        new_vpc_id = vpc_map.get(route_table.get("VpcId"))
        if not new_vpc_id:
            continue
        result = aws(["ec2", "create-route-table", "--region", region, "--vpc-id", new_vpc_id, "--output", "json"])
        new_route_table_id = result["RouteTable"]["RouteTableId"] if result else f"dry-run-{route_table['RouteTableId']}"
        route_table_map[route_table["RouteTableId"]] = new_route_table_id
        create_tags(region, new_route_table_id, route_table.get("Tags", []))
        for assoc in route_table.get("Associations", []):
            old_subnet_id = assoc.get("SubnetId")
            new_subnet_id = subnet_map.get(old_subnet_id)
            if new_subnet_id:
                aws([
                    "ec2", "associate-route-table",
                    "--region", region,
                    "--route-table-id", new_route_table_id,
                    "--subnet-id", new_subnet_id,
                    "--output", "json"
                ], allow_fail=True)
        for route in route_table.get("Routes", []):
            if route.get("GatewayId") == "local":
                continue
            destination_args = []
            for src, flag in (
                ("DestinationCidrBlock", "--destination-cidr-block"),
                ("DestinationIpv6CidrBlock", "--destination-ipv6-cidr-block"),
                ("DestinationPrefixListId", "--destination-prefix-list-id"),
            ):
                if route.get(src):
                    destination_args = [flag, route[src]]
                    break
            if not destination_args:
                continue
            target_args = []
            if route.get("GatewayId") in igw_map:
                target_args = ["--gateway-id", igw_map[route["GatewayId"]]]
            if not target_args:
                warn(f"Skipping unsupported route target in {route_table.get('RouteTableId')}: {route}")
                continue
            aws([
                "ec2", "create-route",
                "--region", region,
                "--route-table-id", new_route_table_id,
                *destination_args,
                *target_args,
                "--output", "json"
            ], allow_fail=True)

    for key_pair in region_data.get("keyPairs", []):
        public_key = key_pair.get("PublicKey")
        if not public_key:
            warn(f"Skipping key pair without public key material: {key_pair.get('KeyName')}")
            continue
        aws([
            "ec2", "import-key-pair",
            "--region", region,
            "--key-name", key_pair["KeyName"],
            "--public-key-material", public_key,
            "--output", "json"
        ], allow_fail=True)

    for instance in region_data.get("instances", []):
        old_subnet_id = instance.get("SubnetId")
        new_subnet_id = subnet_map.get(old_subnet_id)
        if not new_subnet_id:
            warn(f"Skipping instance because subnet was not restored: {instance.get('InstanceId')}")
            continue
        security_group_ids = [
            sg_map[group["GroupId"]]
            for group in instance.get("SecurityGroups", [])
            if group.get("GroupId") in sg_map
        ]
        if not security_group_ids:
            warn(f"Skipping instance because no security groups were restored: {instance.get('InstanceId')}")
            continue
        args = [
            "ec2", "run-instances",
            "--region", region,
            "--image-id", instance["ImageId"],
            "--instance-type", instance["InstanceType"],
            "--subnet-id", new_subnet_id,
            "--security-group-ids", *security_group_ids,
            "--count", "1",
            "--output", "json",
        ]
        if instance.get("KeyName"):
            args.extend(["--key-name", instance["KeyName"]])
        args.extend(tag_specs("instance", instance.get("Tags", [])))
        aws(args, allow_fail=True)

log("Rollback restore pass complete")
PY
