## Author: Suhas Basarkod
## Modify as needed
## How to deploy ALB Ingress Controller.
# You must use at least version 1.16.308 of the AWS CLI)

#!/usr/bin/env bash 

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cluster-name)
            shift
            cluster_name="${1}"
            shift
            ;;
        --region)
            shift
            region="${1}"
            shift
            ;;
        # Set this flag to indicate the type ALB ingress controller you are creating. Options are "internal" and "public"
        --elb-flag)
            shift
            elb_flag="${1}"
            shift
            ;;            
        *)
            echo "$1 is not a recognized flag!"
            exit 1;
            ;;
    esac
done

# Check if vars are set
[[ -z "$region" || -z "$cluster_name" || -z "${elb_flag}" ]] && echo -e "Example Usage: $0 --cluster-name 'my_cluster' --region 'us-east-1' --elb-flag 'internal' (accepted values for --elb-flag are 'internal' OR 'public')" && exit 0

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text --region ${region})
echo -e "Using Context: $(kubectl config current-context)\n"

check_eksctl()
{
  if [[ ! `eksctl --help 2>/dev/null` ]]; then
    echo "eksctl not installed\n"
  else
    echo "eksctl installed"
  fi
}

check_subnet_tags()
{
  # Tag your EKS Cluster subnets:
  # => Key: "kubernetes.io/cluster/<cluster_name>" ; Value: "shared"
  # => For public subnet, "kubernetes.io/role/elb" ; Value: "1"
  # => For private subnet, "kubernetes.io/role/internal-elb" ; Value: "1"

  declare -a subnet_list=$(aws eks describe-cluster --name ${cluster_name} --region ${region} | jq .cluster.resourcesVpcConfig.subnetIds | sed -e "s/]/)/" -e "s/\[/(/" | tr -d '\n' | tr -d ' ' | tr ',' ' ')
  declare -a private_subnets=()
  declare -a public_subnets=()
  public_elb_flag=0
  private_elb_flag=0
  cluster_tag_flag=0
  # Figure out private and public Subnets
  for i in "${subnet_list[@]}"
  do
    gateway_ids=''
    gateway_ids=$(aws ec2 describe-route-tables --region ${region} --filter Name="association.subnet-id",Values="${i}" | jq .RouteTables[].Routes[].GatewayId )
    (echo ${gateway_ids} | grep -q "igw-") && public_subnets+=("${i}") || private_subnets+=("${i}") 
  done
  echo "Private Subnets: ${private_subnets[@]}"
  echo "Public Subnets: ${public_subnets[@]}"

  # Check Tags for Private Subnets
  if [[ "${elb_flag}" == "internal" ]]; then
    echo "Checking Private Subnet tags"
    [[ ${#private_subnets[@]} -eq 0 ]] && echo -e "No Private subnets found for this cluster\n"
    for i in "${private_subnets[@]}"
    do
      ## 2 ways of querying for a tag. Using both to diversify
      cluster_tag=$(aws ec2 describe-tags --region ${region} --filters "Name=resource-id,Values=${i}" "Name=key,Values=kubernetes.io/cluster/${cluster_name}" --query "Tags[*].Value" --output text)

      [[ "${cluster_tag}" == 'shared' ]] && echo -e "Cluster Tag: 'kubernetes.io/cluster/${cluster_name}' exists for ${i}\n" || echo -e "WARNING - Tag: 'kubernetes.io/cluster/${cluster_name}' DOES NOT exist for ${i} . ELB Creation will fail in this subnet\n"

      private_elb_tag=$(aws ec2 describe-tags --region ${region} --filters "Name=resource-id,Values=${i}" --query "Tags[?Key=='kubernetes.io/role/internal-elb']|[0].Value" --output text) 

      [[ "${private_elb_tag}" == '1' ]] && echo -e "Private ELB Tag: 'kubernetes.io/role/internal-elb' exists for ${i}\n" && private_elb_flag=1 || echo -e "WARNING: Private ELB Tag: 'kubernetes.io/role/internal-elb' DOES NOT exist for ${i} . ELB Creation will fail in this subnet\n"
    done

  # Check Tags for Public subnets
  elif [[ "${elb_flag}" == "public" ]]; then
    echo "Checking public Subnet tags"
    [[ ${#public_subnets[@]} -eq 0 ]] && echo -e "No Public subnets found for this cluster\n"
    for i in "${public_subnets[@]}"
    do
      ## 2 ways of querying for a tag. Using both to diversify
      cluster_tag=$(aws ec2 describe-tags --region ${region} --filters "Name=resource-id,Values=${i}" "Name=key,Values=kubernetes.io/cluster/${cluster_name}" --query "Tags[*].Value" --output text)

      [[ "${cluster_tag}" == 'shared' ]] && echo -e "Cluster Tag: 'kubernetes.io/cluster/${cluster_name}' exists for ${i}\n" || echo -e "WARNING - Tag: 'kubernetes.io/cluster/${cluster_name}' DOES NOT exist for ${i} . ELB Creation will fail in this subnet\n"

      public_elb_tag=$(aws ec2 describe-tags --region ${region} --filters "Name=resource-id,Values=${i}" --query "Tags[?Key=='kubernetes.io/role/elb']|[0].Value" --output text)

      [[ "${public_elb_tag}" == '1' ]] && echo -e "Public ELB Tag: 'kubernetes.io/role/elb' exists for ${i}\n" || echo -e "WARNING: Public ELB Tag: 'kubernetes.io/role/elb' DOES NOT exist for ${i} . ELB Creation will fail in this subnet\n"
    done
  else
    echo "Invalid elb_flag set" && exit 1
  fi
}

create_IAM_OIDC()
{
  OIDC_PROVIDER=$(aws eks describe-cluster --name ${cluster_name} --region ${region} --query "cluster.identity.oidc.issuer" --output text)
  echo -e "\nOIDC Provider for your Cluster: ${OIDC_PROVIDER}"
}

check_IAM_policy()
{
  IAM_policy_flag=0
  IAM_role_flag=0
  sa_flag=0

  echo -e "Checking for an IAM policy called ALBIngressControllerIAMPolicy for the ALB Ingress Controller pod that allows it to make calls to AWS APIs on your behalf\n"

  NAMESPACE=kube-system
  ALB_COMPONENT_NAME=alb-ingress-controller
  IAM_ROLE_NAME=eks-alb-ingress-controller
  
  PolicyArnPattern="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/ALBIngressControllerIAMPolicy"
  IAMRoleArnPattern="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${IAM_ROLE_NAME}" 

  PolicyARN=$(aws iam list-policies --region ${region} | jq -r '.Policies[] | select(.PolicyName=="ALBIngressControllerIAMPolicy") | .Arn')

  if [[ "${PolicyARN}" == "${PolicyArnPattern}" ]]; then
    echo -e "Policy '${PolicyARN}' exists..\n"
    IAM_policy_flag=1
  else
    echo -e "Policy '${PolicyARN}' does not exist..\n"
  fi

  check_iam=$(aws iam get-role --role-name ${IAM_ROLE_NAME} --region ${region})
  check_iam_arn=$(echo ${check_iam} | jq -r .Role.Arn)
  if [[ "${check_iam_arn}" == "${IAMRoleArnPattern}" ]]; then
    echo -e "IAM Role exists: ${check_iam_arn} ...Below is the Assume Role Policy Document:\n $(echo ${check_iam} | jq -r .Role.AssumeRolePolicyDocument)\n"
    IAM_role_flag=1
  else
    echo -e "IAM Role: ${IAMRoleArnPattern} does not exist\n"
  fi
  
  if [[ ${IAM_role_flag} -eq 1 && ${IAM_policy_flag} -eq 1 ]]; then

    attached_policies=$(aws iam list-attached-role-policies --role-name $IAM_ROLE_NAME --region ${region} | jq -r '.AttachedPolicies[].PolicyArn')

    if echo ${attached_policies} | grep -q ${PolicyArnPattern}; then
      echo -e "Policy: ${PolicyArnPattern} attached to $IAM_ROLE_NAME . List of attached Policies: \n${attached_policies}\n"

      [[ `kubectl get deploy  ${ALB_COMPONENT_NAME} -n ${NAMESPACE}` ]] && echo -e "Deployment:  ${ALB_COMPONENT_NAME} exists\n" && kubectl get po -n ${NAMESPACE} -l app.kubernetes.io/name=alb-ingress-controller

      [[ `kubectl get ClusterRole  ${ALB_COMPONENT_NAME} -n ${NAMESPACE}` ]] && echo -e "ClusterRole  ${ALB_COMPONENT_NAME} exists\n"

      [[ `kubectl get ClusterRoleBinding  ${ALB_COMPONENT_NAME} -n ${NAMESPACE}` ]] && echo -e "ClusterRoleBinding  ${ALB_COMPONENT_NAME} exists\n"

      [[ `kubectl get sa ${ALB_COMPONENT_NAME} -n ${NAMESPACE}` ]] || echo -e "Service account: ${ALB_COMPONENT_NAME} does not exist" || sa_flag=1 && echo -e "Service account: ${ALB_COMPONENT_NAME} exists"
      # Check if SA is Annotated with the ARN of the IAM role
      RoleARN=$(aws iam get-role --role-name $IAM_ROLE_NAME --region ${region} | jq -r .Role.Arn)
      get_annotation=$(kubectl get sa ${ALB_COMPONENT_NAME} -n ${NAMESPACE} -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com\/role\-arn}')
      if [[ ${sa_flag} -eq 1 && "${get_annotation}" == "${IAMRoleArnPattern}" ]]; then
        echo -e "Annotation: ${get_annotation} exists on Service Account:  ${ALB_COMPONENT_NAME} ..\n"
      else
        echo -e "Annotation: ${IAMRoleArnPattern} does not exist on Service Account: ${ALB_COMPONENT_NAME}  ..\n"
      fi
    fi
  fi   
}

check_eksctl
check_subnet_tags
create_IAM_OIDC
check_IAM_policy

