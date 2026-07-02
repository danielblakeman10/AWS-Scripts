# AWS Scripts

Small Bash utilities for AWS CLI learning labs.

## Scripts

- `aws-auto-deploy.sh` creates a basic EC2 lab stack in `us-east-1`: VPC, public subnet, route table, internet gateway, security group, key pair, and EC2 instance.
- `delete-my-aws-vpcs.sh` deletes VPCs tagged `Name=my-aws-vpc` and common dependencies such as EC2 instances, NAT gateways, internet gateways, subnets, route tables, and non-default security groups.

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

## Requirements

- AWS CLI installed
- AWS credentials configured
- IAM permissions for EC2/VPC resource creation and deletion

## Notes

These scripts are for lab environments. Review security group rules and deletion behavior before using them in any shared or production AWS account.
