#!/usr/bin/env bats
# tests/macupdate.bats — macupdate davranış testleri
#
# Çalıştır:  bats tests/macupdate.bats
#
# Her test izole bir HOME ve yalnız stub'lardan oluşan bir PATH kullanır
# (STUB_DIR:/usr/bin:/bin:/usr/sbin:/sbin). sudo ve softwareupdate her zaman
# stub'lanır; gerçek sisteme dokunulmaz. Stub'lar çağrıldıkları argümanları
# $CALLS dosyasına yazar.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../${MACUPDATE_SCRIPT:-macupdate}"
    [ -f "$SCRIPT" ] || { echo "missing $SCRIPT" >&2; return 1; }
    TEST_HOME=$(mktemp -d -t macupdate6-XXXXXX)
    STUB_DIR=$(mktemp -d -t macupdate6-stubs-XXXXXX)
    export HOME="$TEST_HOME"
    export PATH="$STUB_DIR:/usr/bin:/bin:/usr/sbin:/sbin"
    export MACUPDATE_NO_CLEAR=1
    CALLS="$TEST_HOME/.calls"
    LOGDIR="$TEST_HOME/.cache/macupdate"
    touch "$CALLS"
    stub sudo
    stub softwareupdate 'echo "No new software available." >&2'
    HOLDER_PID=""
}

teardown() {
    [ -n "$HOLDER_PID" ] && kill "$HOLDER_PID" 2>/dev/null || true
    rm -rf "$TEST_HOME" "$STUB_DIR" 2>/dev/null || true
}

# stub NAME [BODY] — PATH'e çağrıyı kaydeden sahte komut koyar
stub() {
    local name="$1" body="${2:-exit 0}"
    {
        printf '#!/bin/bash\n'
        printf 'echo "%s $*" >> "%s"\n' "$name" "$CALLS"
        printf '%s\n' "$body"
    } >"$STUB_DIR/$name"
    chmod +x "$STUB_DIR/$name"
}

# Ortam değişkenleriyle yönlendirilen brew stub'ı
stub_brew() {
    stub brew '
case "$1" in
  --prefix) echo "${BREW_RUBY_PREFIX:-/nonexistent}" ;;
  outdated) if [[ "$*" == *--cask* ]]; then printf "%b" "${BREW_OUTDATED_CASK:-}";
            elif [[ -f "${BREW_STATE:-/nonexistent}" ]]; then printf "%b" "${BREW_OUTDATED_AFTER:-}";
            else printf "%b" "${BREW_OUTDATED_FORMULA:-}"; fi ;;
  list)     [[ "$*" == *--pinned* ]] && printf "%b" "${BREW_PINNED:-}" ;;
  doctor)   if [[ -n "${BREW_DOCTOR_RC:-}" ]]; then echo "Warning: unlinked kegs"; exit "$BREW_DOCTOR_RC"; fi ;;
  upgrade)  [[ -n "${BREW_STATE:-}" ]] && touch "$BREW_STATE"; exit "${BREW_UPGRADE_RC:-0}" ;;
  services) printf "%b" "${BREW_SERVICES:-Name Status User File\n}" ;;
esac
exit 0'
}

calls() { cat "$CALLS"; }
log_count() { find "$LOGDIR" -maxdepth 1 -name 'macupdate-*.log' 2>/dev/null | wc -l | tr -d ' '; }
json_status() {  # json_status FILE MODULE
    /usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["modules"][sys.argv[2]]["status"])' "$1" "$2"
}
last_json() { find "$LOGDIR" -maxdepth 1 -name 'macupdate-*.json' | sort | tail -1; }
json_detail() {  # json_detail FILE MODULE
    /usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["modules"][sys.argv[2]]["detail"])' "$1" "$2"
}

# ── Argümanlar ve çıkış kodları ───────────────────────────────────────

@test "--version 6.x yazar" {
    run "$SCRIPT" --version
    [ "$status" -eq 0 ]
    [[ "$output" == "macupdate 6."* ]]
}

@test "--help çıkış kodlarını belgeler" {
    run "$SCRIPT" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"64"* ]]
    [[ "$output" == *"75"* ]]
}

@test "bilinmeyen parametre 64 ile çıkar ve log yazmaz" {
    run "$SCRIPT" --bogus
    [ "$status" -eq 64 ]
    [ "$(log_count)" -eq 0 ]
}

@test "--only bilinmeyen modül 64 ile çıkar" {
    run "$SCRIPT" --only bogus --dry-run
    [ "$status" -eq 64 ]
    [[ "$output" == *"Bilinmeyen modül"* ]]
}

@test "--only değersiz 64 ile çıkar" {
    run "$SCRIPT" --only
    [ "$status" -eq 64 ]
}

@test "--list-modules çekirdek ve genişletilmiş modülleri listeler" {
    run "$SCRIPT" --list-modules
    [ "$status" -eq 0 ]
    [[ "$output" == *"brew"* ]]
    [[ "$output" == *"deno"* ]]
    [[ "$output" == *"browser-cache"* ]]
}

@test "--only genişletilmiş modülü grup bayrağı olmadan çalıştırır" {
    stub deno
    run "$SCRIPT" --only deno
    [ "$status" -eq 0 ]
    grep -q '^deno upgrade' "$CALLS"
}

@test "--only virgüllü liste kabul eder" {
    stub deno
    stub mise
    run "$SCRIPT" --only deno,mise
    [ "$status" -eq 0 ]
    grep -q '^deno upgrade' "$CALLS"
    grep -q '^mise ' "$CALLS"
}

# ── Dry-run ───────────────────────────────────────────────────────────

@test "--dry-run değiştiren hiçbir komutu çalıştırmaz" {
    stub_brew
    export BREW_OUTDATED_FORMULA='wget\n'
    stub mas 'case "$1" in outdated) echo "123 AppA (1.0 -> 1.1)";; esac'
    stub npm 'case "$1" in outdated) echo "{\"left-pad\": {\"current\":\"1\",\"latest\":\"2\"}}";; esac'
    stub pipx
    stub rustup
    stub cargo '[[ "$*" == "install-update --version" ]] && echo "cargo-install-update 1"; exit 0'
    stub uv 'case "$1 $2" in "tool list") echo "serena v1";; esac'
    stub poetry
    stub bun
    run "$SCRIPT" --dry-run
    [ "$status" -eq 0 ]
    # salt-okunur sorgular (ör. brew autoremove --dry-run) serbest
    ! grep -v -- '--dry-run' "$CALLS" | grep -qE '^(pipx upgrade-all|rustup update|rustup self|cargo install-update -a|uv tool upgrade|uv cache|npm update|npm cache|brew (update|upgrade|cleanup|autoremove)|mas upgrade|poetry self|bun upgrade)'
}

@test "--dry-run python ve rust'ı 'güncel' değil 'planlandı' raporlar" {
    stub pipx
    stub rustup
    run "$SCRIPT" --dry-run --json --skip-system
    [ "$status" -eq 0 ]
    j=$(last_json)
    [ "$(json_status "$j" python)" = "planned" ]
    [ "$(json_status "$j" rust)" = "planned" ]
}

@test "--dry-run brew'de bekleyen paketi 'mevcut' raporlar, kısmi değil" {
    stub_brew
    export BREW_OUTDATED_FORMULA='wget\n'
    run "$SCRIPT" --dry-run --json --only brew
    [ "$status" -eq 0 ]
    [ "$(json_status "$(last_json)" brew)" = "available" ]
}

# ── Durum doğruluğu ───────────────────────────────────────────────────

@test "MAS_SKIP_IDS ile atlanan uygulama 'kaldı' sayılmaz" {
    mkdir -p "$HOME/.config/macupdate"
    echo 'MAS_SKIP_IDS=(456)' >"$HOME/.config/macupdate/config.sh"
    stub mas "
st=\"$TEST_HOME/.mas_state\"
case \"\$1\" in
  outdated) if [ -f \"\$st\" ]; then echo '456 AppB (2.0 -> 2.1)'; else printf '123 AppA (1.0 -> 1.1)\n456 AppB (2.0 -> 2.1)\n'; fi ;;
  upgrade) [ \"\$2\" = 123 ] && touch \"\$st\" ;;
esac"
    run "$SCRIPT" --only mas --json
    [ "$status" -eq 0 ]
    [ "$(json_status "$(last_json)" mas)" = "updated" ]
    ! grep -q '^mas upgrade 456' "$CALLS"
}

@test "brew doctor uyarısı tek başına brew'u kısmi yapmaz" {
    stub_brew
    export BREW_DOCTOR_RC=1
    run "$SCRIPT" --only brew --json
    [ "$status" -eq 0 ]
    [ "$(json_status "$(last_json)" brew)" = "current" ]
    [[ "$output" == *"brew doctor"* ]]
}

@test "pinned formula 'kaldı' sayılmaz" {
    stub_brew
    export BREW_OUTDATED_FORMULA='foo\n' BREW_PINNED='foo\n'
    run "$SCRIPT" --only brew --json
    [ "$status" -eq 0 ]
    [ "$(json_status "$(last_json)" brew)" = "current" ]
}

@test "brew güncellemesi sayılır; brew upgrade hatası kısmi + exit 2" {
    stub_brew
    export BREW_OUTDATED_FORMULA='wget\n' BREW_OUTDATED_AFTER='' BREW_STATE="$TEST_HOME/.brew_state"
    run "$SCRIPT" --only brew --json
    [ "$status" -eq 0 ]
    [ "$(json_status "$(last_json)" brew)" = "updated" ]
    rm -f "$TEST_HOME/.brew_state"
    export BREW_UPGRADE_RC=1
    run "$SCRIPT" --only brew --json
    [ "$status" -eq 2 ]
    [ "$(json_status "$(last_json)" brew)" = "partial" ]
}

@test "gem outdated stderr uyarıları eski gem sayılmaz" {
    stub_brew
    mkdir -p "$TEST_HOME/rubyprefix/bin" "$TEST_HOME/gems"
    export BREW_RUBY_PREFIX="$TEST_HOME/rubyprefix"
    cat >"$TEST_HOME/rubyprefix/bin/gem" <<EOF
#!/bin/bash
echo "gem \$*" >> "$CALLS"
st="$TEST_HOME/.gem_state"
case "\$1" in
  env) echo "$TEST_HOME/gems" ;;
  outdated)
    if [ -f "\$st" ]; then
      for i in 1 2 3 4 5; do echo "/x/rdoc.rb:\$i: warning: already initialized constant RDoc::X" >&2; done
    else
      printf 'csv (3.3.5 < 3.3.6)\nrdoc (7.0.4 < 8.0.0)\n'
    fi ;;
  update) [[ "\$*" == *--system* ]] || { touch "\$st"; echo "Gems updated: csv rdoc"; } ;;
esac
exit 0
EOF
    chmod +x "$TEST_HOME/rubyprefix/bin/gem"
    run "$SCRIPT" --only ruby --json
    [ "$status" -eq 0 ]
    [ "$(json_status "$(last_json)" ruby)" = "updated" ]
}

@test "volta'nın paketlediği npm 'hâlâ eski' sayılmaz" {
    stub volta
    stub npm 'case "$1" in outdated) echo "{\"npm\": {\"current\":\"11\",\"latest\":\"12\"}}";; esac'
    run "$SCRIPT" --only node --json
    [ "$status" -eq 0 ]
    [ "$(json_status "$(last_json)" node)" = "current" ]
}

@test "npm allowScripts engeli paket adlarıyla uyarılır ve kısmi olur" {
    stub npm 'case "$1" in
  outdated) echo "{}";;
  update) echo "npm warn allow-scripts 1 package has install scripts not yet covered by allowScripts:"
          echo "npm warn allow-scripts   node-pty@1.0.0 (install: node-gyp rebuild)";;
esac'
    run "$SCRIPT" --only node --json
    [ "$status" -eq 2 ]
    [ "$(json_status "$(last_json)" node)" = "partial" ]
    [[ "$output" == *"node-pty@1.0.0"* ]]
}

@test "pnpm global paketi yoksa pnpm update -g çağrılmaz" {
    stub pnpm 'case "$1" in ls) echo "No global packages found";; esac'
    run "$SCRIPT" --only node
    [ "$status" -eq 0 ]
    ! grep -q '^pnpm update' "$CALLS"
}

# ── Güvenli varsayılanlar ─────────────────────────────────────────────

@test "varsayılan çalıştırma cache temizlemez, conda'ya dokunmaz" {
    stub npm 'case "$1" in outdated) echo "{}";; esac'
    stub pnpm 'case "$1" in ls) echo "No global packages found";; esac'
    stub yarn 'case "$1" in --version) echo "4.18.0";; esac'
    stub uv 'case "$1 $2" in "tool list") echo "serena v1";; esac'
    stub pipx
    stub conda
    run "$SCRIPT" --skip-system
    ! grep -qE '^(yarn cache|uv cache|pnpm store|npm cache|conda (update|clean|install))' "$CALLS" || false
    grep -q '^uv tool upgrade --all' "$CALLS"
    grep -q '^pipx upgrade-all' "$CALLS"
}

@test "--extended SwiftPM cache'ini --aggressive-clean olmadan silmez" {
    stub swift
    mkdir -p "$HOME/Library/Caches/org.swift.swiftpm"
    touch "$HOME/Library/Caches/org.swift.swiftpm/keep"
    run "$SCRIPT" --only swift
    [ -f "$HOME/Library/Caches/org.swift.swiftpm/keep" ]
}

@test "--all deep-clean modüllerini içermez" {
    run "$SCRIPT" --all --dry-run --skip-system
    [ "$status" -eq 0 ]
    [[ "$output" != *"[browser-cache]"* ]]
    [[ "$output" == *"[deno]"* ]]
}

@test "deep-clean tty yokken onaysız silmez" {
    mkdir -p "$HOME/Library/Caches/Google/Chrome"
    touch "$HOME/Library/Caches/Google/Chrome/keep"
    run bash -c '"$0" --only browser-cache </dev/null' "$SCRIPT"
    [ -f "$HOME/Library/Caches/Google/Chrome/keep" ]
}

@test "deep-clean --yes ile siler" {
    mkdir -p "$HOME/Library/Caches/Google/Chrome"
    touch "$HOME/Library/Caches/Google/Chrome/gone"
    run bash -c '"$0" --only browser-cache --yes </dev/null' "$SCRIPT"
    [ ! -e "$HOME/Library/Caches/Google/Chrome/gone" ]
}

@test "--maintenance uv cache prune zaman aşımına uğrar, takılmaz" {
    stub pgrep 'exit 1'   # gerçek makinedeki uv süreçlerinden yalıt
    stub uv 'case "$1 $2" in "cache prune") exec sleep 30;; esac'
    export MACUPDATE_UV_PRUNE_TIMEOUT=2
    SECONDS=0
    run "$SCRIPT" --maintenance --only cache
    [ "$SECONDS" -lt 15 ]
    [[ "$output" == *"zaman aşımı"* ]]
}

# ── Kilit, log, JSON ──────────────────────────────────────────────────

@test "kilit doluyken 75 ile çıkar ve boş log bırakmaz" {
    mkdir -p "$LOGDIR/run.lock"
    bash -c 'exec -a macupdate-holder sleep 30' &
    HOLDER_PID=$!
    echo "$HOLDER_PID" >"$LOGDIR/run.lock/pid"
    sleep 0.3
    run "$SCRIPT" --dry-run --skip-system
    [ "$status" -eq 75 ]
    [ "$(log_count)" -eq 0 ]
}

@test "latest.log bu çalıştırmanın loguna işaret eder" {
    run "$SCRIPT" --dry-run --skip-system
    [ "$status" -eq 0 ]
    target=$(readlink "$LOGDIR/latest.log")
    [ -f "$target" ]
    [[ "$target" == "$LOGDIR"/macupdate-*.log ]]
}

@test "--json-only stdout'u geçerli JSON (alt komut çıktısı karışmaz)" {
    stub git 'echo "Already up to date."'
    mkdir -p "$HOME/.fzf"
    printf '#!/bin/bash\necho "fzf binary installed"\n' >"$HOME/.fzf/install"
    chmod +x "$HOME/.fzf/install"
    run bash -c '"$0" --json-only --only fzf 2>/dev/null' "$SCRIPT"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["modules"]["fzf"]["status"]'
}

# ── Rapor modu ────────────────────────────────────────────────────────

@test "--report hiçbir değiştiren komutu çalıştırmaz ve sayımı stdout'tan yapar" {
    stub_brew
    export BREW_OUTDATED_FORMULA='wget\n'
    stub npm 'case "$1" in outdated) [[ "$*" == *--json* ]] && echo "{\"left-pad\": {}}" || echo "left-pad 1 2"; echo "npm warn something" >&2;; esac'
    stub pipx
    stub rustup
    mkdir -p "$TEST_HOME/rubyprefix/bin" "$TEST_HOME/gems"
    export BREW_RUBY_PREFIX="$TEST_HOME/rubyprefix"
    cat >"$TEST_HOME/rubyprefix/bin/gem" <<GEM
#!/bin/bash
echo "gem \$*" >> "$CALLS"
case "\$1" in
  env) echo "$TEST_HOME/gems" ;;
  outdated) printf 'csv (3.3.5 < 3.3.6)\n'; for i in 1 2 3; do echo "warning: already initialized constant" >&2; done ;;
esac
GEM
    chmod +x "$TEST_HOME/rubyprefix/bin/gem"
    run "$SCRIPT" --report --json --skip-system
    [ "$status" -eq 0 ]
    ! grep -vE -- '--(dry-run|help)' "$CALLS" | grep -qE '^(pipx upgrade-all|rustup update|npm update|brew (update|upgrade|cleanup)|gem (update|cleanup))' || false
    j=$(last_json)
    /usr/bin/python3 - "$j" <<'PY'
import json,sys
m=json.load(open(sys.argv[1]))["modules"]
assert m["ruby"]["detail"].startswith("1 gem"), m["ruby"]
assert m["node"]["detail"].startswith("1 npm"), m["node"]
assert m["brew"]["detail"].startswith("1 paket"), m["brew"]
PY
}

@test "--doctor npm'in cache'i değiştiren ve sürüm kontrollerini çalıştırmaz" {
    stub npm
    run "$SCRIPT" --doctor
    grep -q '^npm doctor ' "$CALLS"
    ! grep -qE '^npm doctor *$|^npm doctor .*(cache|versions)' "$CALLS"
}

@test "--report --skip-system softwareupdate'i sorgulamaz" {
    run "$SCRIPT" --report --skip-system
    [ "$status" -eq 0 ]
    ! grep -q '^softwareupdate' "$CALLS"
}

@test "--dry-run ruby'de gem update/cleanup çalıştırmaz" {
    stub_brew
    mkdir -p "$TEST_HOME/rubyprefix/bin" "$TEST_HOME/gems"
    export BREW_RUBY_PREFIX="$TEST_HOME/rubyprefix"
    printf '#!/bin/bash\necho "gem $*" >> "%s"\ncase "$1" in env) echo "%s/gems";; outdated) echo "csv (1 < 2)";; esac\n' "$CALLS" "$TEST_HOME" >"$TEST_HOME/rubyprefix/bin/gem"
    chmod +x "$TEST_HOME/rubyprefix/bin/gem"
    run "$SCRIPT" --dry-run --only ruby --json
    [ "$status" -eq 0 ]
    grep -q '^gem outdated' "$CALLS"
    ! grep -qE '^gem (update|cleanup)' "$CALLS" || false
    [ "$(json_status "$(last_json)" ruby)" = "available" ]
}

# ── v6.0.1 ────────────────────────────────────────────────────────────

@test "ruby: salt-okunur hedefe giden plugin symlink'i önceden saptanır" {
    stub_brew
    mkdir -p "$TEST_HOME/rubyprefix/bin" "$TEST_HOME/gems/plugins" "$TEST_HOME/cellar"
    echo "# plugin" >"$TEST_HOME/cellar/rdoc_plugin.rb"
    chmod 444 "$TEST_HOME/cellar/rdoc_plugin.rb"
    ln -s "$TEST_HOME/cellar/rdoc_plugin.rb" "$TEST_HOME/gems/plugins/rdoc_plugin.rb"
    export BREW_RUBY_PREFIX="$TEST_HOME/rubyprefix"
    printf '#!/bin/bash\necho "gem $*" >> "%s"\ncase "$1" in env) echo "%s/gems";; outdated) echo "csv (1 < 2)";; esac\n' "$CALLS" "$TEST_HOME" >"$TEST_HOME/rubyprefix/bin/gem"
    chmod +x "$TEST_HOME/rubyprefix/bin/gem"
    run "$SCRIPT" --only ruby --json
    chmod 644 "$TEST_HOME/cellar/rdoc_plugin.rb"
    [ "$status" -eq 2 ]
    ! grep -qE '^gem (update|cleanup)' "$CALLS" || false
    [[ "$output" == *"symlink"* ]]
}

@test "node: volta paket sürüm değişimi güncelleme sayılır" {
    stub volta 'case "$1" in list)
  if [ -f "$HOME/.volta_state" ]; then v=1.1.0; else v=1.0.0; fi
  echo "package openclaw@$v / openclaw / node@24 npm@built-in (default)";; esac'
    stub npm 'case "$1" in outdated) echo "{}";; update) touch "$HOME/.volta_state";; esac'
    run "$SCRIPT" --only node --json
    [ "$status" -eq 0 ]
    [ "$(json_status "$(last_json)" node)" = "updated" ]
    [[ "$output" == *"openclaw"* ]]
}

@test "node: kısmi gerekçeleri birlikte raporlanır (engellenen + hâlâ eski)" {
    stub npm 'case "$1" in
  outdated) echo "{\"left-pad\": {}}";;
  update) echo "npm warn allow-scripts   node-pty@1.0.0 (install: node-gyp rebuild)";;
esac'
    run "$SCRIPT" --only node --json
    [ "$status" -eq 2 ]
    detail=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["modules"]["node"]["detail"])' "$(last_json)")
    [[ "$detail" == *"node-pty@1.0.0"* ]]
    [[ "$detail" == *"left-pad"* ]]
}

# ── v6.0.2 ────────────────────────────────────────────────────────────

# volta, `npm update -g`'yi her pakete `npm update --global <ad>` olarak
# uygular ve sürüm aynı olsa da paketi yeniden kurar (REPLACE); allowScripts
# uyarıları her koşuda yeniden çıkar. Güncel paket hiç kurulmamalı.
@test "node: volta paketleri güncelse npm update -g çağrılmaz" {
    stub volta 'case "$1" in list) echo "package openclaw@2026.9.7 / openclaw / node@24 npm@built-in (default)";; esac'
    stub npm 'case "$1" in
  outdated) echo "{}";;
  view) echo "2026.9.7";;
  update) echo "npm warn allow-scripts   koffi@3.3.1 (install: node ./cnoke.cjs)";;
esac'
    run "$SCRIPT" --only node --json
    [ "$status" -eq 0 ]
    grep -q '^npm view openclaw version' "$CALLS"
    ! grep -q '^npm update' "$CALLS" || false
    [ "$(json_status "$(last_json)" node)" = "current" ]
}

@test "node: yalnız yeni sürümü olan volta paketi güncellenir" {
    stub volta 'case "$1" in list)
  if [ -f "$HOME/.volta_state" ]; then v=1.1.0; else v=1.0.0; fi
  echo "package @scope/tool@$v / tool / node@24 npm@built-in (default)"
  echo "package docsify-cli@5.0.0 / docsify / node@24 npm@built-in (default)";; esac'
    stub npm 'case "$1" in
  outdated) echo "{}";;
  view) case "$2" in @scope/tool) echo "1.1.0";; docsify-cli) echo "5.0.0";; esac;;
  update) touch "$HOME/.volta_state";;
esac'
    run "$SCRIPT" --only node --json
    [ "$status" -eq 0 ]
    grep -qx 'npm update -g @scope/tool' "$CALLS"
    [ "$(json_status "$(last_json)" node)" = "updated" ]
}

@test "node: sürümü sorgulanamayan volta paketi yine güncellenir" {
    stub volta 'case "$1" in list) echo "package openclaw@1.0.0 / openclaw / node@24 npm@built-in (default)";; esac'
    stub npm 'case "$1" in outdated) echo "{}";; view) exit 1;; esac'
    run "$SCRIPT" --only node
    grep -qx 'npm update -g openclaw' "$CALLS"
}

@test "node --dry-run: eski volta paketi 'mevcut' raporlanır, npm update çalışmaz" {
    stub volta 'case "$1" in list) echo "package openclaw@1.0.0 / openclaw / node@24 npm@built-in (default)";; esac'
    stub npm 'case "$1" in outdated) echo "{}";; view) echo "1.1.0";; esac'
    run "$SCRIPT" --dry-run --only node --json
    [ "$status" -eq 0 ]
    ! grep -q '^npm update' "$CALLS" || false
    [ "$(json_status "$(last_json)" node)" = "available" ]
}

@test "node --report: volta paket güncellemesi sayılır" {
    stub volta 'case "$1" in list) echo "package openclaw@1.0.0 / openclaw / node@24 npm@built-in (default)";; esac'
    stub npm 'case "$1" in outdated) [[ "$*" == *--json* ]] && echo "{}";; view) echo "1.1.0";; esac'
    run "$SCRIPT" --report --only node --json
    [ "$status" -eq 0 ]
    ! grep -q '^npm update' "$CALLS" || false
    [[ "$output" == *"openclaw 1.0.0 → 1.1.0"* ]]
    detail=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["modules"]["node"]["detail"])' "$(last_json)")
    [[ "$detail" == "1 "* ]]
}

@test "brew: kullanımdan kalkmış HOMEBREW_NO_REQUIRE_TAP_TRUST export edilmez" {
    unset HOMEBREW_NO_REQUIRE_TAP_TRUST
    stub brew "echo \"TRUST=\${HOMEBREW_NO_REQUIRE_TAP_TRUST-unset}\" >> \"$CALLS\""
    run "$SCRIPT" --only brew-services
    grep -q '^TRUST=unset' "$CALLS"
    ! grep -q '^TRUST=1' "$CALLS"
}

@test "brew-services: hata durumundaki servis uyarılır" {
    stub_brew
    export BREW_SERVICES='Name          Status  User File\ncloudflared   error  1       user ~/Library/LaunchAgents/sh.brew.cloudflared.plist\nredis         started user ~/Library/LaunchAgents/homebrew.mxcl.redis.plist\ncolima        none\n'
    run "$SCRIPT" --only brew-services --json
    [ "$status" -eq 0 ]
    [[ "$output" == *"⚠"*"cloudflared"* ]]
    /usr/bin/python3 - "$(last_json)" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
m=d["modules"]["brew-services"]
assert m["status"]=="completed", m
assert "cloudflared" in m["detail"] and "redis" in m["detail"], m
assert any("cloudflared" in w for w in d["warnings"]), d["warnings"]
PY
}

@test "başlık kutusunun sağ kenarı hizalı" {
    run "$SCRIPT" --dry-run --skip-system --only mas
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | head -4 | /usr/bin/python3 -c '
import sys
lines = sys.stdin.buffer.read().decode("utf-8").splitlines()
assert lines[0].startswith("╔") and lines[3].startswith("╚"), lines
assert len({len(l) for l in lines}) == 1, [len(l) for l in lines]'
}

@test "atlanan modülün gerekçesi bir kez yazılır" {
    run "$SCRIPT" --only docker
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c 'Docker prune isteğe bağlı')" -eq 1 ]
}

@test "en yavaş modüller listesinde süreler sağa hizalı" {
    stub mas 'sleep 2'
    run "$SCRIPT" --only mas
    printf '%s\n' "$output" | grep -qE '^ {2}[ 0-9]{3}s  mas$'
}

@test "softwareupdate başlık gürültüsünü göstermez" {
    stub softwareupdate 'echo "Software Update Tool"; echo; echo "Finding available software"; echo "No new software available." >&2'
    run "$SCRIPT" --only softwareupdate
    [ "$status" -eq 0 ]
    [[ "$output" != *"Finding available software"* ]]
    [[ "$output" == *"No new software available."* ]]
}

@test "rust: rustup update kendini denetlediyse rustup self update çağrılmaz" {
    stub rustup 'case "$1" in update) echo "info: checking for self-update (current version: 1.29.1)";; esac'
    run "$SCRIPT" --only rust
    grep -q '^rustup update' "$CALLS"
    ! grep -q '^rustup self update' "$CALLS"
}

@test "rust: self-update denetimi yoksa rustup self update çağrılır" {
    stub rustup
    run "$SCRIPT" --only rust
    grep -q '^rustup self update' "$CALLS"
}

# ── v6.0.3 ────────────────────────────────────────────────────────────

# CodingAssistant/codex, Xcode'daki Codex ajanının ayar/oturum dizinidir;
# Agents/* indirilmiş ajanlardır. Cache değiller (2026-10-02'de silinmişti).
@test "app-cache Xcode CodingAssistant dizinlerine dokunmaz" {
    local ca="$HOME/Library/Developer/Xcode/CodingAssistant"
    mkdir -p "$ca/Agents/claude" "$ca/Agents/codex" "$ca/codex" "$HOME/Library/Caches/JetBrains"
    touch "$ca/Agents/claude/agent" "$ca/Agents/codex/agent" "$ca/codex/auth.json" "$HOME/Library/Caches/JetBrains/gone"
    run bash -c '"$0" --only app-cache --yes </dev/null' "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -f "$ca/Agents/claude/agent" ]
    [ -f "$ca/Agents/codex/agent" ]
    [ -f "$ca/codex/auth.json" ]
    [ ! -e "$HOME/Library/Caches/JetBrains/gone" ]
}

@test "node: başarısız alt komut adıyla raporlanır" {
    stub bun 'echo "Bun upgrade failed with error: HTTPForbidden"; exit 1'
    run "$SCRIPT" --only node --json
    [ "$status" -eq 2 ]
    [[ "$(json_detail "$(last_json)" node)" == *"bun upgrade"* ]]
}

@test "python: başarısız alt komut adıyla raporlanır" {
    stub pipx 'exit 1'
    run "$SCRIPT" --only python --json
    [ "$status" -eq 2 ]
    [[ "$(json_detail "$(last_json)" python)" == *"pipx upgrade-all"* ]]
}

@test "rust: başarısız alt komut adıyla raporlanır" {
    stub rustup 'case "$1" in update) exit 1;; esac'
    run "$SCRIPT" --only rust --json
    [ "$status" -eq 2 ]
    [[ "$(json_detail "$(last_json)" rust)" == *"rustup update"* ]]
}

@test "deep-clean: onay zaman aşımı gerekçesi doğru yazılır" {
    mkdir -p "$HOME/Library/Caches/Google/Chrome"
    touch "$HOME/Library/Caches/Google/Chrome/keep"
    export MACUPDATE_CONFIRM_TIMEOUT=1
    run bash -c 'sleep 3 | script -q /dev/null "$0" --only browser-cache --json' "$SCRIPT"
    [ -f "$HOME/Library/Caches/Google/Chrome/keep" ]
    [[ "$(json_detail "$(last_json)" browser-cache)" == *"yanıt yok"* ]]
}

@test "mail-downloads: tty yoksa gerekçe 'kullanıcı iptal' değil" {
    local md="$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/X"
    mkdir -p "$md"; echo data >"$md/a.pdf"
    run bash -c '"$0" --only mail-downloads --json </dev/null' "$SCRIPT"
    [ -f "$md/a.pdf" ]
    [[ "$(json_detail "$(last_json)" mail-downloads)" == *"tty yok"* ]]
}

@test "mail-downloads: silinince durum ayrıntısı bunu söyler" {
    local md="$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/X"
    mkdir -p "$md"; echo data >"$md/a.pdf"
    run bash -c '"$0" --only mail-downloads --yes --json </dev/null' "$SCRIPT"
    [ ! -e "$md" ]
    [[ "$(json_detail "$(last_json)" mail-downloads)" == *"temizlendi"* ]]
}

# Ruby ile gelen (varsayılan/bundled) gem'ler `brew upgrade ruby` ile gelir;
# gem update'e verilince io-wait 1.0.0 / rdoc 8.1.0 karışımı oluşmuştu.
ruby_fixture() {  # ruby_fixture "<outdated önce>" "<outdated sonra>" "<Ruby ile gelenler>"
    stub_brew
    mkdir -p "$TEST_HOME/rubyprefix/bin" "$TEST_HOME/gems"
    export BREW_RUBY_PREFIX="$TEST_HOME/rubyprefix"
    cat >"$TEST_HOME/rubyprefix/bin/gem" <<EOF
#!/bin/bash
echo "gem \$*" >> "$CALLS"
st="$TEST_HOME/.gem_state"
case "\$1" in
  env) echo "$TEST_HOME/gems" ;;
  outdated) if [ -f "\$st" ]; then printf '$2'; else printf '$1'; fi ;;
  update) [[ "\$*" == *--system* ]] || touch "\$st" ;;
esac
exit 0
EOF
    printf '#!/bin/bash\nprintf "%s"\n' "$3" >"$TEST_HOME/rubyprefix/bin/ruby"
    chmod +x "$TEST_HOME/rubyprefix/bin/gem" "$TEST_HOME/rubyprefix/bin/ruby"
}

@test "ruby: Ruby ile gelen gem'ler gem update'e verilmez" {
    ruby_fixture 'csv (3.3.5 < 3.3.6)\nio-wait (0.4.0 < 1.0.0)\nrdoc (7.0.4 < 8.1.0)\n' \
                 'io-wait (0.4.0 < 1.0.0)\nrdoc (7.0.4 < 8.1.0)\n' 'io-wait\\nrdoc\\n'
    run "$SCRIPT" --only ruby --json
    [ "$status" -eq 0 ]
    grep -qx 'gem update --no-document csv' "$CALLS"
    ! grep -E '^gem update --no-document' "$CALLS" | grep -qE 'io-wait|rdoc' || false
    [ "$(json_status "$(last_json)" ruby)" = "updated" ]
    [[ "$output" == *"Ruby ile gelen 2 gem atlandı"* ]]
    grep -q 'io-wait rdoc' "$(find "$LOGDIR" -name 'macupdate-*.log' | head -1)"
}

@test "ruby: yalnız Ruby ile gelen gem'ler eskiyse gem update çağrılmaz" {
    ruby_fixture 'io-wait (0.4.0 < 1.0.0)\n' 'io-wait (0.4.0 < 1.0.0)\n' 'io-wait\\n'
    run "$SCRIPT" --only ruby --json
    [ "$status" -eq 0 ]
    grep -q '^gem update --system' "$CALLS"
    ! grep -q '^gem update --no-document' "$CALLS" || false
    [ "$(json_status "$(last_json)" ruby)" = "current" ]
}

# ── --repos (gerçek git depolarıyla) ──────────────────────────────────

# git_clone_fixture KOVA AD — $TEST_HOME/remotes/AD.git (bare) ve onun
# $HOME/projects/KOVA/AD klonu; ilk commit'te izlenen "file" var.
git_clone_fixture() {
    local b="$1" n="$2" seed="$TEST_HOME/seed-$1-$2"
    git init -q -b main "$seed"
    echo v1 >"$seed/file"
    git -C "$seed" add file
    git -C "$seed" -c user.email=t@t -c user.name=t commit -q -m init
    mkdir -p "$TEST_HOME/remotes" "$HOME/projects/$b"
    git clone -q --bare "$seed" "$TEST_HOME/remotes/$n.git"
    git clone -q "$TEST_HOME/remotes/$n.git" "$HOME/projects/$b/$n"
}
remote_commit() {  # remote_commit AD — uzak depoya yeni commit gönder
    local w="$TEST_HOME/work-$1"
    [[ -d "$w" ]] || git clone -q "$TEST_HOME/remotes/$1.git" "$w"
    echo "$RANDOM" >>"$w/file"
    git -C "$w" -c user.email=t@t -c user.name=t commit -q -am upd
    git -C "$w" push -q origin HEAD:main
}
head_of()   { git -C "$HOME/projects/$1" rev-parse HEAD; }
remote_head() { git -C "$TEST_HOME/remotes/$1.git" rev-parse main; }

@test "repos: geride kalan temiz depo fast-forward edilir" {
    git_clone_fixture clones foo
    remote_commit foo
    run "$SCRIPT" --only repos --json
    [ "$status" -eq 0 ]
    [ "$(head_of clones/foo)" = "$(remote_head foo)" ]
    [ "$(json_status "$(last_json)" repos)" = "updated" ]
    [[ "$output" == *"clones/foo"*"+1"* ]]
}

@test "repos: yerel değişikliği olan depoya dokunulmaz" {
    git_clone_fixture private bar
    remote_commit bar
    old=$(head_of private/bar)
    echo yerel >>"$HOME/projects/private/bar/file"
    run "$SCRIPT" --only repos --json
    [ "$status" -eq 0 ]
    [ "$(head_of private/bar)" = "$old" ]
    grep -q yerel "$HOME/projects/private/bar/file"
}

@test "repos: remote'suz depo hata sayılmaz, yerel/ kapsam dışı" {
    git_clone_fixture clones foo
    git init -q -b main "$HOME/projects/private/noremote"
    git_clone_fixture yerel baz
    remote_commit baz
    old=$(head_of yerel/baz)
    run "$SCRIPT" --only repos --json
    [ "$status" -eq 0 ]
    [ "$(head_of yerel/baz)" = "$old" ]
    [ "$(json_status "$(last_json)" repos)" = "current" ]
}

@test "repos: ayrışmış depo adıyla kısmi raporlanır" {
    git_clone_fixture clones foo
    remote_commit foo
    echo yerel-commit >>"$HOME/projects/clones/foo/file"
    git -C "$HOME/projects/clones/foo" -c user.email=t@t -c user.name=t commit -q -am local
    old=$(head_of clones/foo)
    run "$SCRIPT" --only repos --json
    [ "$status" -eq 2 ]
    [ "$(head_of clones/foo)" = "$old" ]
    [[ "$(json_detail "$(last_json)" repos)" == *"clones/foo"* ]]
}

@test "repos: depodaki git hook'ları çalıştırılmaz" {
    git_clone_fixture clones foo
    remote_commit foo
    printf '#!/bin/sh\ntouch "%s"\n' "$TEST_HOME/hook-ran" >"$HOME/projects/clones/foo/.git/hooks/post-merge"
    chmod +x "$HOME/projects/clones/foo/.git/hooks/post-merge"
    run "$SCRIPT" --only repos
    [ "$(head_of clones/foo)" = "$(remote_head foo)" ]
    [ ! -e "$TEST_HOME/hook-ran" ]
}

@test "repos --dry-run: fetch ve merge yapılmaz" {
    git_clone_fixture clones foo
    remote_commit foo
    old=$(head_of clones/foo)
    old_remote_ref=$(git -C "$HOME/projects/clones/foo" rev-parse origin/main)
    run "$SCRIPT" --dry-run --only repos --json
    [ "$status" -eq 0 ]
    [ "$(head_of clones/foo)" = "$old" ]
    [ "$(git -C "$HOME/projects/clones/foo" rev-parse origin/main)" = "$old_remote_ref" ]
    [ "$(json_status "$(last_json)" repos)" = "planned" ]
}

@test "repos: yanıt vermeyen remote zaman aşımına uğrar, takılmaz" {
    git_clone_fixture clones foo
    git -C "$HOME/projects/clones/foo" remote set-url origin ssh://example.invalid/foo.git
    stub ssh 'exec sleep 30'
    export MACUPDATE_REPOS_TIMEOUT=2
    SECONDS=0
    run "$SCRIPT" --only repos --json
    [ "$SECONDS" -lt 15 ]
    [ "$status" -eq 2 ]
    [[ "$(json_detail "$(last_json)" repos)" == *"clones/foo"* ]]
}

@test "repos --dry-run depoları kova başına tek satırda listeler" {
    git_clone_fixture clones foo
    git_clone_fixture clones bar
    git_clone_fixture private baz
    run "$SCRIPT" --dry-run --only repos
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c '^\$ git -C')" -eq 0 ]
    printf '%s\n' "$output" | grep -qE '^  clones \(2\): bar foo$'
    printf '%s\n' "$output" | grep -qE '^  private \(1\): baz$'
}

# PR birleşip uzak dal silinince fetch --prune upstream'i kaldırır; depo
# sessizce "güncel" sayılmamalı.
@test "repos: upstream'i silinmiş dal bildirilir" {
    git_clone_fixture clones foo
    local w="$TEST_HOME/work-foo"
    git clone -q "$TEST_HOME/remotes/foo.git" "$w"
    git -C "$w" push -q origin HEAD:refs/heads/feat
    git -C "$HOME/projects/clones/foo" fetch -q
    git -C "$HOME/projects/clones/foo" checkout -q -b feat --track origin/feat
    git -C "$TEST_HOME/remotes/foo.git" branch -q -D feat
    run "$SCRIPT" --only repos --json
    [ "$status" -eq 0 ]
    [[ "$output" == *"upstream'i silinmiş"*"clones/foo"* ]]
}

# ── v6.0.6: --all çıktısındaki yanlış durumlar ────────────────────────

@test "aws: çalışmayan ikili kısmi + uyarı, 'brew ile yapıldı' denmez" {
    stub aws 'echo "/usr/local/bin/aws: Bad CPU type in executable" >&2; exit 126'
    run "$SCRIPT" --only aws --json
    [ "$status" -eq 2 ]
    [[ "$output" == *"Rosetta"* ]]
    [[ "$output" != *"brew upgrade ile yapıldı"* ]]
    [ "$(json_status "$(last_json)" aws)" = "partial" ]
}

@test "aws: brew dışı kurulum doğru raporlanır" {
    stub aws 'echo "aws-cli/2.31.0 Python/3.13 Darwin/27 exe/x86_64"'
    run "$SCRIPT" --only aws --json
    [ "$status" -eq 0 ]
    [[ "$output" != *"brew upgrade ile yapıldı"* ]]
    [[ "$(json_detail "$(last_json)" aws)" == *"brew dışı"* ]]
}

@test "mise: self-update hatası kısmi raporlanır" {
    stub mise 'case "$1" in self-update) echo "mise ERROR RateLimitedError" >&2; exit 1;; esac'
    run "$SCRIPT" --only mise --json
    [ "$status" -eq 2 ]
    [[ "$(json_detail "$(last_json)" mise)" == *"mise self-update"* ]]
}

@test "pyenv: update eklentisi yoksa çağrılmaz" {
    stub pyenv 'case "$1" in root) echo "$HOME/.pyenv";; commands) printf "install\nversions\n";; update) exit 1;; esac'
    run "$SCRIPT" --only pyenv --json
    [ "$status" -eq 0 ]
    ! grep -q '^pyenv update' "$CALLS" || false
    [ "$(json_status "$(last_json)" pyenv)" = "skipped" ]
}

@test "vscode: code komutu Cursor'a aitse eklentiler iki kez kurulmaz" {
    local bin="$TEST_HOME/Applications/Cursor.app/Contents/Resources/app/bin"
    mkdir -p "$bin"
    printf '#!/bin/bash\necho "code $*" >> "%s"\n[ "$1" = --list-extensions ] && echo ms-python.python\nexit 0\n' "$CALLS" >"$bin/code"
    chmod +x "$bin/code"
    ln -s "$bin/code" "$STUB_DIR/code"
    run "$SCRIPT" --only vscode --json
    [ "$status" -eq 0 ]
    ! grep -q -- '--install-extension' "$CALLS" || false
    [ "$(json_status "$(last_json)" vscode)" = "skipped" ]
}

@test "--maintenance: uv süreci çalışırken cache prune beklemeden atlanır" {
    stub pgrep 'echo 4242'
    stub uv 'case "$1 $2" in "cache prune") exec sleep 30;; esac'
    export MACUPDATE_UV_PRUNE_TIMEOUT=3
    run "$SCRIPT" --maintenance --only cache
    ! grep -q '^uv cache prune' "$CALLS" || false
    [[ "$output" == *"uv süreci çalışıyor"* ]]
}

@test "omz: güncelleme '+N commit' diye özetlenir, banner ve git çıktısı basılmaz" {
    mkdir -p "$HOME/.oh-my-zsh/tools" "$HOME/.oh-my-zsh/custom/plugins"
    printf '#!/bin/bash\necho "  __ omz-banner __"\necho "Hooray! Oh My Zsh has been updated!"\n' >"$HOME/.oh-my-zsh/tools/upgrade.sh"
    chmod +x "$HOME/.oh-my-zsh/tools/upgrade.sh"
    git_clone_fixture tmp zsh-x
    git clone -q "$TEST_HOME/remotes/zsh-x.git" "$HOME/.oh-my-zsh/custom/plugins/zsh-x"
    remote_commit zsh-x
    run "$SCRIPT" --only omz --json
    [ "$status" -eq 0 ]
    [[ "$output" == *"zsh-x +1 commit"* ]]
    [[ "$output" != *"omz-banner"* ]]
    [[ "$output" != *"Fast-forward"* ]]
    [ "$(json_status "$(last_json)" omz)" = "updated" ]
}

@test "repos varsayılan koşuda çalışmaz" {
    git_clone_fixture clones foo
    remote_commit foo
    old=$(head_of clones/foo)
    run "$SCRIPT" --skip-system
    [ "$(head_of clones/foo)" = "$old" ]
}

@test "log dosyasına renk kodu yazılmaz" {
    run bash -c 'sleep 2 | script -q /dev/null "$0" --only mas' "$SCRIPT"
    [[ "$output" == *$'\033'* ]]
    ! grep -q $'\033' "$(find "$LOGDIR" -name 'macupdate-*.log' | head -1)"
}

# ── v6.0.7: dry-run günlük döndürmez ─────────────────────────────

# LOG_MAX_DAYS'ten eski bir günlük ve JSON'unu LOGDIR'e koyar
old_log_fixture() {
    mkdir -p "$LOGDIR"
    echo eski >"$LOGDIR/macupdate-20200101-000000.log"
    echo '{}' >"$LOGDIR/macupdate-20200101-000000.json"
    touch -t 202001010000 "$LOGDIR/macupdate-20200101-000000.log" "$LOGDIR/macupdate-20200101-000000.json"
}

@test "--dry-run eski günlükleri silmez" {
    stub_brew
    old_log_fixture
    run "$SCRIPT" --only brew-services --dry-run
    [ "$status" -eq 0 ]
    [ -f "$LOGDIR/macupdate-20200101-000000.log" ]
    [ -f "$LOGDIR/macupdate-20200101-000000.json" ]
}

@test "dry-run olmayan koşu eski günlükleri döndürür" {
    stub_brew
    old_log_fixture
    run "$SCRIPT" --only brew-services
    [ "$status" -eq 0 ]
    [ ! -e "$LOGDIR/macupdate-20200101-000000.log" ]
    [ ! -e "$LOGDIR/macupdate-20200101-000000.json" ]
}
