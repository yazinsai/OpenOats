#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <version> <sha256>" >&2
  exit 1
fi

VERSION="$1"
SHA256="$2"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CASK_PATH="$ROOT_DIR/Casks/openoats.rb"

if [[ ! -f "$CASK_PATH" ]]; then
  echo "Cask not found at $CASK_PATH" >&2
  exit 1
fi

/usr/bin/ruby - "$CASK_PATH" "$VERSION" "$SHA256" <<'RUBY'
path, version, sha256 = ARGV
contents = File.read(path)
contents.sub!(/version\s+"[^"]+"/, %(version "#{version}"))
contents.sub!(/sha256\s+"[^"]+"/, %(sha256 "#{sha256}"))
File.write(path, contents)
RUBY
