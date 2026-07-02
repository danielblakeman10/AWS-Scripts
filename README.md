# AWS Scripts

Small Bash utilities for AWS CLI learning labs.

## Scripts

- `aws-scripts/aws-auto-deploy.sh` creates a basic EC2 lab stack in `us-east-1`: VPC, public subnet, route table, internet gateway, security group, key pair, and EC2 instance.
- `aws-scripts/delete-my-aws-vpcs.sh` deletes VPCs tagged `Name=my-aws-vpc` and common dependencies such as EC2 instances, NAT gateways, internet gateways, subnets, route tables, and non-default security groups.
- `aws-scripts/nuke-aws-lab-resources.sh` scans enabled regions and deletes EC2 instances, EC2 key pairs, network interfaces, VPC dependencies, and VPCs. It defaults to dry-run, skips any resource with a tag key or value containing `roc`, preserves default VPCs unless `--include-default-vpcs` is passed, and requires `--confirm-delete` before making changes.
- `aws-scripts/rollback-aws-lab-resources.sh` recreates EC2/VPC lab infrastructure from a rollback manifest written by `aws-scripts/nuke-aws-lab-resources.sh`.

## Usage

Validate syntax without running commands:

```bash
bash -n aws-scripts/aws-auto-deploy.sh
bash -n aws-scripts/delete-my-aws-vpcs.sh
```

Run the deploy script:

```bash
chmod +x aws-scripts/aws-auto-deploy.sh
./aws-scripts/aws-auto-deploy.sh
```

Dry-run the cleanup script first:

```bash
chmod +x aws-scripts/delete-my-aws-vpcs.sh
./aws-scripts/delete-my-aws-vpcs.sh --dry-run
```

Delete matching VPCs in the default region:

```bash
./aws-scripts/delete-my-aws-vpcs.sh
```

Preview broad EC2/VPC cleanup across all enabled regions:

```bash
chmod +x aws-scripts/nuke-aws-lab-resources.sh
./aws-scripts/nuke-aws-lab-resources.sh
```

Actually delete broad EC2/VPC lab resources:

```bash
./aws-scripts/nuke-aws-lab-resources.sh --confirm-delete
```

When confirmed deletion runs, the script writes a rollback manifest under:

```bash
./rollback-manifests/
```

The broad cleanup script always skips resources with tag keys or values containing `roc`, case-insensitive. A protected VPC causes the script to skip that VPC cleanup path.

Actually delete all matching EC2/VPC resources, including default VPCs:

```bash
./aws-scripts/nuke-aws-lab-resources.sh --include-default-vpcs --confirm-delete
```

Limit broad cleanup to one region:

```bash
./aws-scripts/nuke-aws-lab-resources.sh --region us-east-1 --confirm-delete
```

Preview rollback from a manifest:

```bash
chmod +x aws-scripts/rollback-aws-lab-resources.sh
./aws-scripts/rollback-aws-lab-resources.sh --manifest ./rollback-manifests/aws-cleanup-inventory-YYYYMMDDTHHMMSSZ.json
```

Actually run rollback:

```bash
./aws-scripts/rollback-aws-lab-resources.sh \
  --manifest ./rollback-manifests/aws-cleanup-inventory-YYYYMMDDTHHMMSSZ.json \
  --confirm-restore
```

## Requirements

- AWS CLI installed
- AWS credentials configured
- IAM permissions for EC2/VPC resource creation and deletion

## Notes

These scripts are for lab environments. Review security group rules and deletion behavior before using them in any shared or production AWS account.

Rollback has limits: original AWS resource IDs cannot be restored, terminated EC2 disks/data cannot be restored unless separately backed up, EC2 instances are relaunched from captured configuration when possible, attached/requester-managed network interfaces are not directly recreated, and key pairs are restored only when public key material is available in the manifest.
