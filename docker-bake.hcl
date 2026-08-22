variable "REGISTRY" { default = "ghcr.io/lkshrk/auto-code-env" }
variable "DEBIAN_IMAGE" { default = "debian:trixie-slim@sha256:3a39a0592364683e6bab97937b72cad5a8fa6dcbbee90edb3bb48c7f8e94f258" }
variable "DOTFILES_COMMIT" { default = "6342c6edad63dbf35653a354bb920234dca5b0cd" }
variable "DOTFILES_REF" { default = "main" }
variable "OMNI_VERSION" { default = "0.9.32" }
variable "OMNI_AMD64_SHA256" { default = "9d2369d5f73622834fb8cf7f15baf2ac5417274a9f49856cf380a8758ad8dbaf" }
variable "OMNI_ARM64_SHA256" { default = "64c9e1997b5b5a48a0067344bb154c61d90db0b560a6cddc978ba3d3f3c441cb" }
variable "DOCKER_VERSION" { default = "29.7.2" }
variable "DOCKER_AMD64_SHA256" { default = "803d433f226db4776e1768fd319fc6c6e4935a456acf84fcc0080818b854bc8f" }
variable "DOCKER_ARM64_SHA256" { default = "43d143448adf2c2787704e7d7704fd6d62d367a54c5edaef0a3f75509cb0938d" }
variable "BUILDX_VERSION" { default = "0.36.1" }
variable "BUILDX_AMD64_SHA256" { default = "48af8a397ebd60178778bf63611dbcebe5f5e7a9be90eb9147b24b9587455778" }
variable "BUILDX_ARM64_SHA256" { default = "5d0cafd9d16afe1a0f0d9529885344ace2cc99efdd531b6c783c5455a6001569" }
variable "COMPOSE_VERSION" { default = "2.39.2" }
variable "COMPOSE_AMD64_SHA256" { default = "a55a8cd4ef103aac282812554e531aac8df7e914a287ee81e14d695556a22902" }
variable "COMPOSE_ARM64_SHA256" { default = "54488fffb60782f3c8787a48b95ed15f49f5a3a85f4105304bd46db5edd9db61" }
variable "PNPM_VERSION" { default = "11.22.0" }
variable "CLAUDE_CODE_VERSION" { default = "2.1.239" }
variable "CODEX_VERSION" { default = "0.149.0" }
variable "HERDR_VERSION" { default = "0.8.2" }
variable "HERMES_VERSION" { default = "0.18.2" }
variable "HERMES_REF" { default = "v2026.7.7.2" }
variable "HERMES_COMMIT" { default = "9de9c25f620ff7f1ce0fd5457d596052d5159596" }
variable "HERMES_INSTALLER_SHA256" { default = "a93c65b01ea392e179cf872e182bd01a2b65c0c15f17833e9f9569033ef10e07" }
variable "LAZYGIT_VERSION" { default = "0.64.1" }
variable "PILOT_VERSION" { default = "2.264.0-fork.1" }
variable "PILOT_AMD64_SHA256" { default = "501709602b6620cef58b29d32fb38c988af782623615a25a554081b2984b3e69" }
variable "PILOT_ARM64_SHA256" { default = "de6e305f4a2aec4cc0652da524dcf4f440617e5a947dbfebc1539655f497adab" }

target "common" {
  context = "."
  dockerfile = "Dockerfile"
  platforms = ["linux/amd64", "linux/arm64"]
  args = {
    DEBIAN_IMAGE = DEBIAN_IMAGE
    DOTFILES_REF = DOTFILES_REF
    DOTFILES_COMMIT = DOTFILES_COMMIT
    OMNI_VERSION = OMNI_VERSION
    OMNI_AMD64_SHA256 = OMNI_AMD64_SHA256
    OMNI_ARM64_SHA256 = OMNI_ARM64_SHA256
    DOCKER_VERSION = DOCKER_VERSION
    DOCKER_AMD64_SHA256 = DOCKER_AMD64_SHA256
    DOCKER_ARM64_SHA256 = DOCKER_ARM64_SHA256
    BUILDX_VERSION = BUILDX_VERSION
    BUILDX_AMD64_SHA256 = BUILDX_AMD64_SHA256
    BUILDX_ARM64_SHA256 = BUILDX_ARM64_SHA256
    COMPOSE_VERSION = COMPOSE_VERSION
    COMPOSE_AMD64_SHA256 = COMPOSE_AMD64_SHA256
    COMPOSE_ARM64_SHA256 = COMPOSE_ARM64_SHA256
    PNPM_VERSION = PNPM_VERSION
    CLAUDE_CODE_VERSION = CLAUDE_CODE_VERSION
    CODEX_VERSION = CODEX_VERSION
    HERDR_VERSION = HERDR_VERSION
    HERMES_VERSION = HERMES_VERSION
    HERMES_REF = HERMES_REF
    HERMES_COMMIT = HERMES_COMMIT
    HERMES_INSTALLER_SHA256 = HERMES_INSTALLER_SHA256
    LAZYGIT_VERSION = LAZYGIT_VERSION
    PILOT_VERSION = PILOT_VERSION
    PILOT_AMD64_SHA256 = PILOT_AMD64_SHA256
    PILOT_ARM64_SHA256 = PILOT_ARM64_SHA256
  }
}

target "dev-full" {
  inherits = ["common"]
  target = "dev-full"
  tags = ["${REGISTRY}:dev-full"]
}

target "dev-pilot" {
  inherits = ["common"]
  target = "dev-pilot"
  tags = ["${REGISTRY}:dev-pilot"]
}

target "dev-hermes" {
  inherits = ["common"]
  target = "dev-hermes"
  tags = ["${REGISTRY}:dev-hermes"]
}

target "dev-both" {
  inherits = ["common"]
  target = "dev-both"
  tags = ["${REGISTRY}:dev-both"]
}

group "default" { targets = ["dev-full", "dev-pilot", "dev-hermes", "dev-both"] }
