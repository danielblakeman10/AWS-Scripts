# AWS Scripts

Small Bash utilities for AWS CLI learning labs.

## Scripts

- `aws-auto-deploy.sh` creates a basic EC2 lab stack in `us-east-1`: VPC, public subnet, route table, internet gateway, security group, key pair, and EC2 instance.
- `delete-my-aws-vpcs.sh` deletes VPCs tagged `Name=my-aws-vpc` and common dependencies such as EC2 instances, NAT gateways, internet gateways, subnets, route tables, and non-default security groups.
- `nuke-aws-lab-resources.sh` scans enabled regions and deletes EC2 instances, EC2 key pairs, VPC dependencies, and VPCs. It defaults to dry-run, preserves default VPCs unless `--include-default-vpcs` is passed, and requires `--confirm-delete` before making changes.

## Usage

Validate syntax without running commands:

```bash
bash -n aws-auto-deploy.sh
bash -n delete-my-aws-vpcs.sh
```

Run the deploy script:

```bash
chmod +x aws-auto-deploy.sh
./aws-auto-deploy.sh
```

Dry-run the cleanup script first:

```bash
chmod +x delete-my-aws-vpcs.sh
./delete-my-aws-vpcs.sh --dry-run
```

Delete matching VPCs in the default region:

```bash
./delete-my-aws-vpcs.sh
```

Preview broad EC2/VPC cleanup across all enabled regions:

```bash
chmod +x nuke-aws-lab-resources.sh
./nuke-aws-lab-resources.sh
```

Actually delete broad EC2/VPC lab resources:

```bash
./nuke-aws-lab-resources.sh --confirm-delete
```

Actually delete all matching EC2/VPC resources, including default VPCs:

```bash
./nuke-aws-lab-resources.sh --include-default-vpcs --confirm-delete
```

Limit broad cleanup to one region:

```bash
./nuke-aws-lab-resources.sh --region us-east-1 --confirm-delete
```

## Requirements

- AWS CLI installed
- AWS credentials configured
- IAM permissions for EC2/VPC resource creation and deletion

## Notes

These scripts are for lab environments. Review security group rules and deletion behavior before using them in any shared or production AWS account.
