#!/usr/bin/env bash
# 自建测试 runner：本机 SwiftPM 不可用（CLT 缺 Platforms），直接用 swiftc 编译运行测试。
# App/ 下有顶层代码的 main.swift，与测试入口冲突，编译时排除。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BUILD_DIR="$ROOT_DIR/build"
mkdir -p "$BUILD_DIR"

sources=()
while IFS= read -r file; do
  sources+=("$file")
done < <(find "$ROOT_DIR/src/iCut" -name '*.swift' ! -path '*/App/*' -print)

tests=()
while IFS= read -r file; do
  tests+=("$file")
done < <(find "$ROOT_DIR/tests/iCutTests" -name '*.swift' -print)

if [[ ${#tests[@]} -eq 0 ]]; then
  echo "error: tests/iCutTests 下没有测试文件" >&2
  exit 1
fi

echo "==> 编译（${#sources[@]} 个源文件 + ${#tests[@]} 个测试文件）"
swiftc -O -target "$(uname -m)-apple-macosx13.0" -o "$BUILD_DIR/iCutTests" "${sources[@]}" "${tests[@]}"

echo "==> 运行"
"$BUILD_DIR/iCutTests"
