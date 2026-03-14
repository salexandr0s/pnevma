#!/usr/bin/env zsh
set +e
test_cmds=(
  "just rust-test"
  "just xcode-test"
  "just xcode-ui-test"
  "just spm-test-clean"
  "just test-all"
  "just ghostty-smoke"
)
: > .codex-test-logs/summary.txt
for test_cmd in "$test_cmds[@]"; do
  safe_name=${test_cmd// /_}
  safe_name=${safe_name//\//_}
  safe_name=${safe_name//:/_}
  log=".codex-test-logs/${safe_name}.log"
  echo "===== RUNNING: $test_cmd =====" | tee -a .codex-test-logs/summary.txt
  start=$(date +%s)
  zsh -lc "$test_cmd" > >(tee "$log") 2>&1
  exit_code=$?
  end=$(date +%s)
  duration=$((end-start))
  echo "EXIT=$exit_code DURATION=${duration}s CMD=$test_cmd LOG=$log" | tee -a .codex-test-logs/summary.txt
  echo | tee -a .codex-test-logs/summary.txt
  echo "----- tail: $log -----"
  tail -n 40 "$log"
  echo
 done
