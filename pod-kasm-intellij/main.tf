terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
    }   
  }
}

locals {
  cpu-limit = "4"
  memory-limit = "8G"
  cpu-request = "500m"
  memory-request = "1" 
  home-volume = "10Gi"
  repo = "iluwatar/java-design-patterns.git"
  image = "docker.io/marktmilligan/intellij-community-kasm:2022.3.2"
  user = "kasm-user"
}

variable "use_kubeconfig" {
  type        = bool
  sensitive   = true
  description = <<-EOF
  Use host kubeconfig? (true/false)

  Set this to false if the Coder host is itself running as a Pod on the same
  Kubernetes cluster as you are deploying workspaces to.

  Set this to true if the Coder host is running outside the Kubernetes cluster
  for workspaces.  A valid "~/.kube/config" must be present on the Coder host.
  EOF
}

variable "workspaces_namespace" {
  sensitive   = true
  description = <<-EOF
  Kubernetes namespace to deploy the workspace into

  EOF
}

provider "kubernetes" {
  # Authenticate via ~/.kube/config or a Coder-specific ServiceAccount, depending on admin preferences
  config_path = var.use_kubeconfig == true ? "~/.kube/config" : null
}

data "coder_workspace" "me" {}

variable "dotfiles_uri" {
  description = <<-EOF
  Dotfiles repo URI (optional)

  see https://dotfiles.github.io
  EOF
  default = "git@github.com:sharkymark/dotfiles.git"
}

resource "coder_agent" "coder" {
  os                      = "linux"
  arch                    = "amd64"
  dir                     = "/home/${local.user}"
  startup_script = <<EOT

#!/bin/bash

set -e

# use coder CLI to clone and install dotfiles
coder dotfiles -y ${var.dotfiles_uri} &

# clone java repo
mkdir -p ~/.ssh
ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts
git clone git@github.com:${local.repo} &

echo "starting KasmVNC"
/dockerstartup/kasm_default_profile.sh
/dockerstartup/vnc_startup.sh &

# IntelliJ needs KasmVNC fully running to start, so sleep let it complete
sleep 10

echo "starting JetBrains IntelliJ IDEA Community IDE"
/opt/idea/bin/idea.sh &

  EOT  
}

resource "coder_app" "kasm" {
  agent_id      = coder_agent.coder.id
  slug          = "kasm"  
  display_name  = "IDEA in KasmVNC"
  icon          = "/icon/intellij.svg"
  url           = "http://localhost:6901"
  subdomain = true
  share     = "owner"

  healthcheck {
    url       = "http://localhost:6901/healthz/"
    interval  = 20
    threshold = 5
  } 
}

resource "kubernetes_pod" "main" {
  count = data.coder_workspace.me.start_count
  depends_on = [
    kubernetes_persistent_volume_claim.home-directory
  ]  
  metadata {
    name = "coder-${data.coder_workspace.me.owner}-${data.coder_workspace.me.name}"
    namespace = var.workspaces_namespace
  }
  spec {
    security_context {
      run_as_user = "1000"
      fs_group    = "1000"
    }    
    container {
      name    = "coder-container"
      image   = local.image
      command = ["sh", "-c", coder_agent.coder.init_script]
      image_pull_policy = "Always"
      security_context {
        run_as_user = "1000"
      }      
      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.coder.token
      }  
      resources {
        requests = {
          cpu    = local.cpu-request
          memory = local.memory-request
        }        
        limits = {
          cpu    = local.cpu-limit
          memory = local.memory-limit
        }
      }                       
      volume_mount {
        mount_path = "/home/${local.user}"
        name       = "home-directory"
      }      
    }
    volume {
      name = "home-directory"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim.home-directory.metadata.0.name
      }
    }        
  }
}

resource "kubernetes_persistent_volume_claim" "home-directory" {
  metadata {
    name      = "home-coder-${data.coder_workspace.me.owner}-${data.coder_workspace.me.name}"
    namespace = var.workspaces_namespace
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = local.home-volume
      }
    }
  }
}

resource "coder_metadata" "workspace_info" {
  count       = data.coder_workspace.me.start_count
  resource_id = kubernetes_pod.main[0].id
  item {
    key   = "CPU"
    value = "${local.cpu-limit} cores"
  }
  item {
    key   = "memory"
    value = "${local.memory-limit}"
  }  
  item {
    key   = "disk"
    value = "${local.home-volume}"
  }
  item {
    key   = "image"
    value = local.image
  }
  item {
    key   = "volume"
    value = kubernetes_pod.main[0].spec[0].container[0].volume_mount[0].mount_path
  } 
}