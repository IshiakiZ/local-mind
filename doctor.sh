#!/bin/bash
# Local Mind — diagnostics. Read-only: this changes nothing on your Mac.
# Run:  ./doctor.sh
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
ok(){ printf "  \033[32m✓\033[0m %s\n" "$1"; }
# `timeout` ships with GNU coreutils and is NOT on a stock Mac. Rolling our own
# so this script works on a machine that has never seen Homebrew extras.
run_limited(){ # run_limited <seconds> <cmd...>
  local secs=$1; shift
  "$@" & local pid=$!
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    i=$((i+1)); [ "$i" -ge $((secs*10)) ] && { kill -9 "$pid" 2>/dev/null; return 124; }
    sleep 0.1
  done
  wait "$pid"
}
bad(){ printf "  \033[31m✗\033[0m %s\n" "$1"; }
warn(){ printf "  \033[33m!\033[0m %s\n" "$1"; }

echo "── Machine ─────────────────────────────────────────"
CHIP=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
RAM=$(( $(sysctl -n hw.memsize) / 1073741824 ))
OSV=$(sw_vers -productVersion)
echo "  $CHIP · ${RAM} GB · macOS $OSV"
case "$CHIP" in *Apple*) ok "Apple silicon";; *) bad "Intel Mac — the on-device model cannot run here";; esac
[ "${OSV%%.*}" -ge 26 ] && ok "macOS 26+" || bad "macOS $OSV — Local Mind needs macOS 26 (Tahoe) or newer"
[ "$RAM" -ge 16 ] && ok "${RAM} GB RAM" || warn "${RAM} GB RAM — qwen3:8b needs about 6 GB free"

echo
echo "── Apple on-device model ───────────────────────────"
if xcode-select -p >/dev/null 2>&1; then
  cat > /tmp/_lm_fm.swift <<'SWIFT'
import FoundationModels
switch SystemLanguageModel.default.availability {
case .available: print("AVAILABLE")
case .unavailable(let r): print("UNAVAILABLE: \(r)")
@unknown default: print("UNKNOWN")
}
SWIFT
  R=$(run_limited 90 swift /tmp/_lm_fm.swift 2>/dev/null | tail -1)
  case "$R" in
    AVAILABLE) ok "Apple Intelligence model ready";;
    UNAVAILABLE*) bad "$R";
                  echo "      Turn on Apple Intelligence: System Settings › Apple Intelligence & Siri";;
    "") warn "Check produced no result — Swift may be slow on first run. Try again."
        echo "      If it keeps failing: System Settings › Apple Intelligence & Siri";;
    *) warn "Unexpected result: $R";;
  esac
  rm -f /tmp/_lm_fm.swift
else
  warn "Xcode Command Line Tools missing — run: xcode-select --install"
fi

echo
echo "── Ollama ──────────────────────────────────────────"
if ! command -v ollama >/dev/null 2>&1; then
  bad "ollama not installed — run: brew install ollama"
else
  ok "ollama $(ollama --version 2>/dev/null | awk '{print $NF}')"
  if curl -s --max-time 3 http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
    ok "server running"
  else
    bad "server not running — run: brew services start ollama"
  fi
  # Check the model the APP is set to, not a hardcoded one — it is selectable.
  MODEL=$(defaults read com.pearce.localmind ollamaModel 2>/dev/null || echo "qwen3:8b")
  if ollama list 2>/dev/null | grep -q "^${MODEL} "; then
    ok "${MODEL} installed (the model Local Mind is set to use)"
  else
    bad "${MODEL} missing — either: ollama pull ${MODEL}"
    echo "      or pick an installed one from the model menu in Local Mind's title bar."
    echo "      installed right now:"
    ollama list 2>/dev/null | tail -n +2 | awk '{print "        " $1}'
  fi
fi

echo
echo "── Live request (this is what the app actually does) ─"
if curl -s --max-time 3 http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
  START=$(date +%s)
  CODE=$(curl -s -o /tmp/_lm_body.txt -w "%{http_code}" --max-time 180 \
    -X POST http://127.0.0.1:11434/api/chat -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in three words.\"}],\"stream\":false}")
  SECS=$(( $(date +%s) - START ))
  if [ "$CODE" = "200" ]; then
    REPLY=$(python3 -c "import json;print(json.load(open('/tmp/_lm_body.txt'))['message']['content'][:60])" 2>/dev/null)
    ok "HTTP 200 in ${SECS}s — replied: $REPLY"
    [ "$SECS" -gt 30 ] && warn "That is very slow. Check Activity Monitor for memory pressure."
  else
    bad "HTTP $CODE in ${SECS}s"
    echo "      $(head -c 300 /tmp/_lm_body.txt)"
    grep -q "not found" /tmp/_lm_body.txt 2>/dev/null && \
      echo "      ↳ Pull it with: ollama pull ${MODEL}"
  fi
  echo "  loaded models:"; ollama ps 2>/dev/null | tail -n +2 | sed 's/^/      /'
  rm -f /tmp/_lm_body.txt
else
  warn "skipped — server not reachable"
fi

echo
echo "── Disk space ──────────────────────────────────────"
AVAIL=$(df -g / | tail -1 | awk '{print $4}')
echo "  ${AVAIL} GB free"
if [ "$AVAIL" -lt 8 ]; then
  bad "Not enough room. qwen3:8b needs about 6 GB, plus space for macOS to work."
  echo "      Free some space, then: ollama pull qwen3:8b"
elif [ "$AVAIL" -lt 20 ]; then
  warn "Getting tight. macOS slows down badly below ~10 GB free."
else
  ok "plenty of room"
fi

echo
echo "── Memory ──────────────────────────────────────────"
# NOTE: do NOT report "pages free" — macOS uses nearly all RAM for cache, so
# that number is ~0.1 GB even on a completely healthy Mac. It alarms people
# for no reason. Memory PRESSURE is the number that actually means something.
PCT=$(memory_pressure 2>/dev/null | awk -F: '/free percentage/{gsub(/[^0-9]/,"",$2); print $2}')
if [ -n "$PCT" ]; then
  echo "  ${PCT}% free by memory pressure"
  if [ "$PCT" -lt 15 ]; then bad "Under real memory pressure — close some apps"
  elif [ "$PCT" -lt 30 ]; then warn "Somewhat tight"
  else ok "healthy"; fi
fi
SWAP=$(sysctl -n vm.swapusage 2>/dev/null | awk '{print $6}' | tr -d 'M')
[ -n "$SWAP" ] && echo "  swap in use: ${SWAP}M"
echo
echo "Paste this whole output to whoever is helping you."
