terraform {
  required_version = ">= 1.3.0"
  required_providers {
    null = { source = "hashicorp/null" }
  }
}

provider "null" {}

resource "null_resource" "noop_two" {
  triggers = { build = "true" }
}

