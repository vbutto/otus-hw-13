########################################
# Роли для сервисного аккаунта terraform
# compute.admin
# iam.serviceAccounts.admin
# kms.admin
# resource-manager.admin
# vpc.admin
########################################



########################################
# СЕРВИСНЫЕ АККАУНТЫ (базовые роли для IaC, S3 и CI/CD)
########################################

# SA для Kubernetes (рабочие процессы/поды; получит puller + editor)
resource "yandex_iam_service_account" "sa" {
  folder_id = var.folder_id
  name      = "k8s-root-sa"
}

# SA для администрирования Object Storage (storage.admin)
resource "yandex_iam_service_account" "s3acc" {
  folder_id = var.folder_id
  name      = "s3-storage-admin"
}

# SA для CI/CD (права пуша образов, ключи при необходимости)
resource "yandex_iam_service_account" "ci_cd_acc" {
  folder_id = var.folder_id
  name      = "ci-cd-acc"
}

# Отдельный SA для пуша образов в реестр
resource "yandex_iam_service_account" "sa_pusher" {
  folder_id = var.folder_id
  name      = "registry-pusher"
}

# Пауза для консистентности IAM после создания SA
resource "time_sleep" "after_service_accounts" {
  depends_on = [
    yandex_iam_service_account.sa,
    yandex_iam_service_account.s3acc,
    yandex_iam_service_account.ci_cd_acc,
    yandex_iam_service_account.sa_pusher
  ]
  create_duration = "20s"
}

########################################
# КЛЮЧИ ДОСТУПА
########################################
# Статический ключ именно для S3-админа (storage.admin)
resource "yandex_iam_service_account_static_access_key" "s3_static_key" {
  service_account_id = yandex_iam_service_account.s3acc.id
  description        = "static access key for Object Storage admin (buckets/objects)"
  depends_on         = [time_sleep.after_service_accounts]
}

########################################
# КРИПТО (KMS): ключ для шифрования артефактов/логов
########################################
resource "yandex_kms_symmetric_key" "lz_kms" {
  name              = "lz-kms-key"
  description       = "KMS key for training Landing Zone (S3/logs/artifacts)"
  default_algorithm = "AES_256"
  rotation_period   = "8760h" # 1 год
  folder_id         = var.folder_id
}

########################################
# ОБЪЕКТНОЕ ХРАНИЛИЩЕ (бакет для логов/артефактов)
########################################
resource "yandex_storage_bucket" "lz_logs_bucket" {
  bucket     = "lz-${var.folder_id}-logs" # уникально в YC S3 namespace
  access_key = yandex_iam_service_account_static_access_key.s3_static_key.access_key
  secret_key = yandex_iam_service_account_static_access_key.s3_static_key.secret_key

  force_destroy = true # для учебных целей
  versioning {
    enabled = true
  }
}

########################################
# СЕТЬ (VPC): базовая сеть + подсети в ru-central1-a/b, интернет-шлюз и маршруты
########################################
# VPC
resource "yandex_vpc_network" "lz_vpc" {
  name = "lz-vpc"
}

# Интернет-шлюз (NAT GW managed by YC)
resource "yandex_vpc_gateway" "internet_gw" {
  name = "lz-internet-gw"
  shared_egress_gateway {}
}

# Таблица маршрутизации c дефолтным маршрутом в интернет
resource "yandex_vpc_route_table" "lz_rt" {
  network_id = yandex_vpc_network.lz_vpc.id
  static_route {
    destination_prefix = "0.0.0.0/0"
    gateway_id         = yandex_vpc_gateway.internet_gw.id
  }
}

# Подсеть A (с привязанной таблицей маршрутов)
resource "yandex_vpc_subnet" "lz_subnet_a" {
  name           = "lz-subnet-a"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.lz_vpc.id
  v4_cidr_blocks = [var.network_cidr_a]
  route_table_id = yandex_vpc_route_table.lz_rt.id
}

# Подсеть B (с привязанной таблицей маршрутов)
resource "yandex_vpc_subnet" "lz_subnet_b" {
  name           = "lz-subnet-b"
  zone           = "ru-central1-b"
  network_id     = yandex_vpc_network.lz_vpc.id
  v4_cidr_blocks = [var.network_cidr_b]
  route_table_id = yandex_vpc_route_table.lz_rt.id
}

########################################
# БЕЗОПАСНОСТЬ СЕТИ: базовая Security Group (SSH/HTTP из интернета, всё внутри VPC)
########################################
resource "yandex_vpc_security_group" "lz_sg_base" {
  name       = "lz-base-sg"
  network_id = yandex_vpc_network.lz_vpc.id
  labels = {
    env = "training"
  }

  # Разрешить весь внутренний трафик в пределах VPC (east-west)
  ingress {
    protocol       = "ANY"
    v4_cidr_blocks = ["10.0.0.0/8"]
    description    = "intra-VPC traffic"
  }

  egress {
    protocol       = "ANY"
    v4_cidr_blocks = ["10.0.0.0/8"]
    description    = "intra-VPC traffic"
  }

  # Входящий SSH из интернета
  ingress {
    protocol       = "TCP"
    port           = 22
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  # Входящий HTTP
  ingress {
    protocol       = "TCP"
    port           = 80
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  # Исходящий трафик в интернет
  egress {
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

########################################
# НАЗНАЧЕНИЕ РОЛЕЙ
########################################

# Полный доступ к Object Storage для s3acc (администрирование бакетов/объектов)
resource "yandex_resourcemanager_folder_iam_binding" "storage_admin" {
  folder_id = var.folder_id
  role      = "storage.admin"
  members = [
    "serviceAccount:${yandex_iam_service_account.s3acc.id}",
  ]
  depends_on = [time_sleep.after_service_accounts]
}

# Редакторские права для Kubernetes SA (создание/управление ресурсами в папке)
resource "yandex_resourcemanager_folder_iam_binding" "editor" {
  folder_id = var.folder_id
  role      = "editor"
  members = [
    "serviceAccount:${yandex_iam_service_account.sa.id}",
  ]
  depends_on = [time_sleep.after_service_accounts]
}

# Доступ на вытягивание образов (k8s SA)
resource "yandex_resourcemanager_folder_iam_binding" "cr_images_puller" {
  folder_id = var.folder_id
  role      = "container-registry.images.puller"
  members = [
    "serviceAccount:${yandex_iam_service_account.sa.id}",
  ]
  depends_on = [time_sleep.after_service_accounts]
}

# Доступ на пуш образов (CI/CD и отдельный pusher)
resource "yandex_resourcemanager_folder_iam_binding" "cr_images_pusher" {
  folder_id = var.folder_id
  role      = "container-registry.images.pusher"
  members = [
    "serviceAccount:${yandex_iam_service_account.ci_cd_acc.id}",
    "serviceAccount:${yandex_iam_service_account.sa_pusher.id}",
  ]
  depends_on = [time_sleep.after_service_accounts]
}

########################################
# ОБРАЗ ДЛЯ БАСТИОНА (Ubuntu 22.04 LTS)
########################################
data "yandex_compute_image" "ubuntu_2204" {
  family = "ubuntu-2204-lts"
}

########################################
# SECURITY GROUP ДЛЯ БАСТИОНА (строже, чем базовая)
########################################
resource "yandex_vpc_security_group" "lz_sg_bastion" {
  name       = "lz-bastion-sg"
  network_id = yandex_vpc_network.lz_vpc.id
  labels     = { role = "bastion" }

  # SSH из разрешённого диапазона
  ingress {
    protocol       = "TCP"
    port           = 22
    v4_cidr_blocks = [var.allowed_ssh_cidr]
    description    = "SSH to bastion"
  }

  # Доступ с бастиона внутрь VPC (любой протокол)
  egress {
    protocol       = "ANY"
    v4_cidr_blocks = ["10.0.0.0/8"]
    description    = "From bastion to VPC"
  }

  # Исходящий трафик в Интернет (обновления, пакеты)
  egress {
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
    description    = "Bastion outbound to Internet"
  }
}

########################################
# ПУБЛИЧНЫЙ IP ДЛЯ БАСТИОНА (статический)
########################################
resource "yandex_vpc_address" "bastion_pub_ip" {
  name = "${var.bastion_name}-public-ip"
  external_ipv4_address {
    zone_id = var.bastion_zone
  }
}

########################################
# ЛОКАЛЫ: выбор подсети для бастиона по зоне
########################################
locals {
  bastion_subnet_id = var.bastion_zone == "ru-central1-b" ? yandex_vpc_subnet.lz_subnet_b.id : yandex_vpc_subnet.lz_subnet_a.id
}

########################################
# ВМ-БАСТИОН
########################################
resource "yandex_compute_instance" "bastion" {
  name        = var.bastion_name
  platform_id = "standard-v3"
  zone        = var.bastion_zone

  resources {
    cores         = 2
    memory        = 2
    core_fraction = 20
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu_2204.id
      size     = 20
      type     = "network-ssd"
    }
  }

  network_interface {
    subnet_id          = local.bastion_subnet_id
    security_group_ids = [yandex_vpc_security_group.lz_sg_bastion.id]
    nat                = true
    nat_ip_address     = yandex_vpc_address.bastion_pub_ip.external_ipv4_address[0].address
  }

  metadata = {
    ssh-keys = "${var.ssh_username}:${var.ssh_public_key}"
    # user-data = file("cloud-init-bastion.yaml")
  }

  scheduling_policy {
    preemptible = false
  }

  depends_on = [
    yandex_vpc_subnet.lz_subnet_a,
    yandex_vpc_subnet.lz_subnet_b,
    yandex_vpc_security_group.lz_sg_bastion
  ]
}

########################################
# ВЫВОДЫ ДЛЯ БЫСТРОГО ДОСТУПА
########################################
output "bastion_public_ip" {
  value       = yandex_vpc_address.bastion_pub_ip.external_ipv4_address[0].address
  description = "Публичный IP бастиона"
}

output "bastion_private_ip" {
  value       = yandex_compute_instance.bastion.network_interface[0].ip_address
  description = "Приватный IP бастиона"
}

output "bastion_ssh_example" {
  value       = "ssh -i ~/.ssh/id_rsa ${var.ssh_username}@${yandex_vpc_address.bastion_pub_ip.external_ipv4_address[0].address}"
  description = "Пример SSH-команды"
}

########################################
# ВЫВОДЫ (Outputs) — полезные ID/параметры
########################################
output "lz_vpc_id" {
  value       = yandex_vpc_network.lz_vpc.id
  description = "ID созданной VPC"
}

output "lz_subnets" {
  value = {
    a = yandex_vpc_subnet.lz_subnet_a.id
    b = yandex_vpc_subnet.lz_subnet_b.id
  }
  description = "ID подсетей по зонам"
}

output "kms_key_id" {
  value       = yandex_kms_symmetric_key.lz_kms.id
  description = "ID симметричного KMS ключа"
}

output "logs_bucket" {
  value       = yandex_storage_bucket.lz_logs_bucket.bucket
  description = "Имя бакета для логов/артефактов"
}
