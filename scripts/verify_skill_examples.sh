#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKILL_NAME="$(basename "${SKILL_DIR}")"

PASS_COUNT=0
SKIP_COUNT=0
FAIL_COUNT=0

pass() {
  echo "[PASS] $1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

skip() {
  echo "[SKIP] $1"
  SKIP_COUNT=$((SKIP_COUNT + 1))
}

fail() {
  echo "[FAIL] $1" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

echo "=== Verifying Antigravity Skill: ${SKILL_NAME} ==="
echo "Skill directory: ${SKILL_DIR}"
echo

# ---------------------------------------------------------------------------
# 1. SKILL.md frontmatter, relative markdown links, and leaked-path audit
# ---------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  if python3 - "${SKILL_DIR}" "${SKILL_NAME}" <<'PY'
import os
import re
import sys

skill_dir = os.path.abspath(sys.argv[1])
expected_name = sys.argv[2]
skill_md = os.path.join(skill_dir, "SKILL.md")

if not os.path.isfile(skill_md):
    print("Missing SKILL.md", file=sys.stderr)
    sys.exit(1)

with open(skill_md, "r", encoding="utf-8") as f:
    text = f.read()

# Validate YAML frontmatter block
fm_match = re.match(r"^---\n(.*?)\n---\n", text, re.DOTALL)
if not fm_match:
    print("SKILL.md missing valid YAML frontmatter delimited by ---", file=sys.stderr)
    sys.exit(1)

fm = fm_match.group(1)
name_match = re.search(r"^name:\s*([a-z0-9-]+)\s*$", fm, re.MULTILINE)
if not name_match:
    print("SKILL.md frontmatter missing valid lowercase hyphenated 'name'", file=sys.stderr)
    sys.exit(1)

actual_name = name_match.group(1)
if actual_name != expected_name:
    print(f"Frontmatter name '{actual_name}' does not match folder '{expected_name}'", file=sys.stderr)
    sys.exit(1)

desc_match = re.search(r"^description:\s*(.+)", fm, re.MULTILINE)
if not desc_match:
    print("SKILL.md frontmatter missing 'description'", file=sys.stderr)
    sys.exit(1)

# Collect all markdown files and verify relative links resolve on disk
md_files = []
for root, _, files in os.walk(skill_dir):
    for fn in files:
        if fn.endswith(".md"):
            md_files.append(os.path.join(root, fn))

link_re = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
broken_links = []
checked_links = 0

for md_path in sorted(md_files):
    with open(md_path, "r", encoding="utf-8") as f:
        content = f.read()
    # Strip fenced code blocks before checking links
    content_no_code = re.sub(r"```.*?```", "", content, flags=re.DOTALL)
    for m in link_re.finditer(content_no_code):
        raw_target = m.group(1).strip().split()[0]
        if raw_target.startswith(("http://", "https://", "mailto:", "#")):
            continue
        target_path = raw_target.split("#", 1)[0]
        if not target_path:
            continue
        resolved = os.path.normpath(os.path.join(os.path.dirname(md_path), target_path))
        checked_links += 1
        if not os.path.exists(resolved):
            rel_md = os.path.relpath(md_path, skill_dir)
            broken_links.append(f"{rel_md} -> {raw_target}")

if broken_links:
    print("Broken relative markdown links:", file=sys.stderr)
    for item in broken_links:
        print(f"  - {item}", file=sys.stderr)
    sys.exit(1)

# Check entire skill directory (excluding this script's own check regexes) for leaked ephemeral paths
forbidden_patterns = [
    re.compile(r"/" + "scratch" + r"/"),
    re.compile(r"/" + "brain" + r"/"),
    re.compile(r"antigravity/" + "brain"),
    re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"),
]

leaks = []
for root, _, files in os.walk(skill_dir):
    for fn in sorted(files):
        full_path = os.path.join(root, fn)
        rel_path = os.path.relpath(full_path, skill_dir)
        try:
            with open(full_path, "r", encoding="utf-8") as f:
                for line_no, line in enumerate(f, start=1):
                    for pat in forbidden_patterns:
                        if pat.search(line):
                            leaks.append(f"{rel_path}:{line_no}: {line.strip()[:120]}")
                            break
        except UnicodeDecodeError:
            continue

if leaks:
    print("Leaked ephemeral workspace paths detected:", file=sys.stderr)
    for item in leaks:
        print(f"  - {item}", file=sys.stderr)
    sys.exit(1)

print(f"Validated frontmatter (name={actual_name}), {checked_links} relative markdown links, and zero leaked paths.")
PY
  then
    pass "SKILL.md frontmatter, relative links, and zero leaked ephemeral paths"
  else
    fail "SKILL.md frontmatter / link / leaked-path check"
  fi
else
  fail "python3 is required to validate frontmatter and markdown links"
fi

# ---------------------------------------------------------------------------
# 2. SwiftUI example: Swift 6 strict typecheck (macOS 14+ & iOS 17+ Simulator)
# ---------------------------------------------------------------------------
SWIFT_FILE="${SKILL_DIR}/examples/swiftui/ParticleDictationCard.swift"
if [[ ! -f "${SWIFT_FILE}" ]]; then
  fail "Missing SwiftUI example: ${SWIFT_FILE}"
elif command -v swiftc >/dev/null 2>&1 && command -v xcrun >/dev/null 2>&1; then
  MAC_SDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
  if [[ -n "${MAC_SDK}" && -d "${MAC_SDK}" ]]; then
    if swiftc -swift-version 6 -warnings-as-errors -sdk "${MAC_SDK}" \
      -target arm64-apple-macosx14.0 -parse-as-library -typecheck "${SWIFT_FILE}"; then
      pass "Swift 6 typecheck (arm64-apple-macosx14.0, -warnings-as-errors)"
    else
      fail "Swift 6 typecheck (arm64-apple-macosx14.0)"
    fi
  else
    skip "macOS SDK not found via xcrun; skipped macOS Swift 6 typecheck"
  fi

  IOS_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null || true)"
  if [[ -n "${IOS_SDK}" && -d "${IOS_SDK}" ]]; then
    if swiftc -swift-version 6 -warnings-as-errors -sdk "${IOS_SDK}" \
      -target arm64-apple-ios17.0-simulator -parse-as-library -typecheck "${SWIFT_FILE}"; then
      pass "Swift 6 typecheck (arm64-apple-ios17.0-simulator, -warnings-as-errors)"
    else
      fail "Swift 6 typecheck (arm64-apple-ios17.0-simulator)"
    fi
  else
    skip "iOS Simulator SDK not found via xcrun; skipped iOS Swift 6 typecheck"
  fi
else
  skip "swiftc/xcrun unavailable on this host; skipped SwiftUI Swift 6 typechecks"
fi

# ---------------------------------------------------------------------------
# 3. React TSX example: strict TypeScript check (when tsc + @types/react exist)
# ---------------------------------------------------------------------------
REACT_TSX="${SKILL_DIR}/examples/react/ParticleDictationCard.tsx"
if [[ ! -f "${REACT_TSX}" ]]; then
  fail "Missing React TSX example: ${REACT_TSX}"
else
  TSC_BIN=""
  if [[ -x "${PWD}/node_modules/.bin/tsc" ]]; then
    TSC_BIN="${PWD}/node_modules/.bin/tsc"
  elif command -v tsc >/dev/null 2>&1; then
    TSC_BIN="$(command -v tsc)"
  fi

  REACT_TYPES_DIR=""
  if [[ -n "${TSC_BIN}" ]]; then
    if [[ -d "${PWD}/node_modules/@types/react" ]]; then
      REACT_TYPES_DIR="${PWD}/node_modules/@types"
    elif command -v node >/dev/null 2>&1; then
      RESOLVED_REACT_PKG="$(node -e "try{console.log(require.resolve('@types/react/package.json'))}catch{}" 2>/dev/null || true)"
      if [[ -n "${RESOLVED_REACT_PKG}" ]]; then
        REACT_TYPES_DIR="$(dirname "$(dirname "${RESOLVED_REACT_PKG}")")"
      else
        GLOBAL_ROOT="$(npm root -g 2>/dev/null || true)"
        if [[ -n "${GLOBAL_ROOT}" && -d "${GLOBAL_ROOT}/@types/react" ]]; then
          REACT_TYPES_DIR="${GLOBAL_ROOT}/@types"
        fi
      fi
    fi
  fi

  if [[ -n "${TSC_BIN}" && -n "${REACT_TYPES_DIR}" ]]; then
    TMP_TS_DIR="$(mktemp -d)"
    trap 'rm -rf "${TMP_TS_DIR}"' EXIT
    NODE_MODULES_DIR="$(dirname "${REACT_TYPES_DIR}")"
    ln -s "${NODE_MODULES_DIR}" "${TMP_TS_DIR}/node_modules"
    cp "${REACT_TSX}" "${TMP_TS_DIR}/ParticleDictationCard.tsx"
    cat > "${TMP_TS_DIR}/tsconfig.json" <<JSON
{
  "compilerOptions": {
    "target": "ES2020",
    "lib": ["ES2020", "DOM", "DOM.Iterable"],
    "module": "ESNext",
    "moduleResolution": "bundler",
    "jsx": "react-jsx",
    "strict": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "noEmit": true,
    "esModuleInterop": true,
    "skipLibCheck": true
  },
  "files": ["./ParticleDictationCard.tsx"]
}
JSON
    if "${TSC_BIN}" -p "${TMP_TS_DIR}/tsconfig.json"; then
      pass "React TSX strict TypeScript check (--strict --noUnusedLocals --noUnusedParameters --noEmit)"
    else
      fail "React TSX strict TypeScript check"
    fi
  else
    skip "tsc and/or @types/react not found in current workspace or global npm; skipped strict TSX compile"
  fi
fi

# ---------------------------------------------------------------------------
# 4. demo.html structural & inline JS syntax sanity check
# ---------------------------------------------------------------------------
DEMO_HTML="${SKILL_DIR}/examples/react/demo.html"
if [[ ! -f "${DEMO_HTML}" ]]; then
  fail "Missing React demo HTML: ${DEMO_HTML}"
else
  if python3 - "${DEMO_HTML}" <<'PY'
import re
import subprocess
import sys
import tempfile
import os

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    html = f.read()

required_markers = [
    "<!doctype html>",
    "createElement('canvas')",
    "'aria-live', 'polite'",
    "aria-describedby",
    "prefers-reduced-motion",
    "window.__PDC_DEBUG__",
]
missing = [m for m in required_markers if m.lower() not in html.lower()]
if missing:
    print(f"demo.html missing expected markers: {missing}", file=sys.stderr)
    sys.exit(1)

scripts = re.findall(r"<script(?:\s[^>]*)?>(.*?)</script>", html, flags=re.DOTALL | re.IGNORECASE)
if not scripts:
    print("demo.html contains no inline <script> block", file=sys.stderr)
    sys.exit(1)

# Syntax-check inline JS with node --check if node is installed
node_bin = None
for cand in ("node",):
    res = subprocess.run(["which", cand], capture_output=True, text=True)
    if res.returncode == 0:
        node_bin = res.stdout.strip()

if node_bin:
    with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False, encoding="utf-8") as tf:
        tf.write("\n;\n".join(scripts))
        tmp_js = tf.name
    try:
        chk = subprocess.run([node_bin, "--check", tmp_js], capture_output=True, text=True)
        if chk.returncode != 0:
            print("demo.html inline JS syntax error:", chk.stderr, file=sys.stderr)
            sys.exit(1)
    finally:
        os.unlink(tmp_js)

print(f"demo.html passed structural markers ({len(required_markers)}) and inline JS syntax check.")
PY
  then
    pass "demo.html structural markers & inline JS syntax check"
  else
    fail "demo.html structural / syntax check"
  fi
fi

echo
echo "=== Summary: ${PASS_COUNT} passed, ${SKIP_COUNT} skipped, ${FAIL_COUNT} failed ==="
if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  exit 1
fi
