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