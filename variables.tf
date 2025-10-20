# ============================================================================
# Основные переменные
# ============================================================================

variable "cloud_id" {
  description = "Yandex Cloud cloud ID"
  type        = string
}

variable "folder_id" {
  description = "Yandex Cloud folder ID"
  type        = string
}

variable "zone" {
  description = "Default availability zone"
  type        = string
  default     = "ru-central1-a"
}

variable "network_cidr_a" {
  description = "CIDR подсети в ru-central1-a"
  type        = string
  default     = "10.10.1.0/24"
}

variable "network_cidr_b" {
  description = "CIDR подсети в ru-central1-b"
  type        = string
  default     = "10.10.2.0/24"
}

variable "sa_key_file" {
  description = "Path to service account key JSON file"
  type        = string
}

# ============================================================================
# Настройки доступа
# ============================================================================

variable "ssh_public_key" {
  description = "SSH public key content (not path to file)"
  type        = string
  sensitive   = true
}

variable "my_ip" {
  description = "Your IP address in CIDR format for SSH access (e.g., 1.2.3.4/32). Leave empty to disable SSH"
  type        = string
  default     = ""
}


########################################
# ПАРАМЕТРЫ БАСТИОНА
########################################
variable "bastion_zone" {
  description = "Зона размещения бастиона"
  type        = string
  default     = "ru-central1-a"
}

variable "bastion_name" {
  description = "Имя ВМ бастиона"
  type        = string
  default     = "lz-bastion"
}

variable "ssh_username" {
  description = "Linux-пользователь для SSH"
  type        = string
  default     = "ubuntu"
}

variable "allowed_ssh_cidr" {
  description = "Откуда разрешать SSH на бастион"
  type        = string
  default     = "0.0.0.0/0" # скорректировать под свою сеть
}
