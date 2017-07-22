provider "aws" {
  region = "${var.region}"
}

terraform {
  backend "s3" {}
  required_version = "~> 0.9.2"
}

data "terraform_remote_state" "ecs-cluster" {
    backend = "s3"
    config {
      bucket = "${var.configuration_bucket}-${var.region}-${var.aws_account_id}"
      region = "${var.region}"
      key    = "${var.tags["site_name"]}/${var.tags["environment"]}/ecs-cluster/terraform.tfstate"
    }
}

data "terraform_remote_state" "confd" {
    backend = "s3"
    config {
      bucket = "${var.configuration_bucket}-${var.region}-${var.aws_account_id}"
      region = "${var.region}"
      key    = "${var.tags["site_name"]}/${var.tags["environment"]}/confd/terraform.tfstate"
    }
}

data "terraform_remote_state" "database" {
    backend = "s3"
    config {
      bucket = "${var.configuration_bucket}-${var.region}-${var.aws_account_id}"
      region = "${var.region}"
      key    = "${var.tags["site_name"]}/${var.tags["environment"]}/database/terraform.tfstate"
    }
}

module "vpc" {
  source   = "git::ssh://git@github.com/tf-modules/aws-vpc.git?ref=0.0.4"
  vpc-name = "${var.vpc_name}"
  region   = "${var.region}"
}

module "aws-r53-zone" {
  source    = "git::ssh://git@github.com/tf-modules/aws-r53-zone.git?ref=0.0.1"
  name      = "${var.dns_domain}"
}

resource "null_resource" "confd" {
  triggers {
    table_arn = "${data.terraform_remote_state.confd.table_arn}"
    config_hash = "${md5(file("config.properties"))}"
    secret_hash = "${md5(file("secret.properties"))}"
  }

  provisioner "local-exec" {
    command = <<EOF
docker run --rm \
  -e AWS_REGION=${var.region} \
  -e AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID \
  -e AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
  -e DYNAMO_TABLE=${data.terraform_remote_state.confd.table_name} \
  -e KMS_KEY_ID=${data.terraform_remote_state.confd.key_arn} \
  ${var.dynamodb_sync_util} ruby confd-sync.rb \
  /jenkins/application/fqdn ${format("%s.%s",var.jenkins_dns,var.dns_domain)} &&
docker run --rm \
  -e AWS_REGION=${var.region} \
  -e AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID \
  -e AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
  -e DYNAMO_TABLE=${data.terraform_remote_state.confd.table_name} \
  -e KMS_KEY_ID=${data.terraform_remote_state.confd.key_arn} \
  ${var.dynamodb_sync_util} ruby confd-sync.rb \
  /jenkins/config/hash ${md5("${file("config.properties")} ${file("secret.properties")}")} &&
docker run --rm \
  -v $PWD/config.properties:/confd-sync/general.ini \
  -v $PWD/secret.properties:/confd-sync/secrets.ini \
  -e AWS_REGION=${var.region} \
  -e AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID \
  -e AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
  -e DYNAMO_TABLE=${data.terraform_remote_state.confd.table_name} \
  -e KMS_KEY_ID=${data.terraform_remote_state.confd.key_arn} \
  ${var.dynamodb_sync_util}
EOF
  }
}

# Create log group
resource "aws_cloudwatch_log_group" "jenkins" {
  name = "/${var.tags["environment"]}/jenkins"
  retention_in_days = "1"

  tags = "${var.tags}"
}

# Create SG for alb
resource "aws_security_group" "jenkins" {
  name        = "${var.tags["environment"]}-jenkins"
  vpc_id      = "${module.vpc.id}"
  description = "${var.tags["environment"]} ALB security group"

  tags = "${merge(map("Name", format("%s-jenkins", var.tags["environment"])), var.tags)}"
  lifecycle { create_before_destroy = true }

  ingress {
    protocol = "tcp"
    from_port = 80
    to_port = 80
    cidr_blocks = ["${split(",", var.default_service_ingress_rules)}"]
  }

  ingress {
    protocol = "tcp"
    from_port = 443
    to_port = 443
    cidr_blocks = ["${split(",", var.default_service_ingress_rules)}"]
  }

  egress {
    protocol    = -1
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_alb" "jenkins" {
  name            = "${var.tags["environment"]}-jenkins"
  internal        = false
  security_groups = ["${aws_security_group.jenkins.id}"]
  subnets         = ["${split(",", var.public_subnets)}"]

  access_logs {
    bucket = "alb-access-logs-012597783113"
  }

  tags = "${merge(map("Name", format("%s-jenkins", var.tags["environment"])), var.tags)}"
}

resource "aws_alb_target_group" "jenkins" {
  name     = "${var.tags["environment"]}-jenkins"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = "${module.vpc.id}"
  tags = "${merge(map("Name", format("%s-jenkins", var.tags["environment"])), var.tags)}"

  health_check {
    path = "/"
    unhealthy_threshold = "4"
    healthy_threshold   = "5"
    interval            = "30"
    timeout             = "5"
  }
}

resource "aws_alb_listener" "jenkins-http" {
   load_balancer_arn = "${aws_alb.jenkins.arn}"
   port = "80"
   protocol = "HTTP"

   default_action {
     target_group_arn = "${aws_alb_target_group.jenkins.arn}"
     type = "forward"
   }
}

resource "aws_alb_listener" "jenkins-https" {
   load_balancer_arn = "${aws_alb.jenkins.arn}"
   port = "443"
   protocol = "HTTPS"
   certificate_arn   = "arn:aws:iam::${var.aws_account_id}:server-certificate/${var.ssl_cert_name}"
   ssl_policy        = "ELBSecurityPolicy-2016-08"

   default_action {
     target_group_arn = "${aws_alb_target_group.jenkins.arn}"
     type = "forward"
   }
}

resource "aws_route53_record" "jenkins" {
  name    = "${var.jenkins_dns}"
  zone_id = "${ module.aws-r53-zone.id }"
  type    = "A"

  alias {
    name                   = "${aws_alb.jenkins.dns_name}"
    zone_id                = "${aws_alb.jenkins.zone_id}"
    evaluate_target_health = true
  }
}

data "template_file" "jenkins_task_definition" {
  template = "${file("${path.module}/task-definitions/jenkins.json")}"
  vars {
    confd_dynamo_table = "${var.tags["environment"]}"
    image = "${var.jenkins_image}"
    confd_image = "${var.confd_image}"
    environment = "${var.tags["environment"]}"
    region = "${var.region}"
    config_hash = "${md5("${file("config.properties")} ${file("secret.properties")}")}"
  }
}

resource "aws_ecs_task_definition" "jenkins" {
  depends_on = ["null_resource.confd"]
  family = "${var.tags["environment"]}-jenkins"
  container_definitions = "${data.template_file.jenkins_task_definition.rendered}"
  network_mode = "bridge"
  task_role_arn = "${aws_iam_role.jenkins_service.arn}"
}

resource "aws_iam_role" "jenkins_service" {
    name = "${var.tags["environment"]}-ecs-jenkins-service-role"
    assume_role_policy = "${file("${path.module}/policies/ecs-role.json")}"
}

data "template_file" "jenkins_service_policy" {
  template = "${file("${path.module}/policies/ecs-service-role-policy.json")}"
  vars {
    kms_arn = "${data.terraform_remote_state.confd.key_arn}"
    dynamodb_table_arn = "${data.terraform_remote_state.confd.table_arn}"
  }
}

resource "aws_iam_policy" "jenkins_service" {
    name = "${var.tags["environment"]}-ecs-jenkins-service-policy"
    description = "A policy to allow ECS workers in ${var.tags["environment"]} to do their jobs"
    policy = "${data.template_file.jenkins_service_policy.rendered}"
}

resource "aws_iam_role_policy_attachment" "jenkins_confd" {
 role = "${aws_iam_role.jenkins_service.id}"
 policy_arn = "${data.terraform_remote_state.confd.policy}"
}

resource "aws_iam_policy_attachment" "jenkins_service" {
 name = "${var.tags["environment"]}_service"
 roles = ["${aws_iam_role.jenkins_service.id}"]
 policy_arn = "${aws_iam_policy.jenkins_service.arn}"
}

resource "aws_ecs_service" "jenkins" {
  depends_on = ["aws_alb_listener.jenkins-http","aws_alb_listener.jenkins-https"]
  name = "${var.tags["environment"]}-jenkins"
  cluster = "${var.tags["environment"]}"
  task_definition = "${aws_ecs_task_definition.jenkins.arn}"
  desired_count = "1"
  iam_role = "${aws_iam_role.jenkins_service.arn}"

  load_balancer {
    target_group_arn = "${aws_alb_target_group.jenkins.arn}"
    container_name = "jenkins-app-server"
    container_port = 8080
  }

  lifecycle {
    create_before_destroy = true
  }
}
