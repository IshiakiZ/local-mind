#!/bin/bash
# Local Mind — diagnostics. Read-only: this changes nothing on your Mac.
# Run:  ./doctor.sh
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
ok(){ printf "  \033[32m✓\033[0m %s\n" "$1"; }
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
  R=$(timeout 60 swift /tmp/_lm_fm.swift 2>/dev/null | tail -1)
  case "$R" in
    AVAILABLE) ok "Apple Intelligence model ready";;
    UNAVAILABLE*) bad "$R";
                  echo "      Turn on Apple Intelligence: System Settings › Apple Intelligence & Siri";;
    *) warn "Could not check (needs Xcode Command Line Tools)";;
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
  if ollama list 2>/dev/null | grep -q "qwen3:8b"; then
    ok "qwen3:8b installed"
  else
    bad "qwen3:8b missing — run: ollama pull qwen3:8b"
  fi
fi

echo
echo "── Live request (this is what the app actually does) ─"
if curl -s --max-time 3 http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
  START=$(date +%s)
  CODE=$(curl -s -o /tmp/_lm_body.txt -w "%{http_code}" --max-time 180 \
    -X POST http://127.0.0.1:11434/api/chat \
    -d '{"model":"qwen3:8b","messages":[{"role":"user","content":"Say hello in three words."}],"stream":false,"think":false}')
  SECS=$(( $(date +%s) - START ))
  if [ "$CODE" = "200" ]; then
    REPLY=$(python3 -c "import json;print(json.load(open('/tmp/_lm_body.txt'))['message']['content'][:60])" 2>/dev/null)
    ok "HTTP 200 in ${SECS}s — replied: $REPLY"
    [ "$SECS" -gt 30 ] && warn "That is very slow. Check Activity Monitor for memory pressure."
  else
    bad "HTTP $CODE in ${SECS}s"
    echo "      $(head -c 300 /tmp/_lm_body.txt)"
    grep -q "think" /tmp/_lm_body.txt 2>/dev/null && \
      echo "      ↳ Your Ollama is too old for this request. Run: brew upgrade ollama"
  fi
  echo "  loaded models:"; ollama ps 2>/dev/null | tail -n +2 | sed 's/^/      /'
  rm -f /tmp/_lm_body.txt
else
  warn "skipped — server not reachable"
fi

echo
echo "── Memory pressure ─────────────────────────────────"
vm_stat | awk '/Pages free/{f=$3} /Pages active/{a=$3} /Pages wired/{w=$4} END{gsub(/\./,"",f);gsub(/\./,"",a);gsub(/\./,"",w); printf "  free %.1f GB · active %.1f GB · wired %.1f GB\n", f*16384/1e9, a*16384/1e9, w*16384/1e9}'
sysctl vm.swapusage 2>/dev/null | sed 's/^/  /'
echo
echo "Paste this whole output to whoever is helping you."
