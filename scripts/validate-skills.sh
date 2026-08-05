#!/usr/bin/env bash
# Validate the contents of this repository.
#
# Phase 1 - skills/<name>/SKILL.md:
#  - file exists and is non-empty
#  - frontmatter contains `name:` and `description:`
#  - frontmatter `name` matches the directory name
#
# Phase 2 - agents/<name>.md and commands/<name>.md:
#  - frontmatter parses and carries a non-empty `description:`
#  - body (the agent prompt / command template) is non-empty
#  - agents: `name` matches the filename, `mode` is a valid value
#  - commands: `agent` names a known agent
#
# Phase 3 - live registration through the opencode plugin:
#  - every skill, agent, and command actually reaches opencode's resolved
#    config. Skipped with a notice when its prerequisites are missing.
#
# Exits non-zero on any failure. Prints a summary.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILLS_DIR="$ROOT/skills"
AGENTS_DIR="$ROOT/agents"
COMMANDS_DIR="$ROOT/commands"

if [[ ! -d "$SKILLS_DIR" ]]; then
  echo "FAIL: skills directory not found at $SKILLS_DIR" >&2
  exit 2
fi

errors=0
checked=0

# Print the frontmatter of a markdown file (between the first two '---' lines).
frontmatter_of() {
  awk '
    /^---$/ { count++; next }
    count == 1 { print }
    count == 2 { exit }
  ' "$1"
}

# Print the body of a markdown file (everything after the closing '---').
body_of() {
  awk '
    /^---$/ && count < 2 { count++; next }
    count >= 2 { print }
  ' "$1"
}

# Read a top-level scalar key out of frontmatter. Leading whitespace is
# required to be absent, so nested keys (permission entries, for example) are
# never mistaken for top-level ones.
fm_value() {
  printf '%s\n' "$1" | sed -n "s/^$2:[[:space:]]*//p" | head -1 | tr -d '"' | tr -d "'"
}

is_blank() {
  [[ -z "$(printf '%s' "$1" | tr -d '[:space:]')" ]]
}

# ---------------------------------------------------------------- phase 1
for dir in "$SKILLS_DIR"/*/; do
  [[ -d "$dir" ]] || continue
  skill_name="$(basename "$dir")"
  skill_file="$dir/SKILL.md"
  checked=$((checked + 1))

  if [[ ! -f "$skill_file" ]]; then
    echo "FAIL [$skill_name]: SKILL.md missing"
    errors=$((errors + 1))
    continue
  fi

  if [[ ! -s "$skill_file" ]]; then
    echo "FAIL [$skill_name]: SKILL.md is empty"
    errors=$((errors + 1))
    continue
  fi

  frontmatter="$(frontmatter_of "$skill_file")"

  if [[ -z "$frontmatter" ]]; then
    echo "FAIL [$skill_name]: no YAML frontmatter found"
    errors=$((errors + 1))
    continue
  fi

  fm_name="$(fm_value "$frontmatter" name)"
  fm_desc="$(fm_value "$frontmatter" description)"

  if [[ -z "$fm_name" ]]; then
    echo "FAIL [$skill_name]: frontmatter missing 'name'"
    errors=$((errors + 1))
    continue
  fi

  if [[ -z "$fm_desc" ]]; then
    echo "FAIL [$skill_name]: frontmatter missing 'description'"
    errors=$((errors + 1))
    continue
  fi

  if [[ "$fm_name" != "$skill_name" ]]; then
    echo "FAIL [$skill_name]: frontmatter name '$fm_name' != directory '$skill_name'"
    errors=$((errors + 1))
    continue
  fi

  echo "ok   [$skill_name]"
done

# ---------------------------------------------------------------- phase 2
known_agents=" build plan general explore "
for file in "$AGENTS_DIR"/*.md; do
  [[ -f "$file" ]] || continue
  known_agents+="$(basename "$file" .md) "
done

for file in "$AGENTS_DIR"/*.md; do
  [[ -f "$file" ]] || continue
  agent_name="$(basename "$file" .md)"
  checked=$((checked + 1))

  frontmatter="$(frontmatter_of "$file")"
  if [[ -z "$frontmatter" ]]; then
    echo "FAIL [agent: $agent_name]: no YAML frontmatter found"
    errors=$((errors + 1))
    continue
  fi

  if [[ -z "$(fm_value "$frontmatter" description)" ]]; then
    echo "FAIL [agent: $agent_name]: frontmatter missing 'description'"
    errors=$((errors + 1))
    continue
  fi

  if is_blank "$(body_of "$file")"; then
    echo "FAIL [agent: $agent_name]: body is empty (agents need a prompt)"
    errors=$((errors + 1))
    continue
  fi

  fm_name="$(fm_value "$frontmatter" name)"
  if [[ -n "$fm_name" && "$fm_name" != "$agent_name" ]]; then
    echo "FAIL [agent: $agent_name]: frontmatter name '$fm_name' != filename '$agent_name'"
    errors=$((errors + 1))
    continue
  fi

  fm_mode="$(fm_value "$frontmatter" mode)"
  if [[ -n "$fm_mode" && "$fm_mode" != "primary" && "$fm_mode" != "subagent" && "$fm_mode" != "all" ]]; then
    echo "FAIL [agent: $agent_name]: mode '$fm_mode' is not primary|subagent|all"
    errors=$((errors + 1))
    continue
  fi

  echo "ok   [agent: $agent_name]"
done

for file in "$COMMANDS_DIR"/*.md; do
  [[ -f "$file" ]] || continue
  command_name="$(basename "$file" .md)"
  checked=$((checked + 1))

  frontmatter="$(frontmatter_of "$file")"
  if [[ -z "$frontmatter" ]]; then
    echo "FAIL [command: $command_name]: no YAML frontmatter found"
    errors=$((errors + 1))
    continue
  fi

  if [[ -z "$(fm_value "$frontmatter" description)" ]]; then
    echo "FAIL [command: $command_name]: frontmatter missing 'description'"
    errors=$((errors + 1))
    continue
  fi

  if is_blank "$(body_of "$file")"; then
    echo "FAIL [command: $command_name]: body is empty (commands need a template)"
    errors=$((errors + 1))
    continue
  fi

  fm_agent="$(fm_value "$frontmatter" agent)"
  if [[ -n "$fm_agent" && "$known_agents" != *" $fm_agent "* ]]; then
    echo "FAIL [command: $command_name]: agent '$fm_agent' is not a known agent"
    errors=$((errors + 1))
    continue
  fi

  echo "ok   [command: $command_name]"
done

# ---------------------------------------------------------------- phase 3
skip_reason=""
if ! command -v opencode >/dev/null 2>&1; then
  skip_reason="opencode is not on PATH"
elif ! command -v python3 >/dev/null 2>&1; then
  skip_reason="python3 is not on PATH (needed to read opencode's JSON output)"
elif [[ ! -d "$ROOT/node_modules/yaml" ]]; then
  skip_reason="dependencies are not installed (run 'bun install' or 'npm install')"
fi

echo ""
if [[ -n "$skip_reason" ]]; then
  echo "registration: SKIPPED - $skip_reason"
else
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' EXIT
  mkdir -p "$workdir/cfg"

  cat > "$workdir/opencode.json" <<EOF
{ "\$schema": "https://opencode.ai/config.json", "plugin": ["$ROOT/plugin/ocskillz.js"] }
EOF

  # OPENCODE_CONFIG_DIR points at an empty directory so the developer's real
  # global config can neither contaminate this check nor be contaminated by it.
  (
    cd "$workdir" || exit 1
    OPENCODE_CONFIG_DIR="$workdir/cfg" opencode debug config > "$workdir/config.json" 2>/dev/null
    OPENCODE_CONFIG_DIR="$workdir/cfg" opencode debug skill > "$workdir/skill.json" 2>/dev/null
  )

  # Both dumps are large enough to exceed typical pipe buffers, so they are
  # written to files and read back rather than streamed.
  registration_output="$(
    python3 - "$ROOT" "$workdir/config.json" "$workdir/skill.json" <<'PY'
import json, os, sys

root, config_path, skill_path = sys.argv[1:4]

def load(path):
    try:
        with open(path) as handle:
            return json.load(handle)
    except Exception as error:
        print(f"FAIL [registration]: could not read {os.path.basename(path)}: {error}")
        return None

config = load(config_path)
skills = load(skill_path)
if config is None or skills is None:
    sys.exit(1)

def names(directory, suffix=".md"):
    try:
        return sorted(n[: -len(suffix)] for n in os.listdir(directory) if n.endswith(suffix))
    except FileNotFoundError:
        return []

expected_skills = sorted(
    entry
    for entry in os.listdir(os.path.join(root, "skills"))
    if os.path.isfile(os.path.join(root, "skills", entry, "SKILL.md"))
)
expected_agents = names(os.path.join(root, "agents"))
expected_commands = names(os.path.join(root, "commands"))

registered_skills = {s["name"] for s in skills}
registered_agents = set(config.get("agent") or {})
registered_commands = set(config.get("command") or {})

failures = 0
for kind, expected, registered in (
    ("skill", expected_skills, registered_skills),
    ("agent", expected_agents, registered_agents),
    ("command", expected_commands, registered_commands),
):
    for name in expected:
        if name not in registered:
            print(f"FAIL [registration] {kind}: '{name}' did not reach opencode's config")
            failures += 1

print(
    f"registration: {len(expected_skills)} skills, "
    f"{len(expected_agents)} agents, {len(expected_commands)} commands"
)
sys.exit(1 if failures else 0)
PY
  )"

  echo "$registration_output"
  registration_failures="$(printf '%s\n' "$registration_output" | grep -c '^FAIL')"
  errors=$((errors + registration_failures))
fi

echo ""
echo "Checked: $checked  Errors: $errors"

if [[ $errors -gt 0 ]]; then
  exit 1
fi
