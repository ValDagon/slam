#!/usr/bin/env bash
# S.L.A.M (Swift Light Agent for Mac) installer: builds the release binary,
# installs it to ~/.local/bin/slam, writes the LaunchAgent plist (FR-1) and
# bootstraps it into the user's gui domain.
#
# Usage:
#   ./install.sh              install (or reinstall) + start
#   ./install.sh uninstall    stop + remove plist + remove binary (data kept)
#   ./install.sh purge        full wipe: service, binary, data, caches, Keychain
#   ./install.sh start|stop|restart|status|logs   manage the installed agent

set -euo pipefail

LABEL="com.local.slam"
LEGACY_LABEL="com.local.swift-agent"
ACCOUNT="telegram-bot-token"
DOMAIN="gui/$(id -u)"
SERVICE="$DOMAIN/$LABEL"
LEGACY_SERVICE="$DOMAIN/$LEGACY_LABEL"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
BIN="$BIN_DIR/slam"
LEGACY_BIN="$BIN_DIR/swift-agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
CONFIG_DIR="$HOME/.config/slam"
SHARE_DIR="$HOME/.local/share/slam"
STATE_DIR="$HOME/.local/state/slam"
LOG_DIR="$STATE_DIR/logs"
CACHE_DIR="$HOME/Library/Caches/slam"
HTTP_DIR="$HOME/Library/HTTPStorages/slam"
LEGACY_CONFIG_DIR="$HOME/.config/swift-agent"
LEGACY_SHARE_DIR="$HOME/.local/share/swift-agent"
LEGACY_STATE_DIR="$HOME/.local/state/swift-agent"
LEGACY_CACHE_DIR="$HOME/Library/Caches/swift-agent"
LEGACY_HTTP_DIR="$HOME/Library/HTTPStorages/swift-agent"

die() { echo "install.sh: $*" >&2; exit 1; }

ensure_dirs() {
    mkdir -p "$BIN_DIR" "$LOG_DIR" "$HOME/Library/LaunchAgents"
}

build_binary() {
    echo "==> swift build -c release (может занять пару минут)"
    (cd "$REPO_DIR" && swift build -c release)
    cp "$REPO_DIR/.build/release/slam" "$BIN"
    # Копия с .build ломает подпись → macOS SIGKILL (OS_REASON_CODESIGNING).
    # Ad-hoc re-sign обязателен до запуска LaunchAgent / repair-keychain-acl.
    if ! codesign --force -s - "$BIN"; then
        die "codesign --force -s - $BIN failed (без подписи демон получит SIGKILL)"
    fi
    codesign -dv "$BIN" 2>&1 | sed 's/^/    /' || true
    echo "==> бинарник установлен и ad-hoc подписан: $BIN"
}

check_token() {
    # Не используем CLI `security find-generic-password`: ACL доверяет только
    # slam, не /usr/bin/security → диалог «security wants to use…».
    if "$BIN" probe-keychain >/dev/null 2>&1; then
        echo "==> токен в Keychain доступен без UI"
        return 0
    fi
    echo "!! токен не читается (нет записи или ACL не доверяет $BIN)."
    if [[ ! -t 0 ]]; then
        echo "!! stdin не TTY — пропускаем set-token; позже: $BIN set-token или $BIN repair-keychain-acl"
        return 0
    fi
    read -r -p "Вставить/обновить токен сейчас (slam set-token)? [Y/n] " answer
    if [[ ! "$answer" =~ ^[Nn]$ ]]; then
        "$BIN" set-token
    else
        echo "!! продолжаем: при необходимости позже $BIN set-token или $BIN repair-keychain-acl"
    fi
}

# Ad-hoc release binary меняет code signature при каждой сборке → login-keychain
# ACL иногда перестаёт узнавать ~/.local/bin/slam. Repair переписывает item
# и часто показывает диалог пароля — поэтому сначала probe без UI, repair только если надо.
repair_keychain_acl() {
    if "$BIN" probe-keychain >/dev/null 2>&1; then
        echo "==> Keychain ACL уже ок для $BIN (пароль не нужен)"
        return 0
    fi
    echo "==> обновляем Keychain ACL под $BIN"
    echo "    (если macOS спросит доступ к связке ключей — «Always Allow» один раз)"
    if ! "$BIN" repair-keychain-acl; then
        echo "!! ACL не обновлён. Выполните: $BIN set-token  (и Always Allow)"
    fi
}

write_plist() {
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
        <string>run</string>
    </array>

    <!-- FR-1: перезапускать только при аварийном выходе -->
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>

    <key>ThrottleInterval</key>
    <integer>10</integer>

    <!-- Без RunAtLoad KeepAlive SuccessfulExit=false не стартует джоб при логине:
         критерий «рестартовать при ненулевом exit» ложен, пока процесса ещё не было. -->
    <key>RunAtLoad</key>
    <true/>

    <key>ProcessType</key>
    <string>Background</string>

    <!-- под launchd файл-логгер пишет сам; зеркало в stderr отключаем,
         чтобы не дублировать строки в launchd-логах -->
    <key>EnvironmentVariables</key>
    <dict>
        <key>SLAM_QUIET_STDERR</key>
        <string>1</string>
    </dict>

    <key>StandardOutPath</key>
    <string>$LOG_DIR/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/launchd.err.log</string>
</dict>
</plist>
EOF
    echo "==> plist записан: $PLIST"
}

is_loaded() {
    launchctl print "$SERVICE" >/dev/null 2>&1
}

is_legacy_loaded() {
    launchctl print "$LEGACY_SERVICE" >/dev/null 2>&1
}

process_running() {
    pgrep -x slam >/dev/null 2>&1 || pgrep -x swift-agent >/dev/null 2>&1
}

migrate_dir() {
    local old="$1" new="$2"
    if [[ -e "$old" || -L "$old" ]]; then
        if [[ -e "$new" || -L "$new" ]]; then
            echo "==> $new уже есть — старый $old не трогаем (снос: ./install.sh purge)"
        else
            mkdir -p "$(dirname "$new")"
            mv "$old" "$new"
            echo "==> перенесено $old → $new"
        fi
    fi
}

# Pre-rebrand identity was swift-agent / com.local.swift-agent.
retire_legacy_service() {
    if is_legacy_loaded; then
        launchctl bootout "$LEGACY_SERVICE" >/dev/null 2>&1 || true
        echo "==> старый LaunchAgent $LEGACY_LABEL выгружен"
    fi
    rm_path "$LEGACY_PLIST"
    rm_path "$LEGACY_BIN"
}

migrate_legacy_data() {
    migrate_dir "$LEGACY_CONFIG_DIR" "$CONFIG_DIR"
    migrate_dir "$LEGACY_SHARE_DIR" "$SHARE_DIR"
    migrate_dir "$LEGACY_STATE_DIR" "$STATE_DIR"
    if [[ -f "$CONFIG_DIR/config.json" ]]; then
        local tmp
        tmp="$(mktemp)"
        sed -e 's|share/swift-agent|share/slam|g' \
            -e 's|config/swift-agent|config/slam|g' \
            -e 's|state/swift-agent|state/slam|g' \
            "$CONFIG_DIR/config.json" > "$tmp"
        mv "$tmp" "$CONFIG_DIR/config.json"
    fi
}

do_install() {
    ensure_dirs
    retire_legacy_service
    migrate_legacy_data
    build_binary
    check_token
    repair_keychain_acl
    write_plist
    do_restart
    echo
    echo "Готово. S.L.A.M (Swift Light Agent for Mac) — $SERVICE"
    echo "Проверка: $BIN version, логи: $LOG_DIR/"
    echo "Управление: launchctl kickstart -k $SERVICE (рестарт), ./install.sh uninstall (снос сервиса), ./install.sh purge (полный снос)"
}

wait_until_stopped() {
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if ! process_running && ! is_loaded && ! is_legacy_loaded; then
            return 0
        fi
        sleep 0.2
    done
    if process_running; then
        pkill -TERM -x slam >/dev/null 2>&1 || true
        pkill -TERM -x swift-agent >/dev/null 2>&1 || true
        sleep 0.4
        pkill -KILL -x slam >/dev/null 2>&1 || true
        pkill -KILL -x swift-agent >/dev/null 2>&1 || true
    fi
}

do_bootout() {
    if is_loaded; then
        launchctl bootout "$SERVICE" >/dev/null 2>&1 || true
        echo "==> агент выгружен из launchd"
    fi
    if is_legacy_loaded; then
        launchctl bootout "$LEGACY_SERVICE" >/dev/null 2>&1 || true
        echo "==> старый агент $LEGACY_LABEL выгружен"
    fi
    wait_until_stopped
}

rm_path() {
    local path="$1"
    if [[ -e "$path" || -L "$path" ]]; then
        rm -rf "$path"
        echo "==> удалён $path"
    fi
}

# Prefer the installed binary (its code signature is on the Keychain ACL).
# `security` is a fallback: ACL trusts slam, not /usr/bin/security,
# so that path may show a Keychain password sheet — Always Allow / enter password.
delete_keychain_service() {
    local svc="$1"
    if security find-generic-password -s "$svc" -a "$ACCOUNT" >/dev/null 2>&1; then
        if security delete-generic-password -s "$svc" -a "$ACCOUNT" >/dev/null 2>&1; then
            echo "==> запись Keychain $svc удалена через /usr/bin/security"
        else
            echo "!! Keychain: не удалось удалить $svc / $ACCOUNT"
            echo "   Откройте Связку ключей → login → найдите «$svc» и удалите вручную."
            echo "   (если macOS спросит пароль — это нормально: ACL доверяет slam, не security)"
            return 1
        fi
    fi
}

clear_keychain() {
    if [[ -x "$BIN" ]] && "$BIN" help 2>/dev/null | grep -q clear-token; then
        "$BIN" clear-token
        return 0
    fi
    local failed=0
    delete_keychain_service "$LABEL" || failed=1
    delete_keychain_service "$LEGACY_LABEL" || failed=1
    if [[ "$failed" -eq 0 ]]; then
        echo "==> запись Keychain уже отсутствует (или security её не видит)"
    fi
    return "$failed"
}

keychain_present() {
    security find-generic-password -s "$LABEL" -a "$ACCOUNT" >/dev/null 2>&1 \
        || security find-generic-password -s "$LEGACY_LABEL" -a "$ACCOUNT" >/dev/null 2>&1
}

do_uninstall() {
    do_bootout
    rm -f "$PLIST" && echo "==> удалён $PLIST"
    rm -f "$BIN" && echo "==> удалён $BIN"
    echo "==> данные сохранены: $SHARE_DIR, $STATE_DIR, $CONFIG_DIR, Keychain"
    echo "    полный снос: $0 purge"
}

# Full wipe of the installed daemon. Does not touch: this git repo, Ollama, ~/.local/bin itself.
do_purge() {
    do_bootout
    clear_keychain || true
    rm_path "$PLIST"
    rm_path "$BIN"
    rm_path "$CONFIG_DIR"
    rm_path "$SHARE_DIR"
    rm_path "$STATE_DIR"
    rm_path "$CACHE_DIR"
    rm_path "$HTTP_DIR"
    rm_path "$LEGACY_PLIST"
    rm_path "$LEGACY_BIN"
    rm_path "$LEGACY_CONFIG_DIR"
    rm_path "$LEGACY_SHARE_DIR"
    rm_path "$LEGACY_STATE_DIR"
    rm_path "$LEGACY_CACHE_DIR"
    rm_path "$LEGACY_HTTP_DIR"
    rm_path "$HOME/Library/HTTPStorages/swift-agent"
    rm_path "$HOME/Library/HTTPStorages/slam"
    rm_path "$HOME/Library/Preferences/com.local.swift-agent.plist"
    rm_path "$HOME/Library/Preferences/com.local.slam.plist"
    (
        shopt -s nullglob
        rm -f "$HOME/Library/Logs/DiagnosticReports/"*swift-agent*.ips
        rm -f "$HOME/Library/Logs/DiagnosticReports/"*slam*.ips
        rm -f "$HOME/Library/Application Support/CrashReporter/"swift-agent_*.plist
        rm -f "$HOME/Library/Application Support/CrashReporter/"slam_*.plist
    )
    echo "==> crash-репорты S.L.A.M / swift-agent сняты (если были)"

    echo
    echo "==> проверка следов"
    local leftover=0
    if is_loaded; then
        echo "!! launchd всё ещё держит $SERVICE"; leftover=1
    else
        echo "    launchd: не загружен"
    fi
    if is_legacy_loaded; then
        echo "!! launchd всё ещё держит $LEGACY_SERVICE"; leftover=1
    fi
    if process_running; then
        echo "!! процесс slam/swift-agent ещё жив"; leftover=1
    else
        echo "    процесс: нет"
    fi
    for path in "$PLIST" "$BIN" "$CONFIG_DIR" "$SHARE_DIR" "$STATE_DIR" "$CACHE_DIR" "$HTTP_DIR"; do
        if [[ -e "$path" || -L "$path" ]]; then
            echo "!! осталось $path"; leftover=1
        else
            echo "    нет $path"
        fi
    done
    if keychain_present; then
        echo "!! Keychain $LABEL / $ACCOUNT всё ещё PRESENT (секрет не печатаем)"
        leftover=1
    else
        echo "    Keychain: MISSING"
    fi
    echo
    echo "Не трогали: исходники репо, Ollama (модель qwen2.5:7b если ставили — снять отдельно:"
    echo "  ollama rm qwen2.5:7b)."
    echo "Токен бота в Telegram: отзовите у @BotFather, если больше не нужен."
    if [[ "$leftover" -ne 0 ]]; then
        echo "!! purge завершён с остатками — см. строки выше"
        return 1
    fi
    echo "Готово: установленный демон с машины снят."
}

do_start()    { ensure_dirs; launchctl bootstrap "$DOMAIN" "$PLIST"; echo "==> запущен"; }
do_stop()     { launchctl bootout "$SERVICE"; echo "==> остановлен"; }
do_restart()  { if is_loaded; then launchctl kickstart -k "$SERVICE"; else launchctl bootstrap "$DOMAIN" "$PLIST"; fi; echo "==> перезапущен"; }
do_status()   { if is_loaded; then launchctl print "$SERVICE" | sed -n '1,25p'; else echo "не загружен ($LABEL)"; fi; }
do_logs()     { exec tail -n 40 -F "$LOG_DIR/slam.log"; }

case "${1:-install}" in
    install)   do_install ;;
    uninstall)
        if [[ "${2:-}" == "--purge" || "${2:-}" == "-p" ]]; then
            do_purge
        else
            do_uninstall
        fi
        ;;
    purge)     do_purge ;;
    start)     do_start ;;
    stop)      do_stop ;;
    restart)   do_restart ;;
    status)    do_status ;;
    logs)      do_logs ;;
    *)         die "unknown command '$1' (install|uninstall|purge|start|stop|restart|status|logs)" ;;
esac
