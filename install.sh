#!/usr/bin/env bash
# Xray VLESS Encryption unified installer
# 版本: v26.08.27

set -euo pipefail

SCRIPT_VERSION="v26.08.27"
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_INSTALL_URL="https://raw.githubusercontent.com/XTLS/Xray-install/e741a4f56d368afbb9e5be3361b40c4552d3710d/install-release.sh"
XRAY_INSTALL_SHA256="7f70c95f6b418da8b4f4883343d602964915e28748993870fd554383afdbe555"
ENCRYPTION_INFO="/root/xray_encryption_info.txt"
REALITY_INFO="/root/xray_reality_info.txt"       # public_key|sni|short_id
SUBSCRIPTION_INFO="/root/xray_vless_link.txt"
AUTH_MODE="mlkem768"
TRAFFIC_MODE="native"
INSTALL_MODE=""
REALITY_SHORT_ID_SET=false
ROLLBACK_DIR=""
INSTALL_ROLLBACK_DIR=""

C_RESET='\033[0m'; C_BOLD='\033[1m'
C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'
C_BLUE='\033[0;34m'; C_CYAN='\033[0;36m'; C_MAGENTA='\033[0;35m'; C_WHITE='\033[1;37m'

color_enabled() {
    local fd="${1:-1}"
    [ "${NO_COLOR:-}" = 1 ] && return 1
    [ "${TERM:-}" = dumb ] && return 1
    [ "$fd" = 2 ] && [ -t 2 ] && return 0
    [ "$fd" = 1 ] && [ -t 1 ]
}
cecho() {
    local color="$1" message="$2" fd="${3:-1}"
    if color_enabled "$fd"; then
        printf '%b%s%b\n' "$color" "$message" "$C_RESET" >&"$fd"
    else
        printf '%s\n' "$message" >&"$fd"
    fi
}
info() { cecho "$C_BLUE" "[!] $1" 2; }
success() { cecho "$C_GREEN" "[✔] $1" 2; }
error() { cecho "$C_RED" "[✖] $1" 2; }
section_title() { cecho "$C_MAGENTA$C_BOLD" "◆ $1" 1; }

require_root_and_dependencies() {
    [ "$(id -u)" = 0 ] || { error "必须以 root 用户运行此脚本。"; exit 1; }
    local pm=""
    if command -v apt-get >/dev/null 2>&1; then pm=apt
    elif command -v dnf >/dev/null 2>&1; then pm=dnf
    elif command -v yum >/dev/null 2>&1; then pm=yum
    else error "仅支持 apt、dnf 或 yum 系统。"; exit 1; fi
    if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v sha256sum >/dev/null 2>&1; then
        info "正在安装缺失依赖（curl、jq、coreutils）..."
        case "$pm" in
            apt) apt-get update && apt-get install -y curl jq coreutils ;;
            dnf|yum) "$pm" install -y curl jq coreutils ;;
        esac
    fi
}

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
valid_sni() {
    local label
    local -a sni_labels
    [[ "$1" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    [ "${#1}" -le 253 ] || return 1
    [[ "$1" != .* && "$1" != *. && "$1" != *..* ]] || return 1
    IFS='.' read -r -a sni_labels <<< "$1"
    for label in "${sni_labels[@]}"; do
        [ "${#label}" -ge 1 ] && [ "${#label}" -le 63 ] || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
    done
    [ "${#sni_labels[@]}" -ge 2 ]
}
valid_short_id() { [[ "$1" =~ ^([0-9A-Fa-f]{2}){1,8}$ ]]; }
valid_uuid() { [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]; }
valid_auth() { [ "$1" = mlkem768 ] || [ "$1" = x25519 ]; }
valid_appearance() { [ "$1" = native ] || [ "$1" = xorpub ] || [ "$1" = random ]; }

xray_supports() {
    local output
    [ -x "$XRAY_BIN" ] || return 1
    output=$("$XRAY_BIN" vlessenc 2>/dev/null) || return 1
    grep -q 'Authentication: X25519, not Post-Quantum' <<< "$output" &&
        grep -q 'Authentication: ML-KEM-768, Post-Quantum' <<< "$output"
}
service_account() {
    local user group
    user=$(systemctl show -p User --value xray 2>/dev/null || true)
    group=$(systemctl show -p Group --value xray 2>/dev/null || true)
    for service_file in /etc/systemd/system/xray.service /lib/systemd/system/xray.service /usr/lib/systemd/system/xray.service; do
        [ -f "$service_file" ] || continue
        [ -n "$user" ] || user=$(awk -F= '/^[[:space:]]*User=/{print $2; exit}' "$service_file")
        [ -n "$group" ] || group=$(awk -F= '/^[[:space:]]*Group=/{print $2; exit}' "$service_file")
    done
    user=${user:-root}; group=${group:-$(id -gn "$user")}
    id "$user" >/dev/null 2>&1 && getent group "$group" >/dev/null 2>&1 || return 1
    printf '%s:%s\n' "$user" "$group"
}

run_official_installer() {
    local script_file log_file rc=0
    script_file=$(mktemp)
    log_file=$(mktemp)
    info "正在准备 Xray 安装程序..."
    if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 120 "$XRAY_INSTALL_URL" > "$script_file"; then
        rm -f "$script_file" "$log_file"; error "下载官方 Xray 安装脚本失败。"; return 1
    fi
    if ! printf '%s  %s\n' "$XRAY_INSTALL_SHA256" "$script_file" | sha256sum -c --status; then
        rm -f "$script_file" "$log_file"; error "官方安装脚本校验失败，已拒绝执行。"; return 1
    fi
    if ! grep -qE '(^#!.*bash|install-release)' "$script_file"; then
        rm -f "$script_file" "$log_file"; error "官方安装脚本内容校验失败。"; return 1
    fi
    bash "$script_file" "$@" >"$log_file" 2>&1 || rc=$?
    rm -f "$script_file"
    if [ "$rc" -ne 0 ]; then
        error "官方 Xray 安装程序执行失败，以下为末尾日志："
        tail -n 30 "$log_file" >&2 || true
        rm -f "$log_file"
        return "$rc"
    fi
    rm -f "$log_file"
}

latest_xray_version() {
    local tag
    tag=$(curl --fail --silent --show-error --location \
        --connect-timeout 10 --max-time 30 \
        -H 'Accept: application/vnd.github+json' \
        -H 'User-Agent: vless-encryption-installer' \
        https://api.github.com/repos/XTLS/Xray-core/releases/latest \
        | jq -r '.tag_name // empty') || return 1
    tag=${tag#v}
    [[ "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || return 1
    printf '%s\n' "$tag"
}

current_xray_version() {
    [ -x "$XRAY_BIN" ] || return 1
    "$XRAY_BIN" version 2>/dev/null | awk 'NR==1 {gsub(/^v/, "", $2); print $2; exit}'
}

extract_vlessenc_value() {
    local output="$1" section="$2" field="$3"
    awk -v section="$section" -v field="$field" '
        $0 == section { inside=1; next }
        inside && /^Authentication:/ { exit }
        inside && $0 ~ ("\\\"" field "\\\":[[:space:]]*\\\"") {
            value=$0; sub(/^[^\"]*\"[^\"]*\":[[:space:]]*\"/, "", value); sub(/\".*$/, "", value); print value; exit
        }
    ' <<< "$output"
}

validate_encryption_token() {
    local token="$1" expected_rtt="$2" prefix mode rtt segment normalized padding bytes valid_key=false
    local -a fields

    IFS='.' read -r -a fields <<< "$token"
    [ "${#fields[@]}" -ge 4 ] || return 1
    prefix=${fields[0]}; mode=${fields[1]}; rtt=${fields[2]}
    [ "$prefix" = mlkem768x25519plus ] && valid_appearance "$mode" && [ "$rtt" = "$expected_rtt" ] || return 1

    # Xray accepts optional short dot-separated padding fields. Key fields
    # are URL-safe Base64 and differ by direction/authentication mode.
    for segment in "${fields[@]:3}"; do
        [ -n "$segment" ] || return 1
        if [ "${#segment}" -lt 20 ]; then
            continue
        fi
        [[ "$segment" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
        normalized=$(printf '%s' "$segment" | tr '_-' '/+')
        padding=$(( (4 - ${#normalized} % 4) % 4 ))
        normalized+=$(printf '%*s' "$padding" '' | tr ' ' '=')
        bytes=$(printf '%s' "$normalized" | base64 -d 2>/dev/null | wc -c) || return 1
        if [ "$expected_rtt" = 600s ]; then
            [[ "$bytes" = 32 || "$bytes" = 64 ]] || return 1
        else
            [[ "$bytes" = 32 || "$bytes" = 1184 ]] || return 1
        fi
        valid_key=true
    done
    [ "$valid_key" = true ]
}

generate_encryption_pair() {
    local out section decryption encryption
    out=$("$XRAY_BIN" vlessenc 2>/dev/null) || true
    [ -n "$out" ] || { error "生成 VLESS Encryption 配置失败。"; return 1; }
    if [ "$AUTH_MODE" = mlkem768 ]; then section="Authentication: ML-KEM-768, Post-Quantum"; else section="Authentication: X25519, not Post-Quantum"; fi
    decryption=$(extract_vlessenc_value "$out" "$section" decryption)
    encryption=$(extract_vlessenc_value "$out" "$section" encryption)
    if ! validate_encryption_token "$decryption" 600s ||
       ! validate_encryption_token "$encryption" 0rtt; then
        error "无法解析或校验 Xray 生成的 VLESS Encryption 密钥串。"
        return 1
    fi
    decryption=$(awk -F. -v m="$TRAFFIC_MODE" 'BEGIN{OFS="."}{$2=m;print}' <<< "$decryption")
    encryption=$(awk -F. -v m="$TRAFFIC_MODE" 'BEGIN{OFS="."}{$2=m;print}' <<< "$encryption")
    printf '%s|%s\n' "$decryption" "$encryption"
}

validate_reality_key() {
    local key="$1" normalized padding bytes
    [[ "$key" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    normalized=$(printf '%s' "$key" | tr '_-' '/+')
    padding=$(( (4 - ${#normalized} % 4) % 4 )); normalized+=$(printf '%*s' "$padding" '' | tr ' ' '=')
    bytes=$(printf '%s' "$normalized" | base64 -d 2>/dev/null | wc -c) || return 1
    [ "$bytes" = 32 ]
}

generate_reality_keys() {
    local out private public
    out=$("$XRAY_BIN" x25519 2>/dev/null) || true
    private=$(awk '/^(PrivateKey:|Private key:)/ {print $NF; exit}' <<< "$out")
    public=$(awk '/^(Password|PublicKey:|Public key:)/ {print $NF; exit}' <<< "$out")
    if ! validate_reality_key "$private" || ! validate_reality_key "$public"; then
        error "无法解析或校验 REALITY 密钥对。"
        return 1
    fi
    printf '%s|%s\n' "$private" "$public"
}

write_config() {
    local port="$1" uuid="$2" decryption="$3" encryption="$4" mode="$5" private="${6:-}" public="${7:-}" sni="${8:-}" short_id="${9:-}"
    local tmp account user group enc_tmp reality_tmp test_log
    account=$(service_account) || { error "无法确定 Xray systemd 服务账户。"; return 1; }
    user=${account%%:*}; group=${account#*:}
    install -d -m 0755 "$(dirname "$XRAY_CONFIG")"
    tmp=$(mktemp "${XRAY_CONFIG}.tmp.XXXXXX.json")
    chmod 600 "$tmp"
    if [ "$mode" = reality ]; then
        jq -n --argjson port "$port" --arg uuid "$uuid" --arg decryption "$decryption" --arg private "$private" --arg sni "$sni" --arg sid "$short_id" '
          {log:{loglevel:"warning"},inbounds:[{listen:"::",port:$port,protocol:"vless",settings:{clients:[{id:$uuid,flow:"xtls-rprx-vision"}],decryption:$decryption},streamSettings:{network:"tcp",security:"reality",realitySettings:{show:false,dest:($sni+":443"),xver:0,serverNames:[$sni],privateKey:$private,shortIds:[$sid],fingerprint:"chrome"}}}],outbounds:[{protocol:"freedom",settings:{domainStrategy:"UseIPv4v6"}}]}' > "$tmp"
    else
        jq -n --argjson port "$port" --arg uuid "$uuid" --arg decryption "$decryption" '
          {log:{loglevel:"warning"},inbounds:[{listen:"::",port:$port,protocol:"vless",settings:{clients:[{id:$uuid,flow:"xtls-rprx-vision"}],decryption:$decryption}}],outbounds:[{protocol:"freedom",settings:{domainStrategy:"UseIPv4v6"}}]}' > "$tmp"
    fi
    test_log=$(mktemp)
    chmod 600 "$test_log"
    if ! "$XRAY_BIN" run -test -config "$tmp" >"$test_log" 2>&1; then
        error "Xray 配置校验失败，未替换现有配置。"; sed -n '1,40p' "$test_log" >&2 || true; rm -f "$tmp" "$test_log"; return 1
    fi
    rm -f "$test_log"
    ROLLBACK_DIR=$(mktemp -d /tmp/xray-rollback.XXXXXX); chmod 700 "$ROLLBACK_DIR"
    [ ! -f "$XRAY_CONFIG" ] || cp -p "$XRAY_CONFIG" "$ROLLBACK_DIR/config.json"
    [ ! -f "$ENCRYPTION_INFO" ] || cp -p "$ENCRYPTION_INFO" "$ROLLBACK_DIR/encryption.info"
    [ ! -f "$REALITY_INFO" ] || cp -p "$REALITY_INFO" "$ROLLBACK_DIR/reality.info"
    enc_tmp=$(mktemp "${ENCRYPTION_INFO}.tmp.XXXXXX"); chmod 600 "$enc_tmp"; printf '%s\n' "$encryption" > "$enc_tmp"
    if [ "$mode" = reality ]; then
        reality_tmp=$(mktemp "${REALITY_INFO}.tmp.XXXXXX"); chmod 600 "$reality_tmp"; printf '%s|%s|%s\n' "$public" "$sni" "$short_id" > "$reality_tmp"
    else
        reality_tmp=""
    fi
    if ! mv -f "$tmp" "$XRAY_CONFIG" || ! chmod 600 "$XRAY_CONFIG" || ! chown "$user:$group" "$XRAY_CONFIG"; then
        error "替换 Xray 配置失败，正在恢复旧配置。"
        rm -f "$tmp" "$enc_tmp" "$reality_tmp"
        rollback_config
        return 1
    fi
    if ! mv -f "$enc_tmp" "$ENCRYPTION_INFO"; then
        error "写入客户端加密信息失败，正在恢复旧配置。"
        rm -f "$reality_tmp"
        rollback_config
        return 1
    fi
    if [ "$mode" = reality ]; then
        if ! mv -f "$reality_tmp" "$REALITY_INFO"; then
            error "写入 REALITY 客户端信息失败，正在恢复旧配置。"
            rollback_config
            return 1
        fi
    elif ! rm -f "$REALITY_INFO"; then
        error "清理旧 REALITY 信息失败，正在恢复旧配置。"
        rollback_config
        return 1
    fi
}

public_ip() {
    local ip valid octet
    local -a ip_octets
    for endpoint in https://api-ipv4.ip.sb/ip https://api.ipify.org https://ip.seeip.org; do
        ip=$(curl -4s --max-time 5 "$endpoint" 2>/dev/null || true)
        if [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
            valid=true
            IFS='.' read -r -a ip_octets <<< "$ip"
            for octet in "${ip_octets[@]}"; do [ "$octet" -le 255 ] || valid=false; done
            [ "$valid" = true ] && { printf '%s\n' "$ip"; return; }
        fi
    done
    for endpoint in https://api-ipv6.ip.sb/ip https://api64.ipify.org; do
        ip=$(curl -6s --max-time 5 "$endpoint" 2>/dev/null || true)
        [[ "$ip" == *:* ]] && { printf '[%s]\n' "$ip"; return; }
    done
    return 1
}

show_subscription() {
    local address uuid port encryption security public sni sid link title
    if [ ! -f "$XRAY_CONFIG" ] || [ ! -f "$ENCRYPTION_INFO" ]; then
        error "缺少配置或客户端信息。"
        return 1
    fi
    jq -e '.inbounds[0].port and .inbounds[0].settings.clients[0].id and .inbounds[0].settings.decryption' "$XRAY_CONFIG" >/dev/null 2>&1 || {
        error "Xray 配置结构无效，无法生成订阅链接。"
        return 1
    }
    address=$(public_ip) || { error "无法获取公网 IP，无法生成订阅链接。"; return 1; }
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG"); port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG"); encryption=$(<"$ENCRYPTION_INFO")
    security=$(jq -r '.inbounds[0].streamSettings.security // "none"' "$XRAY_CONFIG")
    if [ "$security" = reality ]; then
        [ -f "$REALITY_INFO" ] || { error "缺少 REALITY 客户端信息。"; return 1; }
        IFS='|' read -r public sni sid < "$REALITY_INFO"
        title="$(hostname) VLESS-E-REALITY"
        link="vless://${uuid}@${address}:${port}?encryption=$(uri_encode "$encryption")&security=reality&sni=$(uri_encode "$sni")&sid=$(uri_encode "$sid")&fp=chrome&pbk=$(uri_encode "$public")&flow=xtls-rprx-vision&type=tcp#$(uri_encode "$title")"
    else
        title="$(hostname) VLESS-E"
        link="vless://${uuid}@${address}:${port}?encryption=$(uri_encode "$encryption")&flow=xtls-rprx-vision&type=tcp&security=none#$(uri_encode "$title")"
    fi
    local sub_tmp; sub_tmp=$(mktemp "${SUBSCRIPTION_INFO}.tmp.XXXXXX"); chmod 600 "$sub_tmp"
    printf '%s\n' "$link" > "$sub_tmp"; mv -f "$sub_tmp" "$SUBSCRIPTION_INFO"
    echo "----------------------------------------------------------------"
    cecho "$C_CYAN" " --- VLESS 订阅信息 --- "
    echo " 模式: $([ "$security" = reality ] && echo 'VLESS Encryption + REALITY + Vision' || echo 'VLESS Encryption')"
    echo " 端口: $port"; echo " UUID: $uuid"
    [ "$security" != reality ] || { echo " SNI: $sni"; echo " Short ID: $sid"; echo " PublicKey: $public"; }
    echo "----------------------------------------------------------------"; cecho "$C_GREEN" " 订阅链接（已保存到 $SUBSCRIPTION_INFO）："; echo; cecho "$C_GREEN" "$link"; echo "----------------------------------------------------------------"
}

print_step() { cecho "$C_BLUE" "  [$1/$2] $3" 2; }
print_divider() { cecho "$C_CYAN" "────────────────────────────────────────────────" 1; }

xray_status_line() {
    local version mode
    if [ ! -x "$XRAY_BIN" ]; then
        cecho "$C_YELLOW" "  ● Xray：未安装" 1
        return
    fi
    version=$("$XRAY_BIN" version 2>/dev/null | awk 'NR==1{print $2}' || true)
    local state_text state_color
    if systemctl is-active --quiet xray 2>/dev/null; then
        state_text="运行中"; state_color="$C_GREEN"
    else
        state_text="未运行"; state_color="$C_RED"
    fi
    if [ -f "$XRAY_CONFIG" ] && [ "$(jq -r '.inbounds[0].streamSettings.security // "none"' "$XRAY_CONFIG" 2>/dev/null)" = reality ]; then
        mode="VLESS Encryption + REALITY + Vision"
    else
        mode="VLESS Encryption"
    fi
    if color_enabled 1; then
        printf '  Xray：%b%s%b  |  %s\n' "$state_color" "$state_text" "$C_RESET" "${version:-未知}"
    else
        printf '  Xray：%s  |  %s\n' "$state_text" "${version:-未知}"
    fi
    cecho "$C_CYAN" "  当前配置：$mode" 1
}

uninstall_xray() {
    local confirm
    if [ ! -x "$XRAY_BIN" ]; then error "Xray 尚未安装。"; return 1; fi
    echo
    cecho "$C_YELLOW" "  即将卸载 Xray，并使用官方 --purge 清除 Xray 的全部配置和文件。"
    cecho "$C_YELLOW" "  这不仅限于本脚本生成的文件，操作不可恢复。"
    read -r -p "  确定继续？[y/N]: " confirm || { error "读取确认失败，已取消卸载。"; return 2; }
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then info "已取消卸载。"; return 0; fi
    print_step 1 3 "正在停止并卸载 Xray..."
    if ! run_official_installer remove --purge; then error "Xray 卸载失败。"; return 1; fi
    print_step 2 3 "正在清除客户端信息..."
    rm -f "$ENCRYPTION_INFO" "$REALITY_INFO" "$SUBSCRIPTION_INFO"
    print_step 3 3 "正在确认卸载结果..."
    if [ -e "$XRAY_BIN" ] || systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -qx 'xray.service'; then
        error "仍检测到 Xray 文件或服务，请使用菜单 5 查看日志。"
        return 1
    fi
    # 官方 --purge 不会删除本脚本及脚本生成在 /root 下的文件。
    rm -f "$ENCRYPTION_INFO" "$REALITY_INFO" "$SUBSCRIPTION_INFO"
    rm -rf /tmp/xray-rollback.* /tmp/xray-install-rollback.* 2>/dev/null || true
    if [ -f "${0:-}" ]; then rm -f -- "$0" || true; fi
    success "Xray、配置、客户端信息及本脚本已清除。"
}

rollback_config() {
    if [ -z "$ROLLBACK_DIR" ] || [ ! -d "$ROLLBACK_DIR" ]; then return 0; fi
    error "正在恢复上一次可用配置..."
    local failed=false
    if [ -f "$ROLLBACK_DIR/config.json" ]; then cp -p "$ROLLBACK_DIR/config.json" "$XRAY_CONFIG" || failed=true; else rm -f "$XRAY_CONFIG" || failed=true; fi
    if [ -f "$ROLLBACK_DIR/encryption.info" ]; then cp -p "$ROLLBACK_DIR/encryption.info" "$ENCRYPTION_INFO" || failed=true; else rm -f "$ENCRYPTION_INFO" || failed=true; fi
    if [ -f "$ROLLBACK_DIR/reality.info" ]; then cp -p "$ROLLBACK_DIR/reality.info" "$REALITY_INFO" || failed=true; else rm -f "$REALITY_INFO" || failed=true; fi
    if [ -f "$XRAY_CONFIG" ] && ! "$XRAY_BIN" run -test -config "$XRAY_CONFIG" >/dev/null 2>&1; then failed=true; fi
    rm -rf "$ROLLBACK_DIR" || failed=true
    ROLLBACK_DIR=""
    if [ "$failed" = true ]; then
        error "配置回滚失败，请立即检查并手动恢复 Xray 配置。"
        return 1
    fi
    success "配置回滚完成。"
}
clear_rollback() { [ -z "$ROLLBACK_DIR" ] || { rm -rf "$ROLLBACK_DIR"; ROLLBACK_DIR=""; }; }
begin_install_snapshot() {
    local dir
    dir=$(mktemp -d /tmp/xray-install-rollback.XXXXXX) || return 1
    if ! chmod 700 "$dir" ||
       ! { [ ! -e "$XRAY_BIN" ] || cp -p "$XRAY_BIN" "$dir/xray"; } ||
       ! { [ ! -f "$XRAY_CONFIG" ] || cp -p "$XRAY_CONFIG" "$dir/config.json"; } ||
       ! { [ ! -f "$ENCRYPTION_INFO" ] || cp -p "$ENCRYPTION_INFO" "$dir/encryption.info"; } ||
       ! { [ ! -f "$REALITY_INFO" ] || cp -p "$REALITY_INFO" "$dir/reality.info"; }; then
        rm -rf "$dir"
        return 1
    fi
    INSTALL_ROLLBACK_DIR="$dir"
}
restore_install_snapshot() {
    if [ -z "$INSTALL_ROLLBACK_DIR" ] || [ ! -d "$INSTALL_ROLLBACK_DIR" ]; then return 0; fi
    error "正在恢复安装前的配置和 Xray 核心..."
    local failed=false
    if [ -f "$INSTALL_ROLLBACK_DIR/xray" ]; then cp -p "$INSTALL_ROLLBACK_DIR/xray" "$XRAY_BIN" || failed=true; else rm -f "$XRAY_BIN" || failed=true; fi
    if [ -f "$INSTALL_ROLLBACK_DIR/config.json" ]; then cp -p "$INSTALL_ROLLBACK_DIR/config.json" "$XRAY_CONFIG" || failed=true; else rm -f "$XRAY_CONFIG" || failed=true; fi
    if [ -f "$INSTALL_ROLLBACK_DIR/encryption.info" ]; then cp -p "$INSTALL_ROLLBACK_DIR/encryption.info" "$ENCRYPTION_INFO" || failed=true; else rm -f "$ENCRYPTION_INFO" || failed=true; fi
    if [ -f "$INSTALL_ROLLBACK_DIR/reality.info" ]; then cp -p "$INSTALL_ROLLBACK_DIR/reality.info" "$REALITY_INFO" || failed=true; else rm -f "$REALITY_INFO" || failed=true; fi
    rm -rf "$INSTALL_ROLLBACK_DIR" || failed=true
    INSTALL_ROLLBACK_DIR=""
    if [ "$failed" = true ]; then error "安装回滚失败，请立即检查并手动恢复 Xray。"; return 1; fi
    success "安装回滚完成。"
}
clear_install_snapshot() { [ -z "$INSTALL_ROLLBACK_DIR" ] || { rm -rf "$INSTALL_ROLLBACK_DIR"; INSTALL_ROLLBACK_DIR=""; }; }
update_xray() {
    begin_install_snapshot || { error "无法创建更新回滚快照。"; return 1; }
    if ! run_official_installer install; then
        error "Xray 更新失败，正在回滚。"
    elif ! run_official_installer install-geodata; then
        error "GeoIP/GeoSite 更新失败，正在回滚。"
    elif ! restart_xray; then
        error "Xray 重启失败，正在回滚。"
    else
        clear_install_snapshot
        success "Xray 更新完成。"
        return 0
    fi
    restore_install_snapshot || true
    if ! restart_xray; then
        error "回滚后 Xray 仍未运行，请立即检查服务和配置。"
    else
        info "已恢复更新前的 Xray 核心。"
    fi
    return 1
}
abort_install() {
    restore_install_snapshot || true
    clear_rollback
    systemctl restart xray 2>/dev/null || true
    return 1
}
uri_encode() { jq -nr --arg value "$1" '$value | @uri'; }
restart_xray() {
    info "正在重启 Xray 服务..."
    if systemctl restart xray && sleep 1 && systemctl is-active --quiet xray; then
        success "Xray 服务已成功重启."; return 0
    fi
    error "Xray 服务启动失败。"
    return 1
}

install_selected() {
    local port="$1" uuid="$2" mode="$3" sni="${4:-}" sid="${5:-}" pair dec enc keys private public
    begin_install_snapshot || { error "无法创建安装回滚快照。"; return 1; }
    print_step 1 5 "正在安装 / 更新 Xray 核心..."
    run_official_installer install || { error "Xray 核心安装失败。"; abort_install; return 1; }
    print_step 2 5 "正在更新 GeoIP 和 GeoSite 数据..."
    run_official_installer install-geodata || { error "Geo 数据更新失败。"; abort_install; return 1; }
    print_step 3 5 "正在生成 VLESS Encryption 密钥材料..."
    xray_supports || { error "已安装的 Xray 不支持 VLESS Encryption。"; abort_install; return 1; }
    pair=$(generate_encryption_pair) || { abort_install; return 1; }; IFS='|' read -r dec enc <<< "$pair"
    if [ "$mode" = reality ]; then
        print_step 4 5 "正在生成 REALITY 密钥对..."
        keys=$(generate_reality_keys) || { abort_install; return 1; }; IFS='|' read -r private public <<< "$keys"
        print_step 5 5 "正在写入并校验 REALITY 配置..."
        write_config "$port" "$uuid" "$dec" "$enc" reality "$private" "$public" "$sni" "$sid" || { abort_install; return 1; }
    else
        print_step 4 5 "正在准备 VLESS Encryption 配置..."
        print_step 5 5 "正在写入并校验配置..."
        write_config "$port" "$uuid" "$dec" "$enc" encryption || { abort_install; return 1; }
    fi
    if ! restart_xray; then
        restore_install_snapshot || true
        clear_rollback
        if ! restart_xray; then
            error "回滚后 Xray 仍未运行，请立即检查服务和配置。"
        fi
        return 1
    fi
    clear_install_snapshot
    clear_rollback
    success "安装完成：$([ "$mode" = reality ] && echo 'VLESS Encryption + REALITY + Vision' || echo 'VLESS Encryption')。"
    show_subscription || info "Xray 已安装并运行，但暂时无法生成订阅链接。"
    return 0
}

interactive_install() {
    local choice port uuid sni="" sid="20220701" mode
    echo
    section_title "请选择安装模式（每次只能安装一种）"
    echo
    cecho "$C_GREEN" "  1. VLESS Encryption" 1
    cecho "$C_YELLOW" "  2. VLESS Encryption + REALITY + Vision" 1
    print_divider
    read -r -p "  请输入选项 [1-2]: " choice || { error "读取菜单输入失败，请在交互式终端中运行。"; return 2; }
    case "$choice" in 1) mode=encryption;; 2) mode=reality;; *) error "无效选项。"; return 1;; esac
    read -r -p "  端口 [1-65535]（默认 443）：" port || { error "读取端口失败。"; return 2; }; port=${port:-443}; valid_port "$port" || { error "端口无效。"; return 1; }
    read -r -p "  UUID（留空自动生成）：" uuid || { error "读取 UUID 失败。"; return 2; }; uuid=${uuid:-$("$XRAY_BIN" uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)}; valid_uuid "$uuid" || { error "UUID 格式无效。"; return 1; }
    if [ "$mode" = reality ]; then
        read -r -p "  REALITY SNI（默认 www.sega.com）：" sni || { error "读取 SNI 失败。"; return 2; }; sni=${sni:-www.sega.com}; valid_sni "$sni" || { error "SNI 格式无效。"; return 1; }
        read -r -p "  REALITY Short ID（默认 20220701）：" sid || { error "读取 Short ID 失败。"; return 2; }; sid=${sid:-20220701}; valid_short_id "$sid" || { error "Short ID 格式无效。"; return 1; }
    fi
    print_divider
    info "开始安装：$([ "$mode" = reality ] && echo 'VLESS Encryption + REALITY + Vision' || echo 'VLESS Encryption')"
    install_selected "$port" "$uuid" "$mode" "$sni" "$sid"
}

modify_config() {
    local current_mode target_mode choice port uuid sni="" sid="20220701" dec enc private public pair keys input
    if [ ! -f "$XRAY_CONFIG" ] || [ ! -f "$ENCRYPTION_INFO" ]; then
        error "未检测到可修改的 Xray 配置。"
        return 1
    fi

    current_mode=$(jq -r '.inbounds[0].streamSettings.security // "none"' "$XRAY_CONFIG")
    [ "$current_mode" = reality ] || current_mode=encryption
    port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG")
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG")

    echo
    section_title "当前模式：$([ "$current_mode" = reality ] && echo 'VLESS Encryption + REALITY + Vision' || echo 'VLESS Encryption')"
    cecho "$C_CYAN" "  请选择修改方式：" 1
    print_divider
    echo "  1. 保留当前模式，只修改参数"
    if [ "$current_mode" = reality ]; then
        echo "  2. 切换为 VLESS Encryption"
    else
        echo "  2. 切换为 VLESS Encryption + REALITY + Vision"
    fi
    echo "  0. 返回主菜单"
    print_divider
    read -r -p "  请输入选项 [0-2]: " choice || { error "读取菜单输入失败，请在交互式终端中运行。"; return 2; }
    case "$choice" in
        0) return ;;
        1) target_mode=$current_mode ;;
        2)
            if [ "$current_mode" = reality ]; then target_mode=encryption; else target_mode=reality; fi
            ;;
        *) error "无效选项。"; return 1 ;;
    esac

    read -r -p "  端口（当前 $port，回车保留）：" input || { error "读取端口失败。"; return 2; }; port=${input:-$port}; valid_port "$port" || { error "端口无效。"; return 1; }
    read -r -p "  UUID（当前 $uuid，回车保留）：" input || { error "读取 UUID 失败。"; return 2; }; uuid=${input:-$uuid}; valid_uuid "$uuid" || { error "UUID 格式无效。"; return 1; }

    if [ "$target_mode" = reality ]; then
        if [ "$current_mode" = reality ] && [ -f "$REALITY_INFO" ]; then
            IFS='|' read -r public sni sid < "$REALITY_INFO"
            private=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$XRAY_CONFIG")
        else
            sni="www.sega.com"
        fi
        read -r -p "  REALITY SNI（当前/默认 $sni，回车保留）：" input || { error "读取 SNI 失败。"; return 2; }; sni=${input:-$sni}; valid_sni "$sni" || { error "SNI 格式无效。"; return 1; }
        read -r -p "  REALITY Short ID（当前/默认 $sid，回车保留）：" input || { error "读取 Short ID 失败。"; return 2; }; sid=${input:-$sid}; valid_short_id "$sid" || { error "Short ID 格式无效。"; return 1; }
        if [ "$current_mode" != reality ]; then
            print_step 1 3 "正在生成 REALITY 密钥对..."
            keys=$(generate_reality_keys) || return 1
            IFS='|' read -r private public <<< "$keys"
        fi
    fi

    if [ "$target_mode" = "$current_mode" ]; then
        dec=$(jq -r '.inbounds[0].settings.decryption' "$XRAY_CONFIG")
        enc=$(<"$ENCRYPTION_INFO")
    else
        print_step 2 3 "正在生成 $([ "$target_mode" = reality ] && echo 'REALITY 模式' || echo 'Encryption 模式') 密钥材料..."
        pair=$(generate_encryption_pair) || return 1
        IFS='|' read -r dec enc <<< "$pair"
    fi
    print_step 3 3 "正在写入并校验新配置..."
    if [ "$target_mode" = reality ]; then
        write_config "$port" "$uuid" "$dec" "$enc" reality "$private" "$public" "$sni" "$sid"
    else
        write_config "$port" "$uuid" "$dec" "$enc" encryption
    fi
    if ! restart_xray; then
        error "正在回滚配置。"
        rollback_config || true
        if ! restart_xray; then
            error "回滚后 Xray 仍未运行，请立即检查服务和配置。"
        fi
        return 1
    fi
    clear_rollback
    success "配置已更新为 $([ "$target_mode" = reality ] && echo 'VLESS Encryption + REALITY + Vision' || echo 'VLESS Encryption')。"
    show_subscription
}

print_header() {
    clear 2>/dev/null || true
    cecho "$C_CYAN$C_BOLD" "╭──────────────────────────────────────────────╮" 1
    cecho "$C_CYAN$C_BOLD" "│        Xray VLESS Unified Installer          │" 1
    cecho "$C_WHITE$C_BOLD" "│                  ${SCRIPT_VERSION}                    │" 1
    cecho "$C_CYAN$C_BOLD" "╰──────────────────────────────────────────────╯" 1
    xray_status_line
    print_divider
}

main_menu() {
    local choice
    while true; do
        print_header
        echo
        cecho "$C_GREEN" "  1. 安装 / 重装" 1
        cecho "$C_GREEN" "  2. 更新 Xray" 1
        cecho "$C_CYAN" "  3. 重启 Xray" 1
        cecho "$C_RED" "  4. 卸载 Xray" 1
        cecho "$C_BLUE" "  5. 查看 Xray 日志" 1
        cecho "$C_YELLOW" "  6. 修改当前配置" 1
        cecho "$C_MAGENTA" "  7. 查看订阅信息" 1
        print_divider
        cecho "$C_RED$C_BOLD" "  0. 退出" 1
        print_divider
        read -r -p "  请输入选项 [0-7]: " choice || { error "读取菜单输入失败，请在交互式终端中运行。"; return 2; }
        case "$choice" in
            1) interactive_install ;;
            2)
                current_version=$(current_xray_version || true)
                latest_version=$(latest_xray_version || true)
                if [ -z "$current_version" ]; then
                    error "无法读取当前 Xray 版本，已取消更新。"
                elif [ -z "$latest_version" ]; then
                    error "无法获取 Xray 最新版本，已取消更新。"
                elif [ "$current_version" = "$latest_version" ]; then
                    success "Xray 已是最新版本（$current_version），无需更新。"
                else
                    info "当前版本：$current_version，最新版本：$latest_version"
                    info "正在更新 Xray..."
                    update_xray || true
                fi
                ;;
            3) restart_xray ;;
            4) uninstall_xray ;;
            5) journalctl -u xray -f --no-pager || true ;;
            6) modify_config ;;
            7) show_subscription ;;
            0) success "感谢使用。"; return ;;
            *) error "无效选项。" ;;
        esac
        read -r -n 1 -s -p "  按任意键返回菜单..."; echo
    done
}

show_help() {
    cat <<EOF
Xray VLESS Unified Installer ${SCRIPT_VERSION}

用法：
  $0                              # 交互式：选择安装其中一种模式
  $0 install [选项]               # 无交互安装

无交互模式选择（两者只能安装一个）：
  不带 --sni：VLESS Encryption
  带 --sni： VLESS Encryption + REALITY + Vision

选项：
  --port <端口>       监听端口（默认：443）
  --uuid <UUID>       UUID（默认：自动生成）
  --auth <模式>       mlkem768 或 x25519（默认：mlkem768）
  --mode <模式>       native、xorpub 或 random（默认：native）
  --sni <域名>        启用 REALITY + Vision；该模式必填
  --short-id <ID>     REALITY Short ID（默认：20220701）

示例：
  $0 install --port 12345
  $0 install --port 12345 --auth mlkem768 --mode native
  $0 install --port 12345 --sni www.sega.com
EOF
}

main() {
    require_root_and_dependencies
    if [ "${1:-}" != install ]; then main_menu; return; fi
    shift
    local port=443 uuid="" sni="" sid=20220701
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --port|--uuid|--auth|--mode|--sni|--short-id)
                if [ "$#" -lt 2 ] || [ -z "$2" ] || [[ "$2" = -* ]]; then
                    error "参数 $1 缺少有效值。"
                    exit 2
                fi
                case "$1" in --port) port=$2;; --uuid) uuid=$2;; --auth) AUTH_MODE=$2;; --mode) TRAFFIC_MODE=$2;; --sni) sni=$2;; --short-id) sid=$2; REALITY_SHORT_ID_SET=true;; esac; shift 2 ;;
            *) error "未知参数: $1"; exit 1 ;;
        esac
    done
    valid_port "$port" || { error "端口无效。"; exit 1; }; valid_auth "$AUTH_MODE" || { error "认证模式无效。"; exit 1; }; valid_appearance "$TRAFFIC_MODE" || { error "外观模式无效。"; exit 1; }
    uuid=${uuid:-$(cat /proc/sys/kernel/random/uuid)}
    valid_uuid "$uuid" || { error "UUID 格式无效。"; exit 1; }
    if [ -n "$sni" ]; then INSTALL_MODE=reality; valid_sni "$sni" || { error "SNI 域名格式无效。"; exit 1; }; valid_short_id "$sid" || { error "Short ID 格式无效。"; exit 1; }
    else INSTALL_MODE=encryption; [ "$REALITY_SHORT_ID_SET" = false ] || { error "--short-id 只能与 --sni（REALITY 模式）一起使用。"; exit 2; }; fi
    info "安装模式：$([ "$INSTALL_MODE" = reality ] && echo 'VLESS Encryption + REALITY + Vision' || echo 'VLESS Encryption')"
    install_selected "$port" "$uuid" "$INSTALL_MODE" "$sni" "$sid"
}

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then show_help; exit 0; fi
if [ ! -t 0 ] && [ "${1:-}" != install ]; then
    error "交互模式需要 TTY；请使用 install 子命令及非交互参数。"
    exit 2
fi
main "$@"
