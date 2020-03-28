## Author: Suhas Basarkod
## Modify as needed
## How to deploy ALB Ingress Controller.

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
[[ -z "$region" || -z "$cluster_name" || -z "${elb_flag}" ]] && echo "Assign region, clusterName and elb_flag variables to something :/ " && exit 0

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text --region ${region})

echo -e "Using Context: $(kubectl config current-context)\n"

# Install eksctl first using the below commands as outlined in [1]:
install_eksctl()
{
  if [[ ! `eksctl --help 2>/dev/null` ]]; then
    echo "Installing eksctl..."
    curl --silent --location "https://github.com/weaveworks/eksctl/releases/download/latest_release/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
    sudo mv /tmp/eksctl /usr/local/bin
    eksctl version
  fi
}

check_subnet_tags()
{
  # Once eksctl is installed, follow the steps 1-9 outlined in [2] to create the ingress controller:
  # Step 1 - Tag your EKS Cluster subnets:
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
    [[ ${#private_subnets[@]} -eq 0 ]] && echo -e "No Private subnets found for this cluster..exiting\n" && exit 1
    for i in "${private_subnets[@]}"
    do
      ## 2 ways of querying for a tag. Using both to diversify
      cluster_tag=$(aws ec2 describe-tags --region ${region} --filters "Name=resource-id,Values=${i}" "Name=key,Values=kubernetes.io/cluster/${cluster_name}" --query "Tags[*].Value" --output text)

      private_elb_tag=$(aws ec2 describe-tags --region ${region} --filters "Name=resource-id,Values=${i}" --query "Tags[?Key=='kubernetes.io/role/internal-elb']|[0].Value" --output text) 

      [[ "${private_elb_tag}" == '1' ]] && echo -e "Private ELB Tag: 'kubernetes.io/role/internal-elb' exists for ${i}\n" && private_elb_flag=1 || echo -e "WARNING: Private ELB Tag: 'kubernetes.io/role/internal-elb' DOES NOT exist for ${i} . ELB Creation will fail in this subnet\n"
    done
    [[ ${private_elb_flag} -eq 0 ]] && echo "No Subnets found with the Private ELB Tag: 'kubernetes.io/role/internal-elb' ..exiting" && exit 1

  # Check Tags for Public subnets
  elif [[ "${elb_flag}" == "public" ]]; then
    echo "Checking public Subnet tags"
    [[ ${#public_subnets[@]} -eq 0 ]] && echo -e "No Public subnets found for this cluster..exiting\n" && exit 1
    for i in "${public_subnets[@]}"
    do
      ## 2 ways of querying for a tag. Using both to diversify
      cluster_tag=$(aws ec2 describe-tags --region ${region} --filters "Name=resource-id,Values=${i}" "Name=key,Values=kubernetes.io/cluster/${cluster_name}" --query "Tags[*].Value" --output text)

      public_elb_tag=$(aws ec2 describe-tags --region ${region} --filters "Name=resource-id,Values=${i}" --query "Tags[?Key=='kubernetes.io/role/elb']|[0].Value" --output text)

      [[ "${public_elb_tag}" == '1' ]] && echo -e "Public ELB Tag: 'kubernetes.io/role/elb' exists for ${i}\n" && public_elb_flag=1 || echo -e "WARNING: Public ELB Tag: 'kubernetes.io/role/elb' DOES NOT exist for ${i} . ELB Creation will fail in this subnet\n"
    done
    [[ ${public_elb_flag} -eq 0 ]] && echo "No Subnets found with the correct tags ..exiting" && exit 1
  else
    echo "Invalid elb_flag set" && exit 1
  fi
}

# Step 2 - Create an IAM OIDC provider and associate it with your cluster. 
create_IAM_OIDC()
{
  echo -e "\nCreating an IAM OIDC provider and associate it with your cluster\n"
  eksctl utils associate-iam-oidc-provider --region us-east-1 --cluster ${cluster_name} --approve
}

create_IAM_policy()
{
  # Step 3 - Create an IAM policy called ALBIngressControllerIAMPolicy for the ALB Ingress Controller pod that allows it to make calls to AWS APIs on your behalf. 

  echo -e "Creating an IAM policy called ALBIngressControllerIAMPolicy for the ALB Ingress Controller pod that allows it to make calls to AWS APIs on your behalf\n"
  
  PolicyARN=$(aws iam list-policies --region ${region} | jq -r '.Policies[] | select(.PolicyName=="ALBIngressControllerIAMPolicy") | .Arn')
  #echo $PolicyARN

  if [[ "${PolicyARN}" == "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/ALBIngressControllerIAMPolicy" ]]; then
    echo -e "Skipping policy creation as it already exists..\n"
  else
    # https://raw.githubusercontent.com/kubernetes-sigs/aws-alb-ingress-controller/v1.1.4/docs/examples/iam-policy.json
    output=$(aws iam create-policy --region ${region} --policy-name ALBIngressControllerIAMPolicy --policy-document file://iam-policy.json)
    PolicyARN=$(echo ${output} | jq -r .Policy.Arn)
    [[ "${PolicyARN}" == "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/ALBIngressControllerIAMPolicy" ]] || ( echo "Policy Creation failed: ${output}" && exit 1)
  fi
  # Step - 4 - Create a Kubernetes service account named alb-ingress-controller in the kube-system namespace, a cluster role, and a cluster role binding for the ALB Ingress Controller to use

  echo -e "\nCreating a Kubernetes service account named alb-ingress-controller in the kube-system namespace, a cluster role, and a cluster role binding for the ALB Ingress Controller to use\n"
  # kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-alb-ingress-controller/v1.1.4/docs/examples/rbac-role.yaml
  kubectl apply -f rbac-role.yaml

  # Step 5 - Create an IAM role for the ALB ingress controller and attach the role to the service account created in the previous step. 
  # Create an IAM role [3] named eks-alb-ingress-controller and attach the ALBIngressControllerIAMPolicy IAM policy that you created in a previous step to it.

  # You must use at least version 1.16.308 of the AWS CLI)
  OIDC_PROVIDER=$(aws eks describe-cluster --name ${cluster_name} --region ${region} --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")
  SERVICE_ACCOUNT_NAMESPACE=kube-system
  SERVICE_ACCOUNT_NAME=alb-ingress-controller
  IAM_ROLE_NAME=eks-alb-ingress-controller
  IAM_ROLE_DESCRIPTION="IAM Role for Service Account ${SERVICE_ACCOUNT_NAME}"
  read -r -d '' TRUST_RELATIONSHIP <<EOF
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
        },
        "Action": "sts:AssumeRoleWithWebIdentity",
        "Condition": {
          "StringEquals": {
            "${OIDC_PROVIDER}:sub": "system:serviceaccount:${SERVICE_ACCOUNT_NAMESPACE}:${SERVICE_ACCOUNT_NAME}"
          }
        }
      }
    ]
  }
EOF
  echo "${TRUST_RELATIONSHIP}" > trust.json
  check_iam_exists=$(aws iam get-role --role-name ${IAM_ROLE_NAME} --region ${region} | jq -r .Role.Arn)
  if [[ "${check_iam_exists}" == "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${IAM_ROLE_NAME}" ]]; then
    echo -e "IAM Role already exists: ${check_iam_exists} ...Skipping\n"
    echo -e "Updating the trust policy"
    aws iam update-assume-role-policy --role-name ${IAM_ROLE_NAME} --policy-document file://trust.json --region ${region}
  else
    echo -e "\nCreating IAM role and attaching a policy that was previously created\n"
    aws iam create-role --role-name $IAM_ROLE_NAME --assume-role-policy-document file://trust.json --description "${IAM_ROLE_DESCRIPTION}" --region ${region}
  fi
  aws iam attach-role-policy --role-name $IAM_ROLE_NAME --policy-arn=${PolicyARN} --region ${region}

  #Annotate the Kubernetes service account with the ARN of the role that you created:
  RoleARN=$(aws iam get-role --role-name $IAM_ROLE_NAME --region ${region} | jq -r .Role.Arn)
  get_annotation=$(kubectl get  sa alb-ingress-controller -n kube-system -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com\/role\-arn}')
  if [[ "${get_annotation}" == "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${IAM_ROLE_NAME}" ]]; then
    echo -e "Annotation already exists on Service Account..Skipping\n"
  else
    kubectl annotate serviceaccount -n kube-system alb-ingress-controller eks.amazonaws.com/role-arn=${RoleARN} --overwrite
  fi
}

deploy_ingress_controller()
{
  # Step 6 - Deploy the ALB Ingress Controller 
  echo -e "\nDeploying the ALB Ingress Controller \n"
  
  #aws eks describe-cluster --name ${cluster_name}  | jq -r '.cluster | .arn, .resourcesVpcConfig.vpcId'
  vpc_id=$(aws eks describe-cluster --name ${cluster_name} --region ${region} | jq -r '.cluster.resourcesVpcConfig.vpcId')

  #kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-alb-ingress-controller/v1.1.4/docs/examples/alb-ingress-controller.yaml

  cp alb-ingress-controller.yaml edited_alb-ingress-controller.yaml
  sed -i -e "s/cluster_region/${region}/g" -i -e "s/cluster_vpc/${vpc_id}/g" -i -e "s/cluster_name/${cluster_name}/g" edited_alb-ingress-controller.yaml
  kubectl apply -f edited_alb-ingress-controller.yaml
  kubectl get pods -n kube-system | grep alb-ingress-
  
}

deploy_demo_app()
{
  # Deploy Demo 2048 Game
  if [[ "${elb_flag}" == "internal" ]]; then
    kubectl apply -f private_2048.yaml
  elif [[ "${elb_flag}" == "public" ]]; then
    kubectl apply -f public_2048.yaml
  else
    echo "Invalid ELB tag..Exiting" && exit 1
  fi
}

cleanup()
{
  if [[ "${elb_flag}" == "internal" ]]; then
    kubectl delete -f private_2048.yaml
  elif [[ "${elb_flag}" == "public" ]]; then
    kubectl delete -f public_2048.yaml
  else
    echo "Invalid ELB tag..Exiting" && exit 1
  fi
  kubectl delete -f rbac-role.yaml
  kubectl delete -f alb-ingress-controller.yaml
}

install_eksctl
check_subnet_tags
create_IAM_OIDC
create_IAM_policy
deploy_ingress_controller
#deploy_demo_app
#cleanup

#References:
#[1] Installing eksctl - https://docs.aws.amazon.com/eks/latest/userguide/eksctl.html
#[2] ALB Ingress Controller on Amazon EKS - https://docs.aws.amazon.com/eks/latest/userguide/alb-ingress.html
#[3] Creating an IAM Role and Policy for your Service Account - https://docs.aws.amazon.com/eks/latest/userguide/create-service-account-iam-policy-and-role.html#create-service-account-iam-role
#[4] AWS Blog Post - https://aws.amazon.com/blogs/opensource/network-load-balancer-nginx-ingress-controller-eks/
