#!/bin/bash

# ============================================
# AWS Infrastructure Auto-Deploy Script
# Creates: Key Pair, VPC, Subnet, Security Group, EC2 Instance
# With DYNAMIC AMI fetching!
# ============================================

# Colors for pretty output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration Variables
REGION="us-east-1"
VPC_NAME="my-aws-vpc"
VPC_CIDR="10.0.0.0/16"
SUBNET_NAME="my-public-subnet"
SUBNET_CIDR="10.0.1.0/24"
SECURITY_GROUP_NAME="my-ec2-security-group"
INSTANCE_NAME="my-ec2-instance"
INSTANCE_TYPE="t2.micro"
KEY_PAIR="my-aws-keypair"
KEY_FILE_PATH="$HOME/my-aws-keypair.pem"

# Print functions
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1" >&2
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" >&2
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" >&2
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

validate_aws_id() {
    local value=$1
    local pattern=$2
    local label=$3

    if [[ ! "$value" =~ $pattern ]]; then
        print_error "$label is invalid or empty: $value"
        exit 1
    fi
}

# Fetch latest Amazon Linux 2 AMI ID dynamically
fetch_latest_ami() {
    print_info "Fetching latest Amazon Linux 2 AMI ID..."
    AMI_ID=$(aws ec2 describe-images \
        --owners amazon \
        --filters "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" \
        --query "sort_by(Images, &CreationDate)[-1].ImageId" \
        --output text \
        --region $REGION)
    
    if [ -z "$AMI_ID" ]; then
        print_error "Could not find Amazon Linux 2 AMI!"
        exit 1
    fi
    print_success "Found AMI ID: $AMI_ID"
}

# Create Key Pair
create_key_pair() {
    print_info "Creating Key Pair: $KEY_PAIR..."
    
    # Check if key file already exists
    if [ -f "$KEY_FILE_PATH" ]; then
        print_warning "Key file already exists! Skipping key pair creation..."
        print_info "Using existing key: $KEY_FILE_PATH"
        return
    fi
    
    # Create key pair and save private key
    aws ec2 create-key-pair \
        --key-name $KEY_PAIR \
        --query 'KeyMaterial' \
        --output text \
        --region $REGION > "$KEY_FILE_PATH"
    
    if [ $? -eq 0 ]; then
        print_info "IMPORTANT: Keep this key file safe. You will need it to SSH into your instance."
        print_success "Key Pair created! Private key saved to: $KEY_FILE_PATH"
        
        # Set proper permissions (read-only for owner)
        chmod 400 "$KEY_FILE_PATH"
        print_success "Key permissions set (chmod 400)"
    else
        print_error "Failed to create Key Pair"
        exit 1
    fi
}

# Check AWS CLI
check_aws_cli() {
    print_info "Checking if AWS CLI is installed..."
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI is not installed!"
        exit 1
    fi
    print_success "AWS CLI found!"
}

# Check AWS credentials
check_aws_credentials() {
    print_info "Checking AWS credentials..."
    if ! aws sts get-caller-identity &> /dev/null; then
        print_error "AWS credentials not configured. Run 'aws configure' first!"
        exit 1
    fi
    print_success "AWS credentials are valid!"
}

# Create VPC
create_vpc() {
    print_info "Creating VPC: $VPC_NAME with CIDR $VPC_CIDR..."
    
    VPC_ID=$(aws ec2 create-vpc \
        --cidr-block $VPC_CIDR \
        --region $REGION \
        --query 'Vpc.VpcId' \
        --output text)
    
    # Clean the ID ONCE at the source
    VPC_ID=$(echo "$VPC_ID" | tr -d '\r\n')
    
    if [ $? -eq 0 ] && [ -n "$VPC_ID" ]; then
        print_success "VPC created! ID: $VPC_ID"
        validate_aws_id "$VPC_ID" '^vpc-[a-zA-Z0-9]+$' "VPC ID"
        aws ec2 create-tags --resources "$VPC_ID" --tags "Key=Name,Value=$VPC_NAME" --region $REGION >/dev/null
        
        # Enable DNS support
        aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support '{"Value": true}' --region $REGION >/dev/null
        aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value": true}' --region $REGION >/dev/null
        
        echo "$VPC_ID"
    else
        print_error "Failed to create VPC"
        exit 1
    fi
}

# Create Internet Gateway
create_internet_gateway() {
    local vpc_id=$1
    print_info "Creating Internet Gateway..."
    
    IGW_ID=$(aws ec2 create-internet-gateway --region $REGION --query 'InternetGateway.InternetGatewayId' --output text)
    IGW_ID=$(echo "$IGW_ID" | tr -d '\r\n')  # Clean once at source
    
    if [ $? -eq 0 ] && [ -n "$IGW_ID" ]; then
        print_success "Internet Gateway created! ID: $IGW_ID"
        validate_aws_id "$IGW_ID" '^igw-[a-zA-Z0-9]+$' "Internet Gateway ID"
        aws ec2 attach-internet-gateway --vpc-id "$vpc_id" --internet-gateway-id "$IGW_ID" --region $REGION >/dev/null
        echo "$IGW_ID"
    else
        print_error "Failed to create Internet Gateway"
        exit 1
    fi
}

# Create Subnet
create_subnet() {
    local vpc_id=$1
    print_info "Creating Subnet: $SUBNET_NAME with CIDR $SUBNET_CIDR..."
    
    SUBNET_ID=$(aws ec2 create-subnet \
        --vpc-id "$vpc_id" \
        --cidr-block $SUBNET_CIDR \
        --availability-zone "${REGION}a" \
        --region $REGION \
        --query 'Subnet.SubnetId' \
        --output text)
    SUBNET_ID=$(echo "$SUBNET_ID" | tr -d '\r\n')  # Clean once at source
    
    if [ $? -eq 0 ] && [ -n "$SUBNET_ID" ]; then
        print_success "Subnet created! ID: $SUBNET_ID"
        validate_aws_id "$SUBNET_ID" '^subnet-[a-zA-Z0-9]+$' "Subnet ID"
        aws ec2 create-tags --resources "$SUBNET_ID" --tags "Key=Name,Value=$SUBNET_NAME" --region $REGION >/dev/null
        echo "$SUBNET_ID"
    else
        print_error "Failed to create Subnet"
        exit 1
    fi
}

# Create Route Table
create_route_table() {
    local vpc_id=$1
    local subnet_id=$2
    local igw_id=$3
    
    print_info "Creating Route Table..."
    
    RT_ID=$(aws ec2 create-route-table --vpc-id "$vpc_id" --region $REGION --query 'RouteTable.RouteTableId' --output text)
    RT_ID=$(echo "$RT_ID" | tr -d '\r\n')  # Clean once at source
    
    if [ $? -eq 0 ] && [ -n "$RT_ID" ]; then
        print_success "Route Table created! ID: $RT_ID"
        validate_aws_id "$RT_ID" '^rtb-[a-zA-Z0-9]+$' "Route Table ID"
        
        # Add route to internet
        aws ec2 create-route \
            --route-table-id "$RT_ID" \
            --destination-cidr-block "0.0.0.0/0" \
            --gateway-id "$igw_id" \
            --region $REGION >/dev/null
        
        # Associate with subnet
        aws ec2 associate-route-table --route-table-id "$RT_ID" --subnet-id "$subnet_id" --region $REGION >/dev/null
        print_success "Public route configured!"
    else
        print_error "Failed to create Route Table"
        exit 1
    fi
}

# Create Security Group
create_security_group() {
    local vpc_id=$1
    print_info "Creating Security Group: $SECURITY_GROUP_NAME..."
    
    SG_ID=$(aws ec2 create-security-group \
        --group-name $SECURITY_GROUP_NAME \
        --description "Security group for EC2 instance" \
        --vpc-id "$vpc_id" \
        --region $REGION \
        --query 'GroupId' \
        --output text)
    SG_ID=$(echo "$SG_ID" | tr -d '\r\n')  # Clean once at source
    
    if [ $? -eq 0 ] && [ -n "$SG_ID" ]; then
        print_success "Security Group created! ID: $SG_ID"
        validate_aws_id "$SG_ID" '^sg-[a-zA-Z0-9]+$' "Security Group ID"
        aws ec2 create-tags --resources "$SG_ID" --tags "Key=Name,Value=$SECURITY_GROUP_NAME" --region $REGION >/dev/null
        
        # Allow SSH (port 22)
        aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0 --region $REGION >/dev/null || true
        
        # Allow HTTP (port 80)
        aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 80 --cidr 0.0.0.0/0 --region $REGION >/dev/null || true
        
        # Allow HTTPS (port 443)
        aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 443 --cidr 0.0.0.0/0 --region $REGION >/dev/null || true
        
        print_success "Security rules configured (SSH, HTTP, HTTPS). Default outbound rule left unchanged."
        echo "$SG_ID"
    else
        print_error "Failed to create Security Group"
        exit 1
    fi
}

# Create EC2 Instance
create_ec2_instance() {
    local subnet_id=$1
    local sg_id=$2
    
    print_info "Creating EC2 Instance: $INSTANCE_NAME..."
    validate_aws_id "$subnet_id" '^subnet-[a-zA-Z0-9]+$' "Subnet ID"
    validate_aws_id "$sg_id" '^sg-[a-zA-Z0-9]+$' "Security Group ID"
    
    INSTANCE_ID=$(aws ec2 run-instances \
        --image-id $AMI_ID \
        --count 1 \
        --instance-type $INSTANCE_TYPE \
        --key-name $KEY_PAIR \
        --network-interfaces "DeviceIndex=0,SubnetId=$subnet_id,Groups=[$sg_id],AssociatePublicIpAddress=true" \
        --region $REGION \
        --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value='$INSTANCE_NAME'}]' \
        --query 'Instances[0].InstanceId' \
        --output text)
    INSTANCE_ID=$(echo "$INSTANCE_ID" | tr -d '\r\n')  # Clean once at source
    
    if [ $? -eq 0 ] && [ -n "$INSTANCE_ID" ]; then
        print_success "EC2 Instance created! ID: $INSTANCE_ID"
        validate_aws_id "$INSTANCE_ID" '^i-[a-zA-Z0-9]+$' "Instance ID"
        
        # Wait for instance to be running
        print_info "Waiting for instance to be running..."
        aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region $REGION >/dev/null
        
        # Get public IP
        PUBLIC_IP=$(aws ec2 describe-instances \
            --instance-ids "$INSTANCE_ID" \
            --region $REGION \
            --query 'Reservations[0].Instances[0].PublicIpAddress' \
            --output text)
        PUBLIC_IP=$(echo "$PUBLIC_IP" | tr -d '\r\n')  # Clean once at source
        
        print_success "Instance is running!"
        print_info "Public IP: $PUBLIC_IP"
        
        echo "$INSTANCE_ID"
    else
        print_error "Failed to create EC2 Instance"
        exit 1
    fi
}

# Main execution
main() {
    echo ""
    echo "=========================================="
    echo "  AWS Infrastructure Auto-Deploy Script"
    echo "=========================================="
    echo ""
    
    # Prerequisites
    check_aws_cli
    check_aws_credentials
    
    # Create key pair (if it doesn't exist)
    create_key_pair
    
    # Fetch latest AMI
    fetch_latest_ami
    
    # Create resources (no need to clean - each function cleans its own output)
    VPC_ID=$(create_vpc)
    validate_aws_id "$VPC_ID" '^vpc-[a-zA-Z0-9]+$' "VPC ID"
    IGW_ID=$(create_internet_gateway "$VPC_ID")
    validate_aws_id "$IGW_ID" '^igw-[a-zA-Z0-9]+$' "Internet Gateway ID"
    SUBNET_ID=$(create_subnet "$VPC_ID")
    validate_aws_id "$SUBNET_ID" '^subnet-[a-zA-Z0-9]+$' "Subnet ID"
    create_route_table "$VPC_ID" "$SUBNET_ID" "$IGW_ID"
    SG_ID=$(create_security_group "$VPC_ID")
    validate_aws_id "$SG_ID" '^sg-[a-zA-Z0-9]+$' "Security Group ID"
    INSTANCE_ID=$(create_ec2_instance "$SUBNET_ID" "$SG_ID")
    validate_aws_id "$INSTANCE_ID" '^i-[a-zA-Z0-9]+$' "Instance ID"
    PUBLIC_IP=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --region $REGION \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text)
    PUBLIC_IP=$(echo "$PUBLIC_IP" | tr -d '\r\n')
    
    echo ""
    echo "=========================================="
    echo "  Deployment Complete!"
    echo "=========================================="
    echo "Created Resources:"
    echo "  VPC ID:          $VPC_ID"
    echo "  Subnet ID:       $SUBNET_ID"
    echo "  Security Group:  $SG_ID"
    echo "  EC2 Instance:    $INSTANCE_ID"
    echo ""
    echo "Key Pair: $KEY_PAIR"
    echo "Key File: $KEY_FILE_PATH"
    echo ""
    echo "Public IP: $PUBLIC_IP"
    echo ""
    echo "=========================================="
    echo "  SSH into your instance with:"
    echo "=========================================="
    echo ""
    echo "  ssh -i $KEY_FILE_PATH ec2-user@$PUBLIC_IP"
    echo ""
    print_success "Your infrastructure is ready."
    echo ""
}

# Run main
main
