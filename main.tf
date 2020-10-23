provider "google" {
  project     = "rebrain"
  region      = "europe-west1"
  zone        = "europe-west1-b"
  credentials = file("key.json")
}

provider "aws" {
  region     = "eu-west-1"
  access_key = var.access_key
  secret_key = var.secret_key
}

data "aws_route53_zone" "devops" {
  name = "devops.rebrain.srwx.net."
}

resource "aws_route53_record" "domains" {
  count   = var.domains_number
  zone_id = data.aws_route53_zone.devops.zone_id
  name    = "${split(", ", element(var.domains, count.index))[0]}.${data.aws_route53_zone.devops.name}"
  type    = "A"
  ttl     = "30"
  records = [google_compute_global_address.default.address]
}

resource "google_compute_global_address" "default" {
  name = "for-website"
}

resource "google_compute_global_forwarding_rule" "default" {
  name       = "oleg-forwarding-rule"
  ip_address = google_compute_global_address.default.address
  target     = google_compute_target_http_proxy.default.id
  port_range = "80"
}

resource "google_compute_target_http_proxy" "default" {
  name    = "oleg-http-proxy"
  url_map = google_compute_url_map.default.id
}

resource "google_compute_url_map" "default" {
  name            = "oleg-url-map"
  description     = "URL map to route requests to a backend service"
  default_service = google_compute_backend_service.default.id

  host_rule {
  hosts        = ["oleg-karagezov.devops.rebrain.srwx.net"]
  path_matcher = "allpaths"
  }

  path_matcher {
  name            = "allpaths"
  default_service = google_compute_backend_service.default.id

    path_rule {
    paths   = ["/*"]
    service = google_compute_backend_service.default.id
    }
  }
}

resource "google_compute_backend_service" "default" {
  name        = "oleg-backend"
  port_name   = "http"
  protocol    = "HTTP"
  timeout_sec = 10

  backend {
    group = google_compute_instance_group.default.self_link
  }

  health_checks = [google_compute_http_health_check.health_check.id]
}

resource "google_compute_instance_group" "default" {
  name      = "web-servers-instance-group"
  zone      = "europe-west1-b"
  instances = [google_compute_instance.default.id]
  named_port {
    name = "http"
    port = "80"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_http_health_check" "health_check" {
  name               = "oleg-health-check"
  check_interval_sec = 1
  timeout_sec        = 1
  port               = 80
}

resource "google_compute_address" "static_ip_address" {
  name = "my-static-address"
}

resource "google_compute_instance" "default" {
  project      = "rebrain"
  name         = "oleg-karagezov-backend"
  machine_type = "n1-standard-1"
  zone         = "europe-west1-b"

  network_interface {
    network = "default"

    access_config {
      nat_ip = google_compute_address.static_ip_address.address
    }
  }

  boot_disk {
    initialize_params {
      image = "centos-cloud/centos-8"
    }
  }

  metadata_startup_script = "sed -i 's/PermitRootLogin no/PermitRootLogin yes/g' /etc/ssh/sshd_config; systemctl restart sshd; setenforce Permissive"

  metadata = {
    ssh-keys = "root:${file("~/.ssh/id_rsa.pub")}"
  }
}

output "external_VPS_IP" {
  description = "external_VPS_IP"
  value = google_compute_instance.default.network_interface[0].access_config.*.nat_ip
}

output "load-balancer-ip-address" {
  description = "load-balancer-ip-address"
  value = google_compute_global_forwarding_rule.default.ip_address
}

data "template_file" "ansible_inventory" {
  template = "${file("inventory.tmpl")}"
  vars = {
    app_hostname = join("\n",google_compute_instance.default.network_interface[0].access_config.*.nat_ip)
  }
}

resource "local_file" "ansible_inventory" {
  content  = data.template_file.ansible_inventory.rendered
  file_permission = "0644"
  filename = "hosts"
  provisioner "local-exec" {
    command = "sleep 60 && ansible-playbook -i hosts playbook.yml"
  }
}
