#!/usr/bin/env bash

set -uo pipefail

REGION="us-west-2"
export AWS_DEFAULT_REGION="$REGION"

echo "============================================================"
echo "        AWS FORCE CLEANUP - $REGION"
echo "============================================================"
echo
echo "WARNING:"
echo "This script will DELETE resources in $REGION."
echo
echo "It may delete:"
echo "  - EC2 instances"
echo "  - EBS volumes and snapshots"
echo "  - EKS clusters/nodegroups"
echo "  - ALB/NLB"
echo "  - RDS databases"
echo "  - VPCs/subnets/routes/IGWs/NAT/VPC endpoints"
echo "  - ECR repositories"
echo "  - ECS clusters/services"
echo "  - Lambda functions"
echo "  - EFS filesystems"
echo "  - CloudWatch log groups"
echo "  - Auto Scaling groups"
echo "  - Elastic IPs"
echo "  - CloudFormation stacks"
echo
echo "It will NOT delete resources in other AWS regions."
echo

ACCOUNT_ID=$(aws sts get-caller-identity \
  --query Account \
  --output text 2>/dev/null || true)

if [[ -z "$ACCOUNT_ID" || "$ACCOUNT_ID" == "None" ]]; then
    echo "ERROR: AWS credentials are not working."
    exit 1
fi

echo "AWS Account : $ACCOUNT_ID"
echo "AWS Region  : $REGION"
echo

read -rp "Type DELETE-$REGION to continue: " CONFIRM

if [[ "$CONFIRM" != "DELETE-$REGION" ]]; then
    echo
    echo "Cleanup cancelled."
    exit 0
fi

echo
echo "Starting cleanup..."
echo

# ------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------

delete_list() {
    local description="$1"
    shift

    echo
    echo ">>> $description"

    if [[ $# -eq 0 ]]; then
        echo "Nothing found."
        return
    fi

    for item in "$@"; do
        [[ -z "$item" || "$item" == "None" ]] && continue
        echo "Deleting: $item"
        "$@" >/dev/null 2>&1 || true
    done
}

# ------------------------------------------------------------
# 1. CloudFormation stacks
# ------------------------------------------------------------

echo "============================================================"
echo "1. CLOUDFORMATION STACKS"
echo "============================================================"

STACKS=$(aws cloudformation list-stacks \
    --region "$REGION" \
    --stack-status-filter \
    CREATE_IN_PROGRESS CREATE_COMPLETE \
    ROLLBACK_IN_PROGRESS ROLLBACK_FAILED \
    ROLLBACK_COMPLETE DELETE_FAILED \
    UPDATE_IN_PROGRESS UPDATE_COMPLETE \
    UPDATE_ROLLBACK_IN_PROGRESS UPDATE_ROLLBACK_FAILED \
    UPDATE_ROLLBACK_COMPLETE \
    --query 'StackSummaries[].StackName' \
    --output text 2>/dev/null || true)

for STACK in $STACKS; do
    echo "Deleting CloudFormation stack: $STACK"
    aws cloudformation delete-stack \
        --region "$REGION" \
        --stack-name "$STACK" || true
done

# ------------------------------------------------------------
# 2. EKS
# ------------------------------------------------------------

echo
echo "============================================================"
echo "2. EKS"
echo "============================================================"

EKS_CLUSTERS=$(aws eks list-clusters \
    --region "$REGION" \
    --query 'clusters[]' \
    --output text 2>/dev/null || true)

for CLUSTER in $EKS_CLUSTERS; do

    echo
    echo "EKS Cluster: $CLUSTER"

    # Fargate profiles
    PROFILES=$(aws eks list-fargate-profiles \
        --region "$REGION" \
        --cluster-name "$CLUSTER" \
        --query 'fargateProfileNames[]' \
        --output text 2>/dev/null || true)

    for PROFILE in $PROFILES; do
        echo "Deleting Fargate profile: $PROFILE"

        aws eks delete-fargate-profile \
            --region "$REGION" \
            --cluster-name "$CLUSTER" \
            --fargate-profile-name "$PROFILE" || true

        aws eks wait fargate-profile-deleted \
            --region "$REGION" \
            --cluster-name "$CLUSTER" \
            --fargate-profile-name "$PROFILE" 2>/dev/null || true
    done

    # Managed nodegroups
    NODEGROUPS=$(aws eks list-nodegroups \
        --region "$REGION" \
        --cluster-name "$CLUSTER" \
        --query 'nodegroups[]' \
        --output text 2>/dev/null || true)

    for NG in $NODEGROUPS; do
        echo "Deleting EKS nodegroup: $NG"

        aws eks delete-nodegroup \
            --region "$REGION" \
            --cluster-name "$CLUSTER" \
            --nodegroup-name "$NG" || true

        aws eks wait nodegroup-deleted \
            --region "$REGION" \
            --cluster-name "$CLUSTER" \
            --nodegroup-name "$NG" 2>/dev/null || true
    done

    # Addons
    ADDONS=$(aws eks list-addons \
        --region "$REGION" \
        --cluster-name "$CLUSTER" \
        --query 'addons[]' \
        --output text 2>/dev/null || true)

    for ADDON in $ADDONS; do
        echo "Deleting EKS addon: $ADDON"

        aws eks delete-addon \
            --region "$REGION" \
            --cluster-name "$CLUSTER" \
            --addon-name "$ADDON" || true
    done

    echo "Deleting EKS cluster: $CLUSTER"

    aws eks delete-cluster \
        --region "$REGION" \
        --name "$CLUSTER" || true

    aws eks wait cluster-deleted \
        --region "$REGION" \
        --name "$CLUSTER" 2>/dev/null || true
done

# ------------------------------------------------------------
# 3. ECS
# ------------------------------------------------------------

echo
echo "============================================================"
echo "3. ECS"
echo "============================================================"

ECS_CLUSTERS=$(aws ecs list-clusters \
    --region "$REGION" \
    --query 'clusterArns[]' \
    --output text 2>/dev/null || true)

for CLUSTER in $ECS_CLUSTERS; do

    echo "ECS Cluster: $CLUSTER"

    SERVICES=$(aws ecs list-services \
        --region "$REGION" \
        --cluster "$CLUSTER" \
        --query 'serviceArns[]' \
        --output text 2>/dev/null || true)

    for SERVICE in $SERVICES; do
        echo "Deleting ECS service: $SERVICE"

        aws ecs update-service \
            --region "$REGION" \
            --cluster "$CLUSTER" \
            --service "$SERVICE" \
            --desired-count 0 >/dev/null 2>&1 || true

        aws ecs delete-service \
            --region "$REGION" \
            --cluster "$CLUSTER" \
            --service "$SERVICE" \
            --force || true
    done

    echo "Deleting ECS cluster: $CLUSTER"

    aws ecs delete-cluster \
        --region "$REGION" \
        --cluster "$CLUSTER" || true
done

# ------------------------------------------------------------
# 4. Load Balancers
# ------------------------------------------------------------

echo
echo "============================================================"
echo "4. ALB / NLB"
echo "============================================================"

LB_ARNS=$(aws elbv2 describe-load-balancers \
    --region "$REGION" \
    --query 'LoadBalancers[].LoadBalancerArn' \
    --output text 2>/dev/null || true)

for LB in $LB_ARNS; do
    echo "Deleting load balancer: $LB"

    aws elbv2 delete-load-balancer \
        --region "$REGION" \
        --load-balancer-arn "$LB" || true
done

# ------------------------------------------------------------
# 5. RDS Instances
# ------------------------------------------------------------

echo
echo "============================================================"
echo "5. RDS"
echo "============================================================"

RDS_INSTANCES=$(aws rds describe-db-instances \
    --region "$REGION" \
    --query 'DBInstances[].DBInstanceIdentifier' \
    --output text 2>/dev/null || true)

for DB in $RDS_INSTANCES; do
    echo "Deleting RDS instance: $DB"

    aws rds delete-db-instance \
        --region "$REGION" \
        --db-instance-identifier "$DB" \
        --skip-final-snapshot \
        --delete-automated-backups || true
done

RDS_CLUSTERS=$(aws rds describe-db-clusters \
    --region "$REGION" \
    --query 'DBClusters[].DBClusterIdentifier' \
    --output text 2>/dev/null || true)

for DB in $RDS_CLUSTERS; do
    echo "Deleting RDS cluster: $DB"

    aws rds delete-db-cluster \
        --region "$REGION" \
        --db-cluster-identifier "$DB" \
        --skip-final-snapshot || true
done

# ------------------------------------------------------------
# 6. Lambda
# ------------------------------------------------------------

echo
echo "============================================================"
echo "6. LAMBDA"
echo "============================================================"

LAMBDAS=$(aws lambda list-functions \
    --region "$REGION" \
    --query 'Functions[].FunctionName' \
    --output text 2>/dev/null || true)

for FUNCTION in $LAMBDAS; do
    echo "Deleting Lambda: $FUNCTION"

    aws lambda delete-function \
        --region "$REGION" \
        --function-name "$FUNCTION" || true
done

# ------------------------------------------------------------
# 7. EFS
# ------------------------------------------------------------

echo
echo "============================================================"
echo "7. EFS"
echo "============================================================"

EFS_FILESYSTEMS=$(aws efs describe-file-systems \
    --region "$REGION" \
    --query 'FileSystems[].FileSystemId' \
    --output text 2>/dev/null || true)

for FS in $EFS_FILESYSTEMS; do

    echo "EFS filesystem: $FS"

    MOUNTS=$(aws efs describe-mount-targets \
        --region "$REGION" \
        --file-system-id "$FS" \
        --query 'MountTargets[].MountTargetId' \
        --output text 2>/dev/null || true)

    for MT in $MOUNTS; do
        echo "Deleting EFS mount target: $MT"

        aws efs delete-mount-target \
            --region "$REGION" \
            --mount-target-id "$MT" || true
    done

    echo "Deleting EFS filesystem: $FS"

    # Give mount target deletion a little time
    sleep 5

    aws efs delete-file-system \
        --region "$REGION" \
        --file-system-id "$FS" || true
done

# ------------------------------------------------------------
# 8. Auto Scaling Groups
# ------------------------------------------------------------

echo
echo "============================================================"
echo "8. AUTO SCALING GROUPS"
echo "============================================================"

ASGS=$(aws autoscaling describe-auto-scaling-groups \
    --region "$REGION" \
    --query 'AutoScalingGroups[].AutoScalingGroupName' \
    --output text 2>/dev/null || true)

for ASG in $ASGS; do
    echo "Deleting ASG: $ASG"

    aws autoscaling update-auto-scaling-group \
        --region "$REGION" \
        --auto-scaling-group-name "$ASG" \
        --min-size 0 \
        --max-size 0 \
        --desired-capacity 0 || true

    aws autoscaling delete-auto-scaling-group \
        --region "$REGION" \
        --auto-scaling-group-name "$ASG" \
        --force-delete || true
done

# ------------------------------------------------------------
# 9. EC2 instances
# ------------------------------------------------------------

echo
echo "============================================================"
echo "9. EC2 INSTANCES"
echo "============================================================"

INSTANCES=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters \
        Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text 2>/dev/null || true)

if [[ -n "$INSTANCES" ]]; then
    echo "Terminating:"
    echo "$INSTANCES"

    aws ec2 terminate-instances \
        --region "$REGION" \
        --instance-ids $INSTANCES || true

    aws ec2 wait instance-terminated \
        --region "$REGION" \
        --instance-ids $INSTANCES 2>/dev/null || true
else
    echo "No EC2 instances found."
fi

# ------------------------------------------------------------
# 10. EBS volumes
# ------------------------------------------------------------

echo
echo "============================================================"
echo "10. EBS VOLUMES"
echo "============================================================"

VOLUMES=$(aws ec2 describe-volumes \
    --region "$REGION" \
    --query 'Volumes[].VolumeId' \
    --output text 2>/dev/null || true)

for VOL in $VOLUMES; do
    echo "Deleting EBS volume: $VOL"

    aws ec2 delete-volume \
        --region "$REGION" \
        --volume-id "$VOL" || true
done

# ------------------------------------------------------------
# 11. EBS snapshots
# ------------------------------------------------------------

echo
echo "============================================================"
echo "11. EBS SNAPSHOTS"
echo "============================================================"

SNAPSHOTS=$(aws ec2 describe-snapshots \
    --region "$REGION" \
    --owner-ids self \
    --query 'Snapshots[].SnapshotId' \
    --output text 2>/dev/null || true)

for SNAP in $SNAPSHOTS; do
    echo "Deleting snapshot: $SNAP"

    aws ec2 delete-snapshot \
        --region "$REGION" \
        --snapshot-id "$SNAP" || true
done

# ------------------------------------------------------------
# 12. AMIs
# ------------------------------------------------------------

echo
echo "============================================================"
echo "12. OWNED AMIs"
echo "============================================================"

AMIS=$(aws ec2 describe-images \
    --region "$REGION" \
    --owners self \
    --query 'Images[].ImageId' \
    --output text 2>/dev/null || true)

for AMI in $AMIS; do
    echo "Deregistering AMI: $AMI"

    aws ec2 deregister-image \
        --region "$REGION" \
        --image-id "$AMI" || true
done

# ------------------------------------------------------------
# 13. Elastic IPs
# ------------------------------------------------------------

echo
echo "============================================================"
echo "13. ELASTIC IPs"
echo "============================================================"

ALLOCATIONS=$(aws ec2 describe-addresses \
    --region "$REGION" \
    --query 'Addresses[].AllocationId' \
    --output text 2>/dev/null || true)

for ALLOC in $ALLOCATIONS; do
    echo "Releasing Elastic IP: $ALLOC"

    aws ec2 release-address \
        --region "$REGION" \
        --allocation-id "$ALLOC" || true
done

# ------------------------------------------------------------
# 14. ECR
# ------------------------------------------------------------

echo
echo "============================================================"
echo "14. ECR"
echo "============================================================"

ECR_REPOS=$(aws ecr describe-repositories \
    --region "$REGION" \
    --query 'repositories[].repositoryName' \
    --output text 2>/dev/null || true)

for REPO in $ECR_REPOS; do
    echo "Deleting ECR repository: $REPO"

    aws ecr delete-repository \
        --region "$REGION" \
        --repository-name "$REPO" \
        --force || true
done

# ------------------------------------------------------------
# 15. VPC Endpoints
# ------------------------------------------------------------

echo
echo "============================================================"
echo "15. VPC ENDPOINTS"
echo "============================================================"

ENDPOINTS=$(aws ec2 describe-vpc-endpoints \
    --region "$REGION" \
    --query 'VpcEndpoints[].VpcEndpointId' \
    --output text 2>/dev/null || true)

for EP in $ENDPOINTS; do
    echo "Deleting VPC endpoint: $EP"

    aws ec2 delete-vpc-endpoints \
        --region "$REGION" \
        --vpc-endpoint-ids "$EP" || true
done

# ------------------------------------------------------------
# 16. NAT Gateways
# ------------------------------------------------------------

echo
echo "============================================================"
echo "16. NAT GATEWAYS"
echo "============================================================"

NATS=$(aws ec2 describe-nat-gateways \
    --region "$REGION" \
    --filter Name=state,Values=available,pending,deleting \
    --query 'NatGateways[].NatGatewayId' \
    --output text 2>/dev/null || true)

for NAT in $NATS; do
    echo "Deleting NAT gateway: $NAT"

    aws ec2 delete-nat-gateway \
        --region "$REGION" \
        --nat-gateway-id "$NAT" || true
done

# Give NAT gateways time to disappear
sleep 10

# ------------------------------------------------------------
# 17. Internet Gateways
# ------------------------------------------------------------

echo
echo "============================================================"
echo "17. INTERNET GATEWAYS"
echo "============================================================"

IGWS=$(aws ec2 describe-internet-gateways \
    --region "$REGION" \
    --query 'InternetGateways[].InternetGatewayId' \
    --output text 2>/dev/null || true)

for IGW in $IGWS; do

    VPC=$(aws ec2 describe-internet-gateways \
        --region "$REGION" \
        --internet-gateway-ids "$IGW" \
        --query 'InternetGateways[0].Attachments[0].VpcId' \
        --output text 2>/dev/null || true)

    if [[ "$VPC" != "None" && -n "$VPC" ]]; then
        echo "Detaching $IGW from $VPC"

        aws ec2 detach-internet-gateway \
            --region "$REGION" \
            --internet-gateway-id "$IGW" \
            --vpc-id "$VPC" || true
    fi

    echo "Deleting Internet Gateway: $IGW"

    aws ec2 delete-internet-gateway \
        --region "$REGION" \
        --internet-gateway-id "$IGW" || true
done

# ------------------------------------------------------------
# 18. Network Interfaces
# ------------------------------------------------------------

echo
echo "============================================================"
echo "18. NETWORK INTERFACES"
echo "============================================================"

for ATTEMPT in {1..5}; do

    ENIS=$(aws ec2 describe-network-interfaces \
        --region "$REGION" \
        --query 'NetworkInterfaces[].NetworkInterfaceId' \
        --output text 2>/dev/null || true)

    if [[ -z "$ENIS" ]]; then
        echo "No network interfaces remain."
        break
    fi

    for ENI in $ENIS; do

        DESCRIPTION=$(aws ec2 describe-network-interfaces \
            --region "$REGION" \
            --network-interface-ids "$ENI" \
            --query 'NetworkInterfaces[0].Description' \
            --output text 2>/dev/null || true)

        STATUS=$(aws ec2 describe-network-interfaces \
            --region "$REGION" \
            --network-interface-ids "$ENI" \
            --query 'NetworkInterfaces[0].Status' \
            --output text 2>/dev/null || true)

        echo "ENI: $ENI | $STATUS | $DESCRIPTION"

        if [[ "$STATUS" == "available" ]]; then
            aws ec2 delete-network-interface \
                --region "$REGION" \
                --network-interface-id "$ENI" || true
        fi
    done

    sleep 5
done

# ------------------------------------------------------------
# 19. Route Tables
# ------------------------------------------------------------

echo
echo "============================================================"
echo "19. ROUTE TABLES"
echo "============================================================"

ROUTE_TABLES=$(aws ec2 describe-route-tables \
    --region "$REGION" \
    --query 'RouteTables[].RouteTableId' \
    --output text 2>/dev/null || true)

for RT in $ROUTE_TABLES; do

    MAIN=$(aws ec2 describe-route-tables \
        --region "$REGION" \
        --route-table-ids "$RT" \
        --query 'RouteTables[0].Associations[?Main==`true`].Main' \
        --output text 2>/dev/null || true)

    if [[ "$MAIN" == "True" ]]; then
        echo "Keeping main route table: $RT"
        continue
    fi

    echo "Deleting route table: $RT"

    # Remove subnet associations first
    ASSOCIATIONS=$(aws ec2 describe-route-tables \
        --region "$REGION" \
        --route-table-ids "$RT" \
        --query 'RouteTables[0].Associations[?Main!=`true`].RouteTableAssociationId' \
        --output text 2>/dev/null || true)

    for ASSOC in $ASSOCIATIONS; do
        aws ec2 disassociate-route-table \
            --region "$REGION" \
            --association-id "$ASSOC" || true
    done

    aws ec2 delete-route-table \
        --region "$REGION" \
        --route-table-id "$RT" || true
done

# ------------------------------------------------------------
# 20. Subnets
# ------------------------------------------------------------

echo
echo "============================================================"
echo "20. SUBNETS"
echo "============================================================"

SUBNETS=$(aws ec2 describe-subnets \
    --region "$REGION" \
    --query 'Subnets[].SubnetId' \
    --output text 2>/dev/null || true)

for SUBNET in $SUBNETS; do
    echo "Deleting subnet: $SUBNET"

    aws ec2 delete-subnet \
        --region "$REGION" \
        --subnet-id "$SUBNET" || true
done

# ------------------------------------------------------------
# 21. Non-default Security Groups
# ------------------------------------------------------------

echo
echo "============================================================"
echo "21. SECURITY GROUPS"
echo "============================================================"

SGS=$(aws ec2 describe-security-groups \
    --region "$REGION" \
    --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
    --output text 2>/dev/null || true)

for SG in $SGS; do

    echo "Removing security-group rules: $SG"

    RULES=$(aws ec2 describe-security-group-rules \
        --region "$REGION" \
        --filters Name=group-id,Values="$SG" \
        --query 'SecurityGroupRules[].SecurityGroupRuleId' \
        --output text 2>/dev/null || true)

    for RULE in $RULES; do

        IS_EGRESS=$(aws ec2 describe-security-group-rules \
            --region "$REGION" \
            --security-group-rule-ids "$RULE" \
            --query 'SecurityGroupRules[0].IsEgress' \
            --output text 2>/dev/null || true)

        if [[ "$IS_EGRESS" == "True" ]]; then
            aws ec2 revoke-security-group-egress \
                --region "$REGION" \
                --group-id "$SG" \
                --security-group-rule-ids "$RULE" 2>/dev/null || true
        else
            aws ec2 revoke-security-group-ingress \
                --region "$REGION" \
                --group-id "$SG" \
                --security-group-rule-ids "$RULE" 2>/dev/null || true
        fi
    done

    aws ec2 delete-security-group \
        --region "$REGION" \
        --group-id "$SG" || true
done

# ------------------------------------------------------------
# 22. VPCs
# ------------------------------------------------------------

echo
echo "============================================================"
echo "22. VPCs"
echo "============================================================"

VPCS=$(aws ec2 describe-vpcs \
    --region "$REGION" \
    --query 'Vpcs[].VpcId' \
    --output text 2>/dev/null || true)

for VPC in $VPCS; do
    echo "Deleting VPC: $VPC"

    aws ec2 delete-vpc \
        --region "$REGION" \
        --vpc-id "$VPC" || true
done

# ------------------------------------------------------------
# 23. CloudWatch Logs
# ------------------------------------------------------------

echo
echo "============================================================"
echo "23. CLOUDWATCH LOG GROUPS"
echo "============================================================"

LOG_GROUPS=$(aws logs describe-log-groups \
    --region "$REGION" \
    --query 'logGroups[].logGroupName' \
    --output text 2>/dev/null || true)

for LOG in $LOG_GROUPS; do
    echo "Deleting log group: $LOG"

    aws logs delete-log-group \
        --region "$REGION" \
        --log-group-name "$LOG" || true
done

# ------------------------------------------------------------
# 24. CloudWatch Alarms
# ------------------------------------------------------------

echo
echo "============================================================"
echo "24. CLOUDWATCH ALARMS"
echo "============================================================"

ALARMS=$(aws cloudwatch describe-alarms \
    --region "$REGION" \
    --query 'MetricAlarms[].AlarmName' \
    --output text 2>/dev/null || true)

if [[ -n "$ALARMS" ]]; then
    aws cloudwatch delete-alarms \
        --region "$REGION" \
        --alarm-names $ALARMS || true
fi

# ------------------------------------------------------------
# 25. Final verification
# ------------------------------------------------------------

echo
echo "============================================================"
echo "FINAL VERIFICATION"
echo "============================================================"

echo
echo "EC2:"
aws ec2 describe-instances \
    --region "$REGION" \
    --filters Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text 2>/dev/null || true

echo
echo "EKS:"
aws eks list-clusters \
    --region "$REGION" \
    --output text 2>/dev/null || true

echo
echo "ECS:"
aws ecs list-clusters \
    --region "$REGION" \
    --output text 2>/dev/null || true

echo
echo "RDS:"
aws rds describe-db-instances \
    --region "$REGION" \
    --query 'DBInstances[].DBInstanceIdentifier' \
    --output text 2>/dev/null || true

echo
echo "ECR:"
aws ecr describe-repositories \
    --region "$REGION" \
    --query 'repositories[].repositoryName' \
    --output text 2>/dev/null || true

echo
echo "VPC:"
aws ec2 describe-vpcs \
    --region "$REGION" \
    --query 'Vpcs[].[VpcId,CidrBlock,State]' \
    --output table 2>/dev/null || true

echo
echo "============================================================"
echo "             CLEANUP COMMANDS COMPLETED"
echo "============================================================"
echo
echo "Some AWS-managed resources may take several minutes to disappear."
echo "Resources that report DependencyViolation may require another pass."
echo
