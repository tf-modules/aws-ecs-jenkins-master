variable "aws_account_id" {}
variable "vpc_name" {}

variable "public_subnets" {}
variable "configuration_bucket" {}

variable "region" {}

variable "tags" {
  type = "map"
}

variable "jenkins_image" {}
variable "confd_image" {}

variable "dynamodb_sync_util" {}

variable "ssl_cert_name" {}

variable "jenkins_dns" {}

variable "dns_domain" {}

variable "default_service_ingress_rules" {}
