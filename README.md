Summary

**verification.sh**: This script checks your ALB Ingress Controller setup for expected configuration for it to function as expected
**setup.sh**: This script automatates the process of setting up an alb-ingress controller on AWS via a Bash script

---------

# aws-alb-ingress controller


### Pre-reqs

  - kubectl and aws-cli
  - Required permissions to run 'kubectl' and 'aws' commands

## verification.sh

### Explaination

This script checks for the following things as far as the Ingress Controller setup is concerned and does not deploy of modify things.:
1. eksctl installation
2. Checks for subnet tags:
```
  # => Key: "kubernetes.io/cluster/<cluster_name>" ; Value: "shared"
  # => For public subnet, "kubernetes.io/role/elb" ; Value: "1"
  # => For private subnet, "kubernetes.io/role/internal-elb" ; Value: "1"
```
3. Checks if IAM Policy exists: `arn:aws:iam::${AWS_ACCOUNT_ID}:policy/ALBIngressControllerIAMPolicy`
4. Checks if IAM Role exists: `arn:aws:iam::${AWS_ACCOUNT_ID}:role/eks-alb-ingress-controller`
5. Checks if the above policy is attached to the IAM role
6. Outputs the Assume Role Policy Document of the IAM role
7. Checks if alb-ingress-controller ClusterRole, ClusterRoleBinding, Deployment and Service account exists
8. Checks if the alb-ingress-controller service account is annotated with the aforementioned IAM role
9. Displays OIDC Provider information

### Usage
Invoke the setup.sh the following way
```
$curl -sO https://raw.githubusercontent.com/suhas316380/aws-alb-ingress-controller/master/verification.sh | bash verification.sh --cluster-name "your_cluster_name" --region "your_cluster_region" --elb-flag "internal"

```

### Sample output

```
bash verification.sh --cluster-name "suhas-eks-test" --region "us-east-1" --elb-flag "public"
Using Context: arn:aws:eks:us-east-1:123456789:cluster/suhas-eks-test

eksctl installed
Private Subnets:
Public Subnets: subnet-12345678 subnet-456789
Checking public Subnet tags
Cluster Tag: 'kubernetes.io/cluster/suhas-eks-test' exists for subnet-12345678

Public ELB Tag: 'kubernetes.io/role/elb' exists for subnet-12345678

Cluster Tag: 'kubernetes.io/cluster/suhas-eks-test' exists for subnet-456789

Public ELB Tag: 'kubernetes.io/role/elb' exists for subnet-456789


OIDC Provider for your Cluster: https://oidc.eks.us-east-1.amazonaws.com/id/ABCDEFGHIJKLMNOPQR
Checking for an IAM policy called ALBIngressControllerIAMPolicy for the ALB Ingress Controller pod that allows it to make calls to AWS APIs on your behalf

Policy 'arn:aws:iam::123456789:policy/ALBIngressControllerIAMPolicy' exists..

IAM Role exists: arn:aws:iam::123456789:role/eks-alb-ingress-controller ...Below is the Assume Role Policy Document:
 {
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::123456789:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/ABCDEFGHIJKLMNOPQR"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.us-east-1.amazonaws.com/id/ABCDEFGHIJKLMNOPQR:sub": "system:serviceaccount:kube-system:alb-ingress-controller"
        }
      }
    }
  ]
}

Policy: arn:aws:iam::123456789:policy/ALBIngressControllerIAMPolicy attached to eks-alb-ingress-controller . List of attached Policies:
arn:aws:iam::123456789:policy/ALBIngressControllerIAMPolicy

Error from server (NotFound): deployments.extensions "alb-ingress-controller" not found
ClusterRole  alb-ingress-controller exists

ClusterRoleBinding  alb-ingress-controller exists

Service account: alb-ingress-controller exists
Annotation: arn:aws:iam::123456789:role/eks-alb-ingress-controller does not exist on Service Account: alb-ingress-controller  ..
```
## setup.sh

### Usage
Invoke the setup.sh the following way
```
bash setup.sh --cluster-name "your_cluster_name" --region "your_cluster_region" --elb-flag "internal"

```

**Example-1**:
```sh
$git clone https://github.com/suhas316380/aws-alb-ingress-controller.git
$cd aws-alb-ingress-controller
$bash setup.sh  --cluster-name suhas-eks-test --region us-east-1 --elb-flag public
```

### Explaination
The setup.sh script performs the following things:

**Step 1**: Install eksctl if not present

**Step 2**: Atleast 2 subnets should have the applicable tags. Script check tags of your EKS Cluster subnets: 
```
Key: "kubernetes.io/cluster/<cluster_name>" ; Value: "shared"
For public subnet, "kubernetes.io/role/elb" ; Value: "1"
For private subnet, "kubernetes.io/role/internal-elb" ; Value: "1"
```

Following aws cli cmds are executed to check the necessary tags:

`aws ec2 describe-tags --region ${region} --filters "Name=resource-id,Values=${subnet_id}" "Name=key,Values=kubernetes.io/cluster/${cluster_name}" --query "Tags[*].Value" --output text`


`aws ec2 describe-tags --region ${region} --filters "Name=resource-id,Values=${subnet_id}" --query "Tags[?Key=='kubernetes.io/role/internal-elb']|[0].Value" --output text`

**Step 3**: Create an IAM OIDC provider and associate it with your cluster

`eksctl utils associate-iam-oidc-provider --region us-east-1 --cluster ${cluster_name} --approve`

**Step 4**: Create an IAM policy called ALBIngressControllerIAMPolicy for the ALB Ingress Controller pod that allows it to make calls to AWS APIs on your behalf. 

`aws iam create-policy --region ${region} --policy-name ALBIngressControllerIAMPolicy --policy-document https://raw.githubusercontent.com/kubernetes-sigs/aws-alb-ingress-controller/v1.1.4/docs/examples/iam-policy.json`

**Step 5**: Create a Kubernetes service account named alb-ingress-controller in the kube-system namespace, a cluster role, and a cluster role binding for the ALB Ingress Controller to use

`kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-alb-ingress-controller/v1.1.4/docs/examples/rbac-role.yaml`

**Step 6**: Create an IAM role named eks-alb-ingress-controller and attach the ALBIngressControllerIAMPolicy IAM policy that you created in a previous step to it. Below is the trust policy

```
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
```

Create Role: 

`aws iam create-role --role-name $IAM_ROLE_NAME --assume-role-policy-document file://trust.json --description "${IAM_ROLE_DESCRIPTION}" --region ${region}`

Attach Policy to Role: 

`aws iam attach-role-policy --role-name $IAM_ROLE_NAME --policy-arn=${PolicyARN} --region ${region}`

**Step 7**: Deploy Ingress Controller by substituting the correct values for the vpcid, cluster name and the cluster region.

`kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-alb-ingress-controller/v1.1.4/docs/examples/alb-ingress-controller.yaml`

**Step 8**: Verify 

`kubectl get pods -n kube-system | grep alb-ingress-`

**Step 9**: Optional - Deploy 2048 game. Saperate manifests for public and private Loadbalancer. Uncomment "deploy_demo_app" function call at the end of script to automatically deploy a demo app based on the elb_tag that was set at the beginning of the script

**Step 10**: Option - Cleanup. Uncomment "cleanup" function call at the end of script to automatically delete the demo game, rbac and alb-ingress-controller NS, SVC, Deployment, CR, CRB and SA


### Todos
 - Needs improvement in error handling.
 - Does not add Subnet tags for you. Only determines if atleast one subnet is tagged correctly and complains if that is not the case. 

