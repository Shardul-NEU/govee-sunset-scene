terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # Filled in at init time with:
  #   terraform init -backend-config=backend.hcl
  # (backend.hcl is gitignored - copy backend.hcl.example and fill in the
  # bucket/table created by terraform/bootstrap. See README.md.)
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
}
