#!/bin/bash -l
#SBATCH --job-name=shpc_tools_test
#SBATCH --time=96:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=230GB
#SBATCH --account=pawsey0001
#SBATCH --partition=long

# Serially install each tool from the YAML manifest, load its module, run its top alias, and log the result.

module load shpc/0.1.32 
module unload python
module load singularity/4.3.5-nompi
export SINGULARITY_CACHEDIR=${MYSCRATCH}/.singularity

YAML="${1:-shpc_tools.yaml}"
LOG="${2:-shpc_test_$(date +%Y%m%d_%H%M%S).csv}"
VERBOSE_LOG="${LOG%.csv}.out"
TIMEOUT=60

# Make the module command available in a non-interactive shell.
[ -z "$(type -t module)" ] && source /usr/share/lmod/lmod/init/bash

# Wrap a field in quotes and double any quotes inside it.
csv() { printf '"%s"' "$(printf '%s' "$1" | sed 's/"/""/g')"; }

# Flatten the nested YAML into repo|tool|version|top_alias lines.
parse_yaml() {
  awk '
    /^  [A-Za-z0-9._-]+:[[:space:]]*$/ { tool=$1; sub(/:$/,"",tool); next }
    /^    repo:/                       { repo=$2; next }
    /^    top_alias:/                  { alias=$2; next }
    /^      - /                        { ver=$2; gsub(/"/,"",ver); print repo"|"tool"|"ver"|"alias }
  ' "$1"
}

# Snapshot what shpc already has so we never trigger the interactive overwrite prompt.
INSTALLED=$(shpc list 2>/dev/null | tr -d '[:blank:]')

echo "tool,version,shpc_install,module_load,alias_run,alias_output" > "$LOG"
: > "$VERBOSE_LOG"

i_pass=0; i_fail=0; i_exist=0
l_pass=0; l_fail=0; l_skip=0
a_pass=0; a_fail=0; a_skip=0

while IFS='|' read -r repo tool ver alias; do
  echo "=== $repo/$tool:$ver ==="

  echo "--- shpc install $repo/$tool:$ver" >> "$VERBOSE_LOG"
  # Skip the install if shpc already has it, otherwise shpc prompts and dies on EOF.
  if printf '%s\n' "$INSTALLED" | grep -qxF "$repo/$tool:$ver"; then
    install=EXISTS; i_exist=$((i_exist+1))
    echo "already installed, skipping" >> "$VERBOSE_LOG"
  elif shpc install "$repo/$tool:$ver" >> "$VERBOSE_LOG" 2>&1 < /dev/null; then
    install=PASS; i_pass=$((i_pass+1))
  else
    install=FAIL; i_fail=$((i_fail+1))
  fi

  if [ "$install" = FAIL ]; then
    load=SKIP; l_skip=$((l_skip+1))
  elif module load "$tool/$ver" >> "$VERBOSE_LOG" 2>&1; then
    load=PASS; l_pass=$((l_pass+1))
  else
    load=FAIL; l_fail=$((l_fail+1))
  fi

  # A non-empty response means the alias exists and runs, which is all we are checking.
  out=""
  if [ "$load" != PASS ]; then
    run=SKIP; a_skip=$((a_skip+1))
  else
    out=$(timeout "$TIMEOUT" "$alias" 2>&1 < /dev/null | tr '\n\r\t' '   ' | cut -c1-300)
    if [ -n "$out" ]; then
      run=PASS; a_pass=$((a_pass+1))
    else
      run=FAIL; a_fail=$((a_fail+1))
    fi
  fi

  module unload "$tool/$ver" >> "$VERBOSE_LOG" 2>&1
  module load singularity/4.3.5-nompi

  printf '%s,%s,%s,%s,%s,%s\n' \
    "$(csv "$tool")" "$(csv "$ver")" "$install" "$load" "$run" "$(csv "$out")" >> "$LOG"

  echo "  install=$install load=$load alias=$run"
done < <(parse_yaml "$YAML")

{
  echo ""
  echo "stage,pass,fail,skip,already_installed"
  echo "shpc_install,$i_pass,$i_fail,0,$i_exist"
  echo "module_load,$l_pass,$l_fail,$l_skip,0"
  echo "alias_run,$a_pass,$a_fail,$a_skip,0"
} >> "$LOG"

echo ""
echo "install  pass=$i_pass fail=$i_fail exists=$i_exist"
echo "load     pass=$l_pass fail=$l_fail skip=$l_skip"
echo "alias    pass=$a_pass fail=$a_fail skip=$a_skip"
echo "results: $LOG"
echo "output:  $VERBOSE_LOG"
