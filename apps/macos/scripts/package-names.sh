#!/bin/bash
# Package names distinguish the macOS 14+ update from older Mac releases.
# Keep the disk image name stable for the existing website and manual installs.
typeleast_macos_dmg_name() {
  printf 'TypeLeast-%s-macOS-%s.dmg' "$1" "$2"
}
typeleast_macos_zip_name() {
  printf 'TypeLeast-%s-macOS14-%s.zip' "$1" "$2"
}
typeleast_macos_legacy_zip_name() {
  printf 'TypeLeast-%s-macOS-%s.zip' "$1" "$2"
}
