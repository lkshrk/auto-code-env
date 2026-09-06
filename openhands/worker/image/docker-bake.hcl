variable "VERSION" {
  default = ""
}

target "image" {
  context    = "."
  dockerfile = "openhands/worker/image/Containerfile"
  target     = "oci"
  platforms  = ["linux/amd64", "linux/arm64"]
  tags       = ["ghcr.io/lkshrk/openhands-worker:${VERSION}"]
  args       = { OPENHANDS_WORKER_VERSION = "${VERSION}" }
}

target "wsl-amd64" {
  context    = "."
  dockerfile = "openhands/worker/image/Containerfile"
  target     = "wsl"
  platforms  = ["linux/amd64"]
  args       = { OPENHANDS_WORKER_VERSION = "${VERSION}" }
}

target "wsl-arm64" {
  context    = "."
  dockerfile = "openhands/worker/image/Containerfile"
  target     = "wsl"
  platforms  = ["linux/arm64"]
  args       = { OPENHANDS_WORKER_VERSION = "${VERSION}" }
}
