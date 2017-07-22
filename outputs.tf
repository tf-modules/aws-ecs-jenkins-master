output "alb_url" {
  value = "${aws_alb.jenkins.dns_name}"
}

output "cidrs_allowed_ingress_to_service" {
  value = "${var.default_service_ingress_rules}"
}
