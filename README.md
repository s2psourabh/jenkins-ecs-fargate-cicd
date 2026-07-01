# jenkins-ecs-fargate-cicd
Yes, Sourabh — **this is the better path**. 🔥
Instead of simulating old-style deployment like **EC2 + manual Docker run**, we will simulate a more company-style flow:

```text id="4x9h0d"
GitHub
  ↓
Jenkins Pipeline
  ↓
Docker Build
  ↓
Push Image to AWS ECR
  ↓
Terraform
  ↓
Deploy to ECS Fargate
  ↓
Application Load Balancer URL
```

This gives you a much stronger interview story:

> “I created a CI/CD pipeline where Jenkins builds a Docker image, pushes it to Amazon ECR, and Terraform deploys the containerized application on ECS Fargate behind an Application Load Balancer.”

That sounds far more real-world than “I SSH into EC2 and run Docker manually.” 💪

---

# Target Architecture

We will use:

| Component                     | Purpose                                    |
| ----------------------------- | ------------------------------------------ |
| **GitHub**                    | Source code repository                     |
| **Jenkins**                   | CI/CD automation                           |
| **Docker**                    | Containerize application                   |
| **Amazon ECR**                | Private Docker image registry              |
| **Terraform**                 | Infrastructure provisioning                |
| **Amazon ECS Fargate**        | Run container without managing EC2 servers |
| **Application Load Balancer** | Expose app through HTTP                    |
| **S3 Backend**                | Store Terraform state remotely             |

Amazon ECR supports pushing Docker images using `aws ecr get-login-password`, and AWS recommends logging in to ECR using Docker with username `AWS`. ([AWS Documentation][1]) Terraform’s S3 backend supports remote state storage and state locking using `use_lockfile = true`; HashiCorp also recommends enabling bucket versioning for state recovery. ([HashiCorp Developer][2]) Jenkins supports secure credential usage inside pipelines using the credentials binding mechanism instead of hardcoding secrets. ([Jenkins][3])

---

# Important Cost Note

This setup is real-world, but it may create AWS charges.

The **Application Load Balancer** has an hourly cost plus LCU usage, and the AWS pricing page gives an example around **$32.76/month** for a running ALB in one pricing scenario. ([Amazon Web Services, Inc.][4]) AWS Fargate pricing depends on vCPU, memory, OS, architecture, and storage used while the task runs. ([Amazon Web Services, Inc.][5])

So for practice:

```text id="v8ynab"
Run → Test → Destroy
```

Do not leave it running for days.

---

# Final Project Structure

Create this structure in your GitHub repo:

```text id="o9f35k"
jenkins-ecs-fargate-project/
│
├── Jenkinsfile
├── Dockerfile
├── app/
│   └── index.html
│
└── terraform/
    ├── ecr/
    │   ├── versions.tf
    │   ├── variables.tf
    │   ├── main.tf
    │   └── outputs.tf
    │
    └── app/
        ├── versions.tf
        ├── variables.tf
        ├── main.tf
        └── outputs.tf
```

---

# Step 1: Create Simple App

Create:

```text id="l7z1j4"
app/index.html
```

```html id="w17ju9"
<!DOCTYPE html>
<html>
<head>
    <title>Jenkins ECS Fargate Project</title>
</head>
<body>
    <h1>Hello from Jenkins + Docker + ECR + Terraform + ECS Fargate</h1>
    <p>This is a real-world DevOps CI/CD simulation.</p>
</body>
</html>
```

---

# Step 2: Create Dockerfile

Create:

```text id="hld8zc"
Dockerfile
```

```dockerfile id="ef4420"
FROM nginx:1.27-alpine

COPY app/ /usr/share/nginx/html

EXPOSE 80
```

---

# Step 3: Create Terraform State Bucket

This is a **one-time manual step**.

From your machine or Jenkins server where AWS CLI is configured:

```bash id="zp8dk4"
aws sts get-caller-identity
```

Then create a unique S3 bucket.

Example:

```bash id="r1i3qv"
export AWS_REGION="ap-south-1"
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export TF_STATE_BUCKET="tf-state-${AWS_ACCOUNT_ID}-jenkins-ecs-demo"

aws s3api create-bucket \
  --bucket $TF_STATE_BUCKET \
  --region $AWS_REGION \
  --create-bucket-configuration LocationConstraint=$AWS_REGION

aws s3api put-bucket-versioning \
  --bucket $TF_STATE_BUCKET \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket $TF_STATE_BUCKET \
  --server-side-encryption-configuration '{
    "Rules": [
      {
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "AES256"
        }
      }
    ]
  }'
```

Keep this bucket name. Jenkins will need it as a parameter.

---

# Step 4: Terraform for ECR

This stack creates the ECR repository.

## `terraform/ecr/versions.tf`

```hcl id="bcru71"
terraform {
  required_version = ">= 1.6.0"

  backend "s3" {
    key          = "jenkins-ecs-demo/ecr/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```

---

## `terraform/ecr/variables.tf`

```hcl id="vt0tr8"
variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "app_name" {
  description = "Application name"
  type        = string
}
```

---

## `terraform/ecr/main.tf`

```hcl id="kx8ehs"
provider "aws" {
  region = var.aws_region
}

resource "aws_ecr_repository" "app" {
  name                 = var.app_name
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name      = var.app_name
    ManagedBy = "Terraform"
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
```

---

## `terraform/ecr/outputs.tf`

```hcl id="tmrfma"
output "repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "repository_name" {
  value = aws_ecr_repository.app.name
}
```

---

# Step 5: Terraform for ECS Fargate App

This stack creates:

```text id="ei4vpg"
ECS Cluster
ECS Task Definition
ECS Service
Application Load Balancer
Target Group
Security Groups
CloudWatch Log Group
IAM Roles
```

## `terraform/app/versions.tf`

```hcl id="gsh96w"
terraform {
  required_version = ">= 1.6.0"

  backend "s3" {
    key          = "jenkins-ecs-demo/app/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```

---

## `terraform/app/variables.tf`

```hcl id="mz57g1"
variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "environment" {
  description = "Target environment"
  type        = string

  validation {
    condition     = contains(["dev", "qa", "prod"], var.environment)
    error_message = "Environment must be dev, qa, or prod."
  }
}

variable "app_name" {
  description = "Application name"
  type        = string
}

variable "image_tag" {
  description = "Docker image tag to deploy"
  type        = string
}

variable "container_port" {
  description = "Container port"
  type        = number
  default     = 80
}

variable "task_cpu" {
  description = "Fargate task CPU"
  type        = string
  default     = "256"
}

variable "task_memory" {
  description = "Fargate task memory"
  type        = string
  default     = "512"
}

variable "desired_count" {
  description = "Number of running containers"
  type        = number
  default     = 1
}
```

---

## `terraform/app/main.tf`

```hcl id="fgv6re"
provider "aws" {
  region = var.aws_region
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_ecr_repository" "app" {
  name = var.app_name
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.app_name}-${var.environment}"
  retention_in_days = 7

  tags = {
    Name        = "${var.app_name}-${var.environment}"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

resource "aws_ecs_cluster" "app" {
  name = "${var.app_name}-${var.environment}-cluster"

  tags = {
    Name        = "${var.app_name}-${var.environment}-cluster"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name = "${var.app_name}-${var.environment}-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "ecs_task_role" {
  name = "${var.app_name}-${var.environment}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

resource "aws_security_group" "alb_sg" {
  name        = "${var.app_name}-${var.environment}-alb-sg"
  description = "ALB security group"
  vpc_id      = data.aws_vpc.default.id

  tags = {
    Name        = "${var.app_name}-${var.environment}-alb-sg"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb_sg.id

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 80
  ip_protocol = "tcp"
  to_port     = 80
}

resource "aws_vpc_security_group_egress_rule" "alb_all_outbound" {
  security_group_id = aws_security_group.alb_sg.id

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}

resource "aws_security_group" "ecs_sg" {
  name        = "${var.app_name}-${var.environment}-ecs-sg"
  description = "ECS service security group"
  vpc_id      = data.aws_vpc.default.id

  tags = {
    Name        = "${var.app_name}-${var.environment}-ecs-sg"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

resource "aws_vpc_security_group_ingress_rule" "ecs_from_alb" {
  security_group_id            = aws_security_group.ecs_sg.id
  referenced_security_group_id = aws_security_group.alb_sg.id

  from_port   = var.container_port
  ip_protocol = "tcp"
  to_port     = var.container_port
}

resource "aws_vpc_security_group_egress_rule" "ecs_all_outbound" {
  security_group_id = aws_security_group.ecs_sg.id

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}

resource "aws_lb" "app" {
  name               = "${var.app_name}-${var.environment}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = data.aws_subnets.default.ids

  tags = {
    Name        = "${var.app_name}-${var.environment}-alb"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

resource "aws_lb_target_group" "app" {
  name        = "${var.app_name}-${var.environment}-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "ip"

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name        = "${var.app_name}-${var.environment}-tg"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_ecs_task_definition" "app" {
  family                   = "${var.app_name}-${var.environment}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name      = var.app_name
      image     = "${data.aws_ecr_repository.app.repository_url}:${var.image_tag}"
      essential = true

      portMappings = [
        {
          containerPort = var.container_port
          hostPort      = var.container_port
          protocol      = "tcp"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.app.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])

  tags = {
    Name        = "${var.app_name}-${var.environment}"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

resource "aws_ecs_service" "app" {
  name            = "${var.app_name}-${var.environment}-service"
  cluster         = aws_ecs_cluster.app.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = var.app_name
    container_port   = var.container_port
  }

  depends_on = [
    aws_lb_listener.http,
    aws_iam_role_policy_attachment.ecs_task_execution_policy
  ]

  tags = {
    Name        = "${var.app_name}-${var.environment}-service"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}
```

Amazon ECS services are long-running tasks, commonly used for web servers and APIs, and ECS can integrate with an Application Load Balancer. ([Terraform Registry][6]) An ALB works at the HTTP/HTTPS application layer and can route traffic to targets like containers. ([Amazon Web Services, Inc.][7])

---

## `terraform/app/outputs.tf`

```hcl id="hjnshb"
output "alb_dns_name" {
  value = aws_lb.app.dns_name
}

output "application_url" {
  value = "http://${aws_lb.app.dns_name}"
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.app.name
}

output "ecs_service_name" {
  value = aws_ecs_service.app.name
}
```

---

# Step 6: Jenkins Credentials

In Jenkins, create AWS credentials:

```text id="z21srk"
Manage Jenkins
→ Credentials
→ System
→ Global credentials
→ Add Credentials
```

Create:

| Field    | Value                  |
| -------- | ---------------------- |
| Kind     | Username with password |
| Username | AWS Access Key ID      |
| Password | AWS Secret Access Key  |
| ID       | `aws-jenkins-creds`    |

For a company setup, Jenkins would ideally run on an EC2 agent with an IAM Role, or use OIDC-style temporary credentials. But because you currently have only an IAM user, we will store the access key securely in Jenkins credentials for this learning project.

---

# Step 7: Jenkins Agent Requirements

Your Jenkins agent/server needs these tools installed:

```text id="ftk2fn"
Git
Docker
Terraform
AWS CLI v2
```

Also Jenkins must be allowed to run Docker:

```bash id="3x5p0t"
sudo usermod -aG docker jenkins
sudo systemctl restart jenkins
```

Then verify:

```bash id="260r2r"
docker version
terraform version
aws --version
git --version
```

---

# Step 8: Jenkinsfile

Create:

```text id="q7r68x"
Jenkinsfile
```

```groovy id="up2494"
pipeline {
    agent any

    parameters {
        choice(
            name: 'TARGET_ENV',
            choices: ['dev', 'qa', 'prod'],
            description: 'Choose target environment'
        )

        choice(
            name: 'ACTION',
            choices: ['apply', 'destroy'],
            description: 'Choose Terraform action'
        )

        string(
            name: 'AWS_REGION',
            defaultValue: 'ap-south-1',
            description: 'AWS region'
        )

        string(
            name: 'TF_STATE_BUCKET',
            defaultValue: '',
            description: 'S3 bucket name for Terraform remote state'
        )
    }

    environment {
        APP_NAME = 'jenkins-ecs-demo'
        ECR_DIR = 'terraform/ecr'
        APP_DIR = 'terraform/app'
    }

    stages {

        stage('Validate Inputs') {
            steps {
                script {
                    if (!params.TF_STATE_BUCKET?.trim()) {
                        error "TF_STATE_BUCKET parameter is required."
                    }

                    if (params.TARGET_ENV == 'prod') {
                        input message: "You selected PROD. Approve production deployment?"
                    }

                    env.IMAGE_TAG = "${params.TARGET_ENV}-${env.BUILD_NUMBER}"

                    echo "Application Name: ${env.APP_NAME}"
                    echo "Target Environment: ${params.TARGET_ENV}"
                    echo "Action: ${params.ACTION}"
                    echo "AWS Region: ${params.AWS_REGION}"
                    echo "Image Tag: ${env.IMAGE_TAG}"
                }
            }
        }

        stage('Checkout Code') {
            steps {
                checkout scm
            }
        }

        stage('AWS Identity Check') {
            steps {
                withCredentials([
                    usernamePassword(
                        credentialsId: 'aws-jenkins-creds',
                        usernameVariable: 'AWS_ACCESS_KEY_ID',
                        passwordVariable: 'AWS_SECRET_ACCESS_KEY'
                    )
                ]) {
                    sh """
                        aws sts get-caller-identity
                    """
                }
            }
        }

        stage('Create/Verify ECR Repository') {
            when {
                expression {
                    return params.ACTION == 'apply'
                }
            }
            steps {
                withCredentials([
                    usernamePassword(
                        credentialsId: 'aws-jenkins-creds',
                        usernameVariable: 'AWS_ACCESS_KEY_ID',
                        passwordVariable: 'AWS_SECRET_ACCESS_KEY'
                    )
                ]) {
                    sh """
                        cd ${ECR_DIR}

                        terraform init \
                          -backend-config="bucket=${params.TF_STATE_BUCKET}" \
                          -backend-config="region=${params.AWS_REGION}"

                        terraform plan \
                          -var="aws_region=${params.AWS_REGION}" \
                          -var="app_name=${APP_NAME}" \
                          -out=tfplan

                        terraform apply -auto-approve tfplan
                    """
                }
            }
        }

        stage('Get ECR Repository URL') {
            when {
                expression {
                    return params.ACTION == 'apply'
                }
            }
            steps {
                withCredentials([
                    usernamePassword(
                        credentialsId: 'aws-jenkins-creds',
                        usernameVariable: 'AWS_ACCESS_KEY_ID',
                        passwordVariable: 'AWS_SECRET_ACCESS_KEY'
                    )
                ]) {
                    script {
                        env.ECR_REPO_URL = sh(
                            script: """
                                cd ${ECR_DIR}
                                terraform output -raw repository_url
                            """,
                            returnStdout: true
                        ).trim()

                        env.AWS_ACCOUNT_ID = sh(
                            script: "aws sts get-caller-identity --query Account --output text",
                            returnStdout: true
                        ).trim()

                        env.ECR_REGISTRY = "${env.AWS_ACCOUNT_ID}.dkr.ecr.${params.AWS_REGION}.amazonaws.com"

                        echo "ECR Repo URL: ${env.ECR_REPO_URL}"
                    }
                }
            }
        }

        stage('Docker Build') {
            when {
                expression {
                    return params.ACTION == 'apply'
                }
            }
            steps {
                sh """
                    docker build -t ${ECR_REPO_URL}:${IMAGE_TAG} .
                """
            }
        }

        stage('Docker Login to ECR and Push') {
            when {
                expression {
                    return params.ACTION == 'apply'
                }
            }
            steps {
                withCredentials([
                    usernamePassword(
                        credentialsId: 'aws-jenkins-creds',
                        usernameVariable: 'AWS_ACCESS_KEY_ID',
                        passwordVariable: 'AWS_SECRET_ACCESS_KEY'
                    )
                ]) {
                    sh """
                        aws ecr get-login-password --region ${params.AWS_REGION} | \
                        docker login --username AWS --password-stdin ${ECR_REGISTRY}

                        docker push ${ECR_REPO_URL}:${IMAGE_TAG}
                    """
                }
            }
        }

        stage('Terraform Init App Stack') {
            steps {
                withCredentials([
                    usernamePassword(
                        credentialsId: 'aws-jenkins-creds',
                        usernameVariable: 'AWS_ACCESS_KEY_ID',
                        passwordVariable: 'AWS_SECRET_ACCESS_KEY'
                    )
                ]) {
                    sh """
                        cd ${APP_DIR}

                        terraform init \
                          -backend-config="bucket=${params.TF_STATE_BUCKET}" \
                          -backend-config="region=${params.AWS_REGION}"

                        terraform workspace select ${params.TARGET_ENV} || terraform workspace new ${params.TARGET_ENV}
                    """
                }
            }
        }

        stage('Terraform Plan App Stack') {
            steps {
                withCredentials([
                    usernamePassword(
                        credentialsId: 'aws-jenkins-creds',
                        usernameVariable: 'AWS_ACCESS_KEY_ID',
                        passwordVariable: 'AWS_SECRET_ACCESS_KEY'
                    )
                ]) {
                    script {
                        if (params.ACTION == 'apply') {
                            sh """
                                cd ${APP_DIR}

                                terraform plan \
                                  -var="aws_region=${params.AWS_REGION}" \
                                  -var="environment=${params.TARGET_ENV}" \
                                  -var="app_name=${APP_NAME}" \
                                  -var="image_tag=${IMAGE_TAG}" \
                                  -out=tfplan
                            """
                        } else {
                            sh """
                                cd ${APP_DIR}

                                terraform plan -destroy \
                                  -var="aws_region=${params.AWS_REGION}" \
                                  -var="environment=${params.TARGET_ENV}" \
                                  -var="app_name=${APP_NAME}" \
                                  -var="image_tag=dummy" \
                                  -out=tfplan
                            """
                        }
                    }
                }
            }
        }

        stage('Approval Before Terraform Apply') {
            steps {
                input message: "Approve Terraform ${params.ACTION} for ${params.TARGET_ENV}?"
            }
        }

        stage('Terraform Apply App Stack') {
            steps {
                withCredentials([
                    usernamePassword(
                        credentialsId: 'aws-jenkins-creds',
                        usernameVariable: 'AWS_ACCESS_KEY_ID',
                        passwordVariable: 'AWS_SECRET_ACCESS_KEY'
                    )
                ]) {
                    sh """
                        cd ${APP_DIR}
                        terraform apply -auto-approve tfplan
                    """
                }
            }
        }

        stage('Show Application URL') {
            when {
                expression {
                    return params.ACTION == 'apply'
                }
            }
            steps {
                withCredentials([
                    usernamePassword(
                        credentialsId: 'aws-jenkins-creds',
                        usernameVariable: 'AWS_ACCESS_KEY_ID',
                        passwordVariable: 'AWS_SECRET_ACCESS_KEY'
                    )
                ]) {
                    sh """
                        cd ${APP_DIR}
                        terraform output application_url
                    """
                }
            }
        }
    }

    post {
        success {
            echo "Pipeline completed successfully."
        }

        failure {
            echo "Pipeline failed. Check console logs."
        }

        always {
            sh """
                docker image prune -f || true
            """
        }
    }
}
```

---

# Step 9: Create Jenkins Pipeline Job

In Jenkins:

```text id="8rc86y"
New Item
→ Pipeline
→ Enter name: jenkins-ecs-fargate-project
→ Pipeline script from SCM
→ Git
→ Add your GitHub repo URL
→ Branch: main
→ Script Path: Jenkinsfile
→ Save
```

Run:

```text id="zu9qw5"
Build with Parameters
```

Example values:

```text id="i055kv"
TARGET_ENV     = dev
ACTION         = apply
AWS_REGION     = ap-south-1
TF_STATE_BUCKET = tf-state-<your-account-id>-jenkins-ecs-demo
```

---

# Step 10: How Deployment Works

When you run the Jenkins pipeline:

## 1. Jenkins checks out code

```text id="lrptxi"
GitHub repo → Jenkins workspace
```

## 2. Jenkins creates/verifies ECR

Terraform creates the private ECR repository.

```text id="igjz83"
Amazon ECR repository: jenkins-ecs-demo
```

## 3. Jenkins builds Docker image

```text id="judcyz"
docker build -t ECR_REPO_URL:dev-15 .
```

## 4. Jenkins pushes image to ECR

```text id="ecyzpb"
docker push ECR_REPO_URL:dev-15
```

## 5. Terraform deploys ECS Fargate

Terraform creates:

```text id="5zn9qx"
ECS Cluster
Task Definition
ECS Service
Application Load Balancer
Security Groups
IAM Roles
CloudWatch Logs
```

## 6. Jenkins prints app URL

Example:

```text id="gsqna3"
http://jenkins-ecs-demo-dev-alb-123456.ap-south-1.elb.amazonaws.com
```

---

# Step 11: Destroy When Done

To avoid unnecessary AWS charges, run Jenkins again:

```text id="e5u5zi"
TARGET_ENV = dev
ACTION     = destroy
```

This destroys the ECS service, ALB, target group, security groups, IAM roles, and logs for that environment.

The ECR repo is separate and remains available. That is intentional because image repositories are usually treated as a shared platform resource.

---

# Interview Explanation

Use this answer:

> I created a Jenkins CI/CD pipeline where the same Jenkinsfile can deploy to different environments like dev, qa, and prod using parameters. Jenkins checks out the code from GitHub, builds a Docker image, authenticates with Amazon ECR, and pushes the image with a unique tag. Then Terraform provisions the infrastructure, including ECS Fargate, Application Load Balancer, security groups, IAM roles, CloudWatch logs, and ECS service. Terraform state is stored remotely in S3 with locking enabled. For production, I added a manual approval stage before deployment.

That is a strong DevOps answer. ✅

---

# Why This Is Better Than EC2 Docker Run

| EC2 Docker Run                  | ECS Fargate Approach        |
| ------------------------------- | --------------------------- |
| You manage server manually      | AWS manages compute         |
| SSH often required              | No SSH needed               |
| Docker must be installed on EC2 | No Docker setup on server   |
| Harder to scale                 | ECS service can scale       |
| Less production-like            | More company-like           |
| Manual container restart logic  | ECS maintains desired count |
| Weak interview story            | Strong DevOps story         |

This is the right project to put confidence behind your Jenkins, Docker, Terraform, AWS, and CI/CD knowledge. 🚀

[1]: https://docs.aws.amazon.com/AmazonECR/latest/userguide/docker-push-ecr-image.html?utm_source=chatgpt.com "push a Docker image to an Amazon ECR repository"
[2]: https://developer.hashicorp.com/terraform/language/backend/s3?utm_source=chatgpt.com "Backend Type: s3 | Terraform"
[3]: https://www.jenkins.io/doc/pipeline/steps/credentials-binding/?utm_source=chatgpt.com "Credentials Binding Plugin"
[4]: https://aws.amazon.com/elasticloadbalancing/pricing/?utm_source=chatgpt.com "Elastic Load Balancing pricing"
[5]: https://aws.amazon.com/fargate/pricing/?utm_source=chatgpt.com "AWS Fargate Pricing - Amazon.com"
[6]: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_service?utm_source=chatgpt.com "aws_ecs_service | Resources | hashicorp/aws | Terraform"
[7]: https://aws.amazon.com/elasticloadbalancing/application-load-balancer/?utm_source=chatgpt.com "Application Load Balancer"

