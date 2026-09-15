#!/bin/bash
set -euo pipefail
if [[ -x "${CARGO_HOME:-$HOME/.cargo}/bin/cargo-about" ]]; then
  export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"
fi

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tauri_root="$project_root/src-tauri"
output_dir="$tauri_root/resources/Legal"
rust_report="$output_dir/RUST_THIRD_PARTY_LICENSES.html"
npm_report="$output_dir/NPM_THIRD_PARTY_LICENSES.html"
required_cargo_about_version="cargo-about 0.9.2"

fail() {
  echo "[third-party-licenses] FAIL: $*" >&2
  exit 1
}

require_report_contents() {
  local report=$1
  shift
  [[ -s "$report" ]] || fail "报告不存在或为空：$report"
  if rg -q '/Users/|/\.cargo/|/private/' "$report"; then
    fail "报告包含本机绝对路径，禁止打包：$report"
  fi

  local expected
  for expected in "$@"; do
    rg -q --fixed-strings "$expected" "$report" \
      || fail "报告 $report 缺少生产依赖：$expected"
  done
}

verify_reports() {
  local legal_dir=$1
  local expected_cargo_lock_sha256=$2
  local expected_npm_lock_sha256=$3
  require_report_contents \
    "$legal_dir/RUST_THIRD_PARTY_LICENSES.html" \
    "Cargo.lock SHA-256: <code>$expected_cargo_lock_sha256</code>" \
    "cssparser 0.36.0" \
    "cssparser-macros 0.6.1" \
    "dtoa-short 0.3.5" \
    "option-ext 0.2.0" \
    "selectors 0.36.1" \
    "encoding_rs 0.8.35" \
    "alloc-no-stdlib 2.0.4" \
    "alloc-stdlib 0.2.4" \
    "brotli 8.0.4" \
    "brotli-decompressor 5.0.3"
  require_report_contents \
    "$legal_dir/NPM_THIRD_PARTY_LICENSES.html" \
    "package-lock.json SHA-256 <code>$expected_npm_lock_sha256</code>" \
    "@tauri-apps/api 2.11.1" \
    "@tauri-apps/plugin-dialog 2.7.2" \
    "@tauri-apps/plugin-opener 2.5.4" \
    "@tauri-apps/plugin-shell 2.3.5" \
    "react 19.2.7" \
    "react-dom 19.2.7" \
    "scheduler 0.27.0"
}

command -v rg >/dev/null 2>&1 || fail "缺少 ripgrep (rg)"
command -v shasum >/dev/null 2>&1 || fail "缺少 shasum"
[[ -f "$tauri_root/Cargo.lock" ]] || fail "缺少 src-tauri/Cargo.lock"
[[ -f "$project_root/package-lock.json" ]] || fail "缺少 package-lock.json"
current_cargo_lock_sha256=$(shasum -a 256 "$tauri_root/Cargo.lock" | awk '{print $1}')
current_npm_lock_sha256=$(shasum -a 256 "$project_root/package-lock.json" | awk '{print $1}')

if [[ ${1:-} == "--verify-app" ]]; then
  [[ $# -eq 2 ]] || fail "用法：$0 --verify-app /path/to/Lives.app"
  verify_reports \
    "$2/Contents/Resources/Legal" \
    "$current_cargo_lock_sha256" \
    "$current_npm_lock_sha256"
  echo "[third-party-licenses] PASS: App 内 Rust 与 npm 完整许可报告已验证"
  exit 0
fi

[[ $# -eq 0 ]] || fail "未知参数：$*"
command -v cargo-about >/dev/null 2>&1 \
  || fail "缺少 cargo-about 0.9.2。请先执行：cargo install --locked --features cli --version 0.9.2 cargo-about"
cargo_about_version=$(cargo about --version 2>/dev/null || true)
[[ "$cargo_about_version" == "$required_cargo_about_version" ]] \
  || fail "cargo-about 版本不匹配：期望 $required_cargo_about_version，实际 ${cargo_about_version:-无法读取}"
command -v node >/dev/null 2>&1 || fail "缺少 Node.js"
command -v npm >/dev/null 2>&1 || fail "缺少 npm"
[[ -d "$project_root/node_modules" ]] \
  || fail "缺少 node_modules；请先使用 npm ci 按 package-lock.json 安装依赖"

temporary_dir=$(mktemp -d /private/tmp/lives-third-party-licenses.XXXXXX)
cleanup() {
  rm -rf -- "$temporary_dir"
}
trap cleanup EXIT

rust_temporary="$temporary_dir/RUST_THIRD_PARTY_LICENSES.html"
npm_temporary="$temporary_dir/NPM_THIRD_PARTY_LICENSES.html"

cargo about generate \
  --fail \
  --locked \
  --manifest-path "$tauri_root/Cargo.toml" \
  --config "$tauri_root/about.toml" \
  --output-file "$rust_temporary" \
  "$tauri_root/about.hbs"

node --input-type=commonjs - "$rust_temporary" "$current_cargo_lock_sha256" <<'NODE'
const fs = require("node:fs");

const [, , reportPath, lockHash] = process.argv;
const placeholder = "__CARGO_LOCK_SHA256__";
const report = fs.readFileSync(reportPath, "utf8");
if (report.split(placeholder).length !== 2) {
  throw new Error(`Rust license report must contain exactly one ${placeholder} placeholder`);
}
fs.writeFileSync(reportPath, report.replace(placeholder, lockHash), "utf8");
NODE

node --input-type=commonjs - "$project_root" "$npm_temporary" <<'NODE'
const childProcess = require("node:child_process");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const [, , projectRoot, outputPath] = process.argv;
const rootManifest = JSON.parse(fs.readFileSync(path.join(projectRoot, "package.json"), "utf8"));
const lockContents = fs.readFileSync(path.join(projectRoot, "package-lock.json"));
const lock = JSON.parse(lockContents);

const npmTree = childProcess.execFileSync(
  "npm",
  ["ls", "--omit=dev", "--all", "--parseable"],
  { cwd: projectRoot, encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] },
);

const packagePaths = [...new Set(npmTree.split(/\r?\n/).filter(Boolean).map((entry) => path.resolve(entry)))]
  .filter((entry) => entry !== path.resolve(projectRoot));

if (packagePaths.length === 0) {
  throw new Error("npm production dependency tree is empty");
}

const licenseNamePattern = /^(licen[sc]e|copying|notice)(?:[._-].*)?$/i;
const packages = packagePaths.map((packagePath) => {
  const manifestPath = path.join(packagePath, "package.json");
  if (!fs.existsSync(manifestPath)) {
    throw new Error(`missing package manifest: ${manifestPath}`);
  }

  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  const lockKey = path.relative(projectRoot, packagePath).split(path.sep).join("/");
  const lockedPackage = lock.packages?.[lockKey];
  if (!lockedPackage || lockedPackage.version !== manifest.version) {
    throw new Error(`installed package does not match package-lock.json: ${manifest.name}@${manifest.version} (${lockKey})`);
  }
  const declaredLicense = typeof manifest.license === "string"
    ? manifest.license
    : JSON.stringify(manifest.license ?? manifest.licenses ?? "");
  if (!manifest.name || !manifest.version || !declaredLicense) {
    throw new Error(`incomplete license metadata: ${manifestPath}`);
  }
  const approvedLicenseExpressions = new Set([
    "MIT",
    "Apache-2.0",
    "MIT OR Apache-2.0",
    "Apache-2.0 OR MIT",
  ]);
  if (!approvedLicenseExpressions.has(declaredLicense.trim())) {
    throw new Error(`unreviewed production dependency license: ${manifest.name}@${manifest.version} (${declaredLicense})`);
  }

  const licenseFiles = fs.readdirSync(packagePath)
    .filter((name) => licenseNamePattern.test(name))
    .filter((name) => fs.statSync(path.join(packagePath, name)).isFile())
    .sort();
  if (licenseFiles.length === 0) {
    throw new Error(`no LICENSE/COPYING/NOTICE file in ${packagePath}`);
  }

  return {
    name: manifest.name,
    version: manifest.version,
    declaredLicense,
    repository: typeof manifest.repository === "string"
      ? manifest.repository
      : manifest.repository?.url ?? manifest.homepage ?? "",
    licenseFiles: licenseFiles.map((name) => ({
      name,
      text: fs.readFileSync(path.join(packagePath, name), "utf8"),
    })),
  };
}).sort((left, right) => `${left.name}@${left.version}`.localeCompare(`${right.name}@${right.version}`));

const discoveredNames = new Set(packages.map(({ name }) => name));
const requiredNames = new Set([
  ...Object.keys(rootManifest.dependencies ?? {}),
  "scheduler",
]);
for (const name of requiredNames) {
  if (!discoveredNames.has(name)) {
    throw new Error(`required production dependency is absent from npm report: ${name}`);
  }
}

const escapeHtml = (value) => String(value)
  .replaceAll("&", "&amp;")
  .replaceAll("<", "&lt;")
  .replaceAll(">", "&gt;")
  .replaceAll('"', "&quot;");

const lockHash = crypto.createHash("sha256").update(lockContents).digest("hex");
const output = [
  "<!doctype html>",
  '<html lang="en"><head><meta charset="utf-8">',
  '<meta name="viewport" content="width=device-width, initial-scale=1">',
  "<title>Lives npm Production Dependency Licenses</title>",
  "<style>body{font:15px/1.5 -apple-system,BlinkMacSystemFont,sans-serif;margin:2rem auto;max-width:980px;padding:0 1rem}pre{border:1px solid #ccc;border-radius:6px;max-height:28rem;overflow:auto;padding:1rem;white-space:pre-wrap}</style>",
  "</head><body><main>",
  "<h1>Lives npm Production Dependency Licenses</h1>",
  `<p>Generated from package-lock.json SHA-256 <code>${lockHash}</code>. Development-only dependencies are excluded.</p>`,
  `<p>Production packages: ${packages.length}. Package declarations and every distributed LICENSE, COPYING, or NOTICE file follow.</p>`,
];

for (const pkg of packages) {
  output.push(`<section><h2>${escapeHtml(pkg.name)} ${escapeHtml(pkg.version)}</h2>`);
  output.push(`<p>Declared license: <code>${escapeHtml(pkg.declaredLicense)}</code></p>`);
  if (pkg.repository) output.push(`<p>Upstream: ${escapeHtml(pkg.repository)}</p>`);
  for (const licenseFile of pkg.licenseFiles) {
    output.push(`<h3>${escapeHtml(licenseFile.name)}</h3>`);
    output.push(`<pre>${escapeHtml(licenseFile.text)}</pre>`);
  }
  output.push("</section>");
}

output.push("</main></body></html>");
fs.writeFileSync(outputPath, `${output.join("\n")}\n`, "utf8");
NODE

verify_reports \
  "$temporary_dir" \
  "$current_cargo_lock_sha256" \
  "$current_npm_lock_sha256"
mkdir -p "$output_dir"
mv "$rust_temporary" "$rust_report"
mv "$npm_temporary" "$npm_report"
echo "[third-party-licenses] PASS: 已生成 Rust 与 npm 生产依赖许可报告"
