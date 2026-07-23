#!/bin/sh
# sb — sing-box 极简生产管理器
# 支持：Debian/Ubuntu、Alpine Linux；运行前请审阅脚本并以 root 执行。
# 设计原则：显式命令、无隐式升级、原子配置提交、失败回滚、最小权限运行。
set -eu

PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL
umask 077

APP=sb
ROOT=/etc/sing-box
CONFIG_DIR=$ROOT/config.d
STATE_DIR=$ROOT/state
TLS_DIR=$ROOT/tls
DATA_DIR=/var/lib/sing-box
LOG_DIR=/var/log/sing-box
LOG_FILE=$LOG_DIR/sing-box.log
BIN=/usr/local/bin/sing-box
SERVICE=sing-box
SERVICE_USER=sing-box
SERVICE_GROUP=sing-box
LOCK_DIR=/run/lock/sb.lock
TRANSACTION_FILE=/var/lib/sb/restore-transaction
IDENTITY_DIR=/var/lib/sb
USER_MARKER=$IDENTITY_DIR/service-user-created
GROUP_MARKER=$IDENTITY_DIR/service-group-created
RELEASE_API=https://api.github.com/repos/SagerNet/sing-box/releases
SELF_REPO=fexumo/sing-box
SELF_BRANCH=main
SELF_TARGET=/usr/local/sbin/sb
DEFAULT_SNI=www.speedtest.net
DEFAULT_CERT_CN=www.bing.com
SS_METHOD=2022-blake3-aes-128-gcm
PROTOCOLS='ss trojan vless anytls hy2 snell'
OS_FAMILY=
LOCK_HELD=0
TXN_DIR=
RESTORE_GUARD=0
RESTORE_WAS_ACTIVE=0
INSTALL_GUARD=0
INSTALL_FRESH=0

# ---- 基础设施 -------------------------------------------------------------
die()  { printf '%s\n' "错误：$*" >&2; exit 1; }
warn() { printf '%s\n' "警告：$*" >&2; }
info() { printf '%s\n' "==> $*"; }
ok()   { printf '%s\n' "✓ $*"; }
need_root() { [ "$(id -u)" -eq 0 ] || die '请以 root 身份执行。'; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1；请先执行：$APP i"; }

atomic_install() {
    local source="$1" target="$2" mode="$3" owner="$4" group="$5" temp
    install -d -m 0755 "$(dirname "$target")"
    temp="${target}.new.$$"
    install -m "$mode" -o "$owner" -g "$group" "$source" "$temp" || { rm -f "$temp"; return 1; }
    mv -f "$temp" "$target"
}

process_start_time() {
    [ -r "/proc/$1/stat" ] || return 1
    awk '{print $22}' "/proc/$1/stat"
}

cleanup_orphan_transactions() {
    local dir id pattern
    [ -d "$ROOT" ] || return 0
    for pattern in '.config.d.old.*' '.config.d.new.*' '.state.old.*' '.state.new.*' '.tls.old.*' '.tls.new.*'; do
        for dir in "$ROOT"/$pattern; do
            [ -d "$dir" ] || continue
            id=${dir##*.}
            case "$id" in ''|*[!0-9]*) continue ;; esac
            rm -rf "$dir"
        done
    done
}

restore_transaction_dirs() {
    local id="$1" config_old state_old tls_old
    config_old="$ROOT/.config.d.old.$id"; state_old="$ROOT/.state.old.$id"; tls_old="$ROOT/.tls.old.$id"
    if [ -d "$config_old" ]; then rm -rf "$CONFIG_DIR"; mv "$config_old" "$CONFIG_DIR"; fi
    if [ -d "$state_old" ]; then rm -rf "$STATE_DIR"; mv "$state_old" "$STATE_DIR"; fi
    if [ -d "$tls_old" ]; then rm -rf "$TLS_DIR"; mv "$tls_old" "$TLS_DIR"; fi
    rm -rf "$ROOT/.config.d.new.$id" "$ROOT/.state.new.$id" "$ROOT/.tls.new.$id"
    rm -f "$TRANSACTION_FILE"
}

rollback_restore_dirs() {
    local id
    [ "${RESTORE_GUARD:-0}" = 1 ] || return 0
    id=$(cat "$TRANSACTION_FILE" 2>/dev/null || true)
    case "$id" in ''|*[!0-9]*) RESTORE_GUARD=0; return 0 ;; esac
    restore_transaction_dirs "$id"
    RESTORE_GUARD=0
    harden_permissions 2>/dev/null || true
    if [ "${RESTORE_WAS_ACTIVE:-0}" = 1 ]; then svc_restart >/dev/null 2>&1 || true; fi
}

recover_interrupted_restore() {
    local id
    [ -f "$TRANSACTION_FILE" ] || return 0
    id=$(cat "$TRANSACTION_FILE" 2>/dev/null || true)
    case "$id" in ''|*[!0-9]*) die "恢复事务标记损坏：$TRANSACTION_FILE" ;; esac
    warn "检测到中断的恢复事务 $id，正在恢复旧目录。"
    restore_transaction_dirs "$id"
    if id -u "$SERVICE_USER" >/dev/null 2>&1; then harden_permissions; fi
    if [ -x "$BIN" ] && has_any_protocol; then
        validate_config_dir "$CONFIG_DIR" || die '中断事务恢复后配置无效，请人工检查。'
        svc_enable; svc_restart
    fi
    ok '中断的恢复事务已回滚。'
}

rollback_install() {
    [ "${INSTALL_GUARD:-0}" = 1 ] || return 0
    [ "${INSTALL_FRESH:-0}" = 1 ] || return 0
    svc_stop; svc_disable
    rm -f "$BIN" "$(service_file)" /etc/logrotate.d/sing-box "$SELF_TARGET"
    rm -rf "$ROOT" "$DATA_DIR" "$LOG_DIR"
    remove_service_identity
    rm -rf "$IDENTITY_DIR"
}

cleanup() {
    rollback_restore_dirs
    rollback_install
    if [ -n "${TXN_DIR:-}" ]; then rm -rf "$TXN_DIR" 2>/dev/null || true; fi
    if [ "${LOCK_HELD:-0}" = 1 ]; then
        rm -f "$LOCK_DIR/pid" 2>/dev/null || true
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 129' HUP
trap 'exit 143' TERM

acquire_lock() {
    local owner='' expected_start='' actual_start=''
    mkdir -p /run/lock
    if [ -f "$LOCK_DIR/pid" ]; then
        read -r owner expected_start < "$LOCK_DIR/pid" 2>/dev/null || true
        case "$owner" in ''|*[!0-9]*) owner= ;; esac
        actual_start=$(process_start_time "$owner" 2>/dev/null || true)
        if [ -z "$owner" ] || [ -z "$expected_start" ] || [ "$expected_start" != "$actual_start" ]; then
            rm -rf "$LOCK_DIR"
        fi
    elif [ -d "$LOCK_DIR" ]; then
        rm -rf "$LOCK_DIR"
    fi
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s %s\n' "$$" "$(process_start_time "$$")" > "$LOCK_DIR/pid"
        LOCK_HELD=1
        TXN_DIR=$(mktemp -d /tmp/sb.XXXXXX) || die '无法创建事务目录。'
        chmod 0700 "$TXN_DIR"
        return 0
    fi
    die "已有 $APP 正在运行（锁：$LOCK_DIR）。"
}

detect_os() {
    if [ -f /etc/alpine-release ]; then OS_FAMILY=alpine
    elif [ -f /etc/debian_version ]; then OS_FAMILY=debian
    else die '仅支持 Debian/Ubuntu 与 Alpine Linux。'
    fi
}

machine_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf '%s' amd64 ;;
        aarch64|arm64) printf '%s' arm64 ;;
        *) die "不支持的架构：$(uname -m)" ;;
    esac
}

ensure_packages() {
    if [ "$OS_FAMILY" = debian ]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq curl jq openssl tar ca-certificates iproute2 logrotate libcap2-bin
    else
        apk add --no-cache curl jq openssl tar ca-certificates iproute2 logrotate libcap
    fi
}

ensure_runtime() {
    need_cmd "$BIN"
    need_cmd jq
    need_cmd openssl
    need_cmd ss
}

ensure_service_user() {
    install -d -m 0700 "$IDENTITY_DIR"
    if [ "$OS_FAMILY" = debian ]; then
        if ! grep -q "^${SERVICE_GROUP}:" /etc/group; then
            groupadd --system "$SERVICE_GROUP"
            getent group "$SERVICE_GROUP" | cut -d: -f3 > "$GROUP_MARKER"
        fi
        if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
            info "创建低权限服务账户 $SERVICE_USER"
            useradd --system --home-dir "$DATA_DIR" --no-create-home \
                --shell /usr/sbin/nologin --gid "$SERVICE_GROUP" "$SERVICE_USER"
            id -u "$SERVICE_USER" > "$USER_MARKER"
        else
            usermod -a -G "$SERVICE_GROUP" "$SERVICE_USER"
        fi
    else
        if ! grep -q "^${SERVICE_GROUP}:" /etc/group; then
            addgroup -S "$SERVICE_GROUP"
            awk -F: -v g="$SERVICE_GROUP" '$1==g {print $3}' /etc/group > "$GROUP_MARKER"
        fi
        if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
            info "创建低权限服务账户 $SERVICE_USER"
            adduser -S -D -H -s /sbin/nologin -G "$SERVICE_GROUP" "$SERVICE_USER"
            id -u "$SERVICE_USER" > "$USER_MARKER"
        else
            addgroup "$SERVICE_USER" "$SERVICE_GROUP" >/dev/null 2>&1 || true
        fi
    fi
    chmod 0600 "$USER_MARKER" "$GROUP_MARKER" 2>/dev/null || true
}

harden_permissions() {
    install -d -m 0750 -o root -g "$SERVICE_GROUP" "$ROOT" "$CONFIG_DIR" "$TLS_DIR"
    install -d -m 0700 -o root -g root "$STATE_DIR"
    install -d -m 0750 -o "$SERVICE_USER" -g "$SERVICE_GROUP" "$DATA_DIR" "$LOG_DIR"
    touch "$LOG_FILE"
    chown "$SERVICE_USER:$SERVICE_GROUP" "$LOG_FILE"
    chmod 0640 "$LOG_FILE"
    find "$CONFIG_DIR" "$TLS_DIR" -type f -exec chown root:"$SERVICE_GROUP" {} \; -exec chmod 0640 {} \; 2>/dev/null || true
    find "$STATE_DIR" -type f -exec chown root:root {} \; -exec chmod 0600 {} \; 2>/dev/null || true
}

ensure_layout() {
    ensure_service_user
    harden_permissions
}

config_file() { printf '%s/%s.json' "$CONFIG_DIR" "$1"; }
state_file()  { printf '%s/%s.json' "$STATE_DIR" "$1"; }
protocol_exists() { [ -f "$(config_file "$1")" ]; }

protocol_name() {
    case "$1" in
        ss) echo 'Shadowsocks 2022' ;; trojan) echo Trojan ;;
        vless) echo 'VLESS + Reality' ;; anytls) echo AnyTLS ;;
        hy2) echo Hysteria2 ;; snell) echo 'Snell v6' ;;
    esac
}

protocol_transport() {
    case "$1" in ss) echo 'TCP/UDP' ;; hy2) echo UDP ;; *) echo TCP ;; esac
}

assert_protocol_supported() {
    local protocol="$1" version major minor rest
    [ "$protocol" = snell ] || return 0
    version=$($BIN version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.]+)?' | head -n 1)
    major=${version%%.*}; rest=${version#*.}; minor=${rest%%.*}
    case "$major:$minor" in
        :|:*|*:|*[!0-9:]*) die '无法识别内核版本，不能确认 Snell v6 兼容性。' ;;
    esac
    if [ "$major" -lt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -lt 14 ]; }; then
        die "Snell v6 需要 sing-box 1.14+；当前为 $version。请显式安装兼容版本。"
    fi
}

normalise_protocol() {
    case "$1" in
        ss) printf '%s' ss ;;
        tj|trojan) printf '%s' trojan ;;
        vl|vless) printf '%s' vless ;;
        at|anytls) printf '%s' anytls ;;
        hy|hy2|hysteria2) printf '%s' hy2 ;;
        sn|snell) printf '%s' snell ;;
        *) die "未知协议：$1；可用：ss/tj/vl/at/hy/sn" ;;
    esac
}

has_any_protocol() {
    local p
    for p in $PROTOCOLS; do protocol_exists "$p" && return 0; done
    return 1
}

# ---- 服务层 ---------------------------------------------------------------
service_file() {
    if [ "$OS_FAMILY" = debian ]; then echo /etc/systemd/system/sing-box.service; else echo /etc/init.d/sing-box; fi
}

write_service() {
    local target temp
    target=$(service_file)
    temp=$TXN_DIR/service.new
    if [ "$OS_FAMILY" = debian ]; then
        cat > "$temp" <<EOF
[Unit]
Description=sing-box service
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_GROUP
WorkingDirectory=$DATA_DIR
ExecStartPre=$BIN check -D $DATA_DIR -C $CONFIG_DIR
ExecStart=$BIN run --disable-color -D $DATA_DIR -C $CONFIG_DIR
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3s
RestartPreventExitStatus=0
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=$DATA_DIR $LOG_DIR
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        atomic_install "$temp" "$target" 0644 root root || die '写入 systemd 服务失败。'
        systemctl daemon-reload
    else
        cat > "$temp" <<EOF
#!/sbin/openrc-run
name="sing-box"
description="sing-box proxy service"
supervisor="supervise-daemon"
command="$BIN"
command_args="run --disable-color -D $DATA_DIR -C $CONFIG_DIR"
command_user="$SERVICE_USER:$SERVICE_GROUP"
pidfile="/run/sing-box.pid"
supervisor_args="--pidfile \$pidfile"

depend() { after net dns; }
start_pre() { "$BIN" check -D "$DATA_DIR" -C "$CONFIG_DIR"; }
reload() { ebegin "Reloading \$RC_SVCNAME"; "\$supervisor" "\$RC_SVCNAME" --signal HUP; eend \$?; }
EOF
        atomic_install "$temp" "$target" 0755 root root || die '写入 OpenRC 服务失败。'
    fi
}

write_logrotate() {
    local temp=$TXN_DIR/logrotate.new
    cat > "$temp" <<EOF
$LOG_FILE {
    daily
    rotate 14
    size 20M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    su $SERVICE_USER $SERVICE_GROUP
}
EOF
    atomic_install "$temp" /etc/logrotate.d/sing-box 0644 root root || die '写入日志轮转配置失败。'
}

svc_enable() {
    if [ "$OS_FAMILY" = debian ]; then systemctl enable "$SERVICE" >/dev/null
    else rc-update add "$SERVICE" default >/dev/null 2>&1 || true
    fi
}
svc_disable() {
    if [ "$OS_FAMILY" = debian ]; then systemctl disable "$SERVICE" >/dev/null 2>&1 || true
    else rc-update del "$SERVICE" default >/dev/null 2>&1 || true
    fi
}
svc_restart() {
    if [ "$OS_FAMILY" = debian ]; then systemctl restart "$SERVICE"
    else rc-service "$SERVICE" restart
    fi
}
svc_stop() {
    if [ "$OS_FAMILY" = debian ]; then systemctl stop "$SERVICE" >/dev/null 2>&1 || true
    else rc-service "$SERVICE" stop >/dev/null 2>&1 || true
    fi
}
svc_active() {
    if [ "$OS_FAMILY" = debian ]; then systemctl is-active --quiet "$SERVICE"
    else rc-service "$SERVICE" status 2>/dev/null | grep -q started
    fi
}

validate_config_dir() {
    "$BIN" check -D "$DATA_DIR" -C "$1"
}

# ---- 内核安装与完整性校验 -------------------------------------------------
release_json() {
    local version=$1 url
    if [ -n "$version" ]; then
        case "$version" in v*) ;; *) version="v$version" ;; esac
        printf '%s' "$version" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.]+)?$' || die '非法版本号。'
        url="$RELEASE_API/tags/$version"
    else
        url="$RELEASE_API/latest"
    fi
    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 30 "$url"
}

fetch_binary() {
    # $1: 目标版本（空为最新）；$2: 输出二进制路径
    local version=$1 output=$2 json tag arch libc asset line url digest expected got tmp archive found
    json=$(release_json "$version") || die '无法读取 sing-box 发布信息。'
    tag=$(printf '%s' "$json" | jq -r '.tag_name // empty')
    [ -n "$tag" ] || die '发布信息中没有 tag_name。'
    arch=$(machine_arch)
    if [ "$OS_FAMILY" = alpine ]; then libc=musl; else libc=glibc; fi
    asset="sing-box-${tag#v}-linux-$arch-$libc.tar.gz"
    line=$(printf '%s' "$json" | jq -r --arg name "$asset" '.assets[] | select(.name == $name) | [.browser_download_url, .digest] | @tsv')
    [ -n "$line" ] || die "发布版本 $tag 不含资产：$asset"
    url=$(printf '%s\n' "$line" | cut -f1)
    digest=$(printf '%s\n' "$line" | cut -f2)
    case "$digest" in sha256:*) ;; *) die '发布资产没有可用的 SHA-256 摘要，已拒绝下载。' ;; esac
    expected=${digest#sha256:}
    [ "${#expected}" -eq 64 ] || die '发布资产 SHA-256 摘要格式异常。'

    tmp=$TXN_DIR/download
    rm -rf "$tmp"; mkdir -p "$tmp"
    archive=$tmp/asset.tar.gz
    info "下载 sing-box $tag（$arch/$libc）" >&2
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 600 -o "$archive" "$url" || die '下载失败。'
    got=$(sha256sum "$archive" | awk '{print $1}')
    [ "$got" = "$expected" ] || die 'SHA-256 校验失败，文件已拒绝使用。'
    tar -xzf "$archive" -C "$tmp"
    found=$(find "$tmp" -type f -name sing-box -perm -0100 | head -n 1)
    [ -n "$found" ] || die '压缩包中未找到可执行的 sing-box。'
    "$found" version >/dev/null 2>&1 || die '下载的 sing-box 无法执行。'
    install -m 0755 "$found" "$output"
    printf '%s\n' "$tag"
}

grant_bind_capability() {
    if command -v setcap >/dev/null 2>&1; then
        setcap cap_net_bind_service=+ep "$BIN" 2>/dev/null || warn '无法写入低端口文件能力；Alpine 下请使用 1024 以上端口。'
    fi
}

replace_binary() {
    local version="$1" candidate backup was_active=0 tag
    candidate="$BIN.new.$$"
    backup=
    if [ -x "$BIN" ]; then backup="$BIN.backup.$$"; fi
    if svc_active; then was_active=1; fi
    tag=$(fetch_binary "$version" "$candidate")
    if [ -f "$CONFIG_DIR/base.json" ] && ! "$candidate" check -D "$DATA_DIR" -C "$CONFIG_DIR"; then
        rm -f "$candidate"
        die '现有配置与目标内核不兼容，已拒绝更新。'
    fi
    if [ -n "$backup" ]; then cp -p "$BIN" "$backup"; fi
    mv -f "$candidate" "$BIN"
    grant_bind_capability
    if [ "$was_active" = 1 ] && ! svc_restart; then
        warn '新内核无法启动，正在回滚。'
        if [ -n "$backup" ]; then mv -f "$backup" "$BIN"; fi
        grant_bind_capability
        svc_restart >/dev/null 2>&1 || true
        die '内核更新失败，已回滚。'
    fi
    if [ -n "$backup" ]; then rm -f "$backup"; fi
    ok "sing-box $tag 已就绪"
}

write_base_config() {
    local base=$CONFIG_DIR/base.json
    [ -f "$base" ] && return 0
    jq -n --arg log "$LOG_FILE" '{log:{level:"info",timestamp:true,output:$log},outbounds:[{type:"direct",tag:"direct"}]}' > "$base"
    chown root:"$SERVICE_GROUP" "$base"; chmod 0640 "$base"
}

install_self() {
    local source target=$SELF_TARGET
    source=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
    if [ ! -f "$source" ] || ! sed -n '2p' "$source" | grep -q '^# sb '; then
        warn '当前通过标准输入或非脚本文件执行，未安装 sb 命令；请保存脚本后重新运行 install。'
        return 0
    fi
    atomic_install "$source" "$target" 0755 root root || die '部署管理命令失败。'
    ok "管理命令已部署：$target"
}

cmd_install() {
    local version=
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -v|--version) shift; [ "$#" -gt 0 ] || die '-v/--version 需要值。'; version=$1 ;;
            --help|-h) usage_install; return ;;
            *) die "未知选项：$1" ;;
        esac
        shift
    done
    ensure_packages
    INSTALL_FRESH=0
    if [ ! -x "$BIN" ] && [ ! -d "$ROOT" ] && ! id -u "$SERVICE_USER" >/dev/null 2>&1; then INSTALL_FRESH=1; fi
    INSTALL_GUARD=1
    ensure_layout
    write_service
    write_logrotate
    if [ -x "$BIN" ] && [ -z "$version" ]; then
        ok "已安装 sing-box $($BIN version | head -n 1)"
        grant_bind_capability
    else
        replace_binary "$version"
    fi
    write_base_config
    harden_permissions
    install_self
    if has_any_protocol; then
        info '检测到现有协议配置，校验并启动服务'
        validate_config_dir "$CONFIG_DIR"
        svc_enable
        svc_restart
        ok '安装完成；现有协议已恢复运行。'
    else
        ok '安装完成；服务将在首次添加协议后启用。'
    fi
    INSTALL_GUARD=0
}

cmd_update() {
    local version='' check_only=0 local_tag current
    [ -x "$BIN" ] || die "未安装 sing-box；请先执行：$APP i"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -v|--version) shift; [ "$#" -gt 0 ] || die '-v/--version 需要值。'; version=$1 ;;
            --check) check_only=1 ;;
            --help|-h) usage_update; return ;;
            *) die "未知选项：$1" ;;
        esac
        shift
    done
    ensure_runtime
    local_tag=$(release_json "${version:-}" | jq -r '.tag_name')
    current="v$($BIN version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.]+)?' | head -n 1)"
    if [ "$current" = "$local_tag" ]; then
        ok "已是目标版本：$current"
        return 0
    fi
    if [ "$check_only" = 1 ]; then
        printf '当前：%s\n目标：%s\n' "$current" "$local_tag"
        return 0
    fi
    replace_binary "$local_tag"
}

cmd_self_update() {
    local check_only=0 force=0 meta sha short url candidate expected actual target_tmp
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --check) check_only=1 ;;
            -f|--force) force=1 ;;
            --help|-h) echo "用法：$APP self-up [--check] [-f]"; return ;;
            *) die "未知选项：$1" ;;
        esac
        shift
    done
    need_cmd curl; need_cmd jq; need_cmd sha256sum
    meta=$(curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 30 \
        "https://api.github.com/repos/$SELF_REPO/commits/$SELF_BRANCH") || die '无法获取脚本更新信息。'
    sha=$(printf '%s' "$meta" | jq -r '.sha // empty')
    printf '%s' "$sha" | grep -Eq '^[0-9a-f]{40}$' || die '脚本更新提交 SHA 无效。'
    short=$(printf '%.8s' "$sha")
    url="https://raw.githubusercontent.com/$SELF_REPO/$sha/install.sh"
    candidate=$TXN_DIR/sb.new
    info "下载脚本提交 $short"
    curl -fLsS --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60 -o "$candidate" "$url" || die '脚本下载失败。'
    head -n 2 "$candidate" | grep -q '^# sb — sing-box ' || die '下载文件不是受支持的管理脚本。'
    sh -n "$candidate" || die '新脚本语法检查失败。'
    if command -v shellcheck >/dev/null 2>&1; then shellcheck -s dash "$candidate" || die '新脚本 ShellCheck 失败。'; fi
    if [ -f "$SELF_TARGET" ] && cmp -s "$candidate" "$SELF_TARGET"; then ok "脚本已是最新提交：$short"; return 0; fi
    if [ "$check_only" = 1 ]; then
        printf '发现脚本更新：%s\nSHA-256：%s\n' "$short" "$actual"
        return 0
    fi
    if [ ! -f "$SELF_TARGET" ] && [ "$force" != 1 ]; then die "未找到 $SELF_TARGET；如需安装请添加 -f。"; fi
    install -d -m 0755 "$(dirname "$SELF_TARGET")"
    target_tmp="${SELF_TARGET}.new.$$"
    install -m 0755 "$candidate" "$target_tmp" || { rm -f "$target_tmp"; die '无法写入新脚本。'; }
    mv -f "$target_tmp" "$SELF_TARGET" || { rm -f "$target_tmp"; die '脚本原子替换失败。'; }
    ok "管理脚本已更新：$short"
}

cmd_version() {
    [ "$#" -eq 0 ] || die "用法：$APP v"
    [ -x "$BIN" ] || die "未安装 sing-box；请先执行：$APP i"
    "$BIN" version | head -n 1
    if svc_active; then echo 'service: running'; else echo 'service: stopped'; fi
}

# ---- 配置事务 -------------------------------------------------------------
atomic_copy() {
    # 在目标目录创建临时文件并 rename，保证单文件替换原子性。
    local source=$1 target=$2 mode=$3 group=$4 temp
    temp="${target}.new.$$"
    cp "$source" "$temp"
    chown root:"$group" "$temp"; chmod "$mode" "$temp"
    mv -f "$temp" "$target"
}

stage_config() {
    # $1 protocol; $2 candidate json；返回临时配置目录
    local protocol=$1 candidate=$2 stage
    stage="$TXN_DIR/check-config"
    mkdir -p "$stage"
    cp -a "$CONFIG_DIR/." "$stage/"
    cp "$candidate" "$stage/$(basename "$(config_file "$protocol")")"
    printf '%s\n' "$stage"
}

commit_protocol() {
    # 校验候选目录，再替换配置与私有状态；服务启动失败时一起回滚。
    local protocol="$1" candidate="$2" state_candidate="${3:-}" target backup stage state_target state_backup
    target=$(config_file "$protocol")
    state_target=$(state_file "$protocol")
    backup="$TXN_DIR/${protocol}.old.json"
    state_backup="$TXN_DIR/${protocol}.old-state.json"
    if [ -f "$target" ]; then cp -p "$target" "$backup"; else : > "$backup.absent"; fi
    if [ -f "$state_target" ]; then cp -p "$state_target" "$state_backup"; else : > "$state_backup.absent"; fi
    stage=$(stage_config "$protocol" "$candidate")
    info '校验候选配置'
    if ! validate_config_dir "$stage"; then
        cleanup_protocol_tls "$protocol"
        die '候选配置未通过 sing-box 校验；未修改现有服务。'
    fi
    atomic_copy "$candidate" "$target" 0640 "$SERVICE_GROUP"
    if [ -n "$state_candidate" ]; then
        atomic_copy "$state_candidate" "$state_target" 0600 root
    else
        rm -f "$state_target"
    fi
    svc_enable
    if ! svc_restart; then
        warn '服务启动失败，正在恢复旧配置。'
        if [ -f "$backup" ]; then atomic_copy "$backup" "$target" 0640 "$SERVICE_GROUP"; else rm -f "$target"; fi
        if [ -f "$state_backup" ]; then atomic_copy "$state_backup" "$state_target" 0600 root; else rm -f "$state_target"; fi
        cleanup_protocol_tls "$protocol"
        svc_restart >/dev/null 2>&1 || true
        die '新配置未生效，旧配置已尝试恢复。'
    fi
    cleanup_protocol_tls "$protocol"
    ok "$(protocol_name "$protocol") 已应用并启动。"
}

remove_protocol_transaction() {
    local protocol=$1 target backup stage remaining=0 p
    target=$(config_file "$protocol")
    [ -f "$target" ] || die "$(protocol_name "$protocol") 未配置。"
    backup="$TXN_DIR/${protocol}.removed.json"
    cp -p "$target" "$backup"
    stage="$TXN_DIR/check-config"
    mkdir -p "$stage"; cp -a "$CONFIG_DIR/." "$stage/"; rm -f "$stage/$(basename "$target")"
    validate_config_dir "$stage" || die '删除后配置校验失败，已取消。'
    for p in $PROTOCOLS; do
        [ "$p" = "$protocol" ] && continue
        if protocol_exists "$p"; then remaining=1; break; fi
    done
    rm -f "$target"
    if [ "$remaining" = 1 ]; then
        if ! svc_restart; then
            atomic_copy "$backup" "$target" 0640 "$SERVICE_GROUP"
            svc_restart >/dev/null 2>&1 || true
            die '服务重启失败，已恢复协议配置。'
        fi
    else
        svc_stop; svc_disable
    fi
    rm -f "$(state_file "$protocol")"
    cleanup_protocol_tls "$protocol"
    ok "$(protocol_name "$protocol") 已删除。"
}

# ---- 输入校验与凭据 -------------------------------------------------------
validate_port() {
    case "$1" in ''|*[!0-9]*|0*) return 1 ;; esac
    [ "${#1}" -le 5 ] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

config_port_owner() {
    local wanted=$1 p f
    for p in $PROTOCOLS; do
        f=$(config_file "$p")
        [ -f "$f" ] || continue
        jq -e --argjson port "$wanted" '.inbounds[]? | select(.listen_port == $port)' "$f" >/dev/null 2>&1 && { echo "$p"; return; }
    done
    return 1
}

port_busy_on_host() {
    [ -n "$(ss -H -ltnu "sport = :$1" 2>/dev/null)" ]
}

assert_port_available() {
    local port=$1 protocol=$2 owner current=
    validate_port "$port" || die '端口必须为 1–65535 的十进制整数，且不能有前导零。'
    if [ "$OS_FAMILY" = alpine ] && [ "$port" -lt 1024 ]; then
        getcap "$BIN" 2>/dev/null | grep -q 'cap_net_bind_service' || die '当前文件系统不支持低端口能力；Alpine 下请改用 1024 以上端口。'
    fi
    owner=$(config_port_owner "$port" || true)
    [ -z "$owner" ] || [ "$owner" = "$protocol" ] || die "端口 $port 已由 $(protocol_name "$owner") 使用。"
    if [ -f "$(config_file "$protocol")" ]; then
        current=$(jq -r '.inbounds[0].listen_port' "$(config_file "$protocol")")
    fi
    if port_busy_on_host "$port" && [ "$current" != "$port" ]; then die "端口 $port 已被本机进程监听。"; fi
}

random_port() {
    local n port i=0
    while [ "$i" -lt 100 ]; do
        n=$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')
        port=$((n % 30000 + 20000))
        if ! config_port_owner "$port" >/dev/null 2>&1 && ! port_busy_on_host "$port"; then echo "$port"; return; fi
        i=$((i + 1))
    done
    die '无法找到空闲随机端口。'
}

validate_hostname() {
    local host="$1"
    case "$host" in
        ''|.*|*..*|*.*.|*[!A-Za-z0-9.-]*) return 1 ;;
    esac
    [ "${#host}" -le 253 ] || return 1
    printf '%s\n' "$host" | awk -F. '
        NF < 2 { exit 1 }
        { for (i=1; i<=NF; i++) if (length($i)<1 || length($i)>63 || $i ~ /^-/ || $i ~ /-$/) exit 1 }
    '
}

generate_hex() { openssl rand -hex "$1"; }
generate_password() { generate_hex 16; }
generate_ss_password() { openssl rand -base64 16 | tr -d '\n'; }

prepare_tls() {
    # 结果：TLS_CERT、TLS_KEY。自定义证书采用内容寻址文件名，绝不覆盖线上材料。
    local cert_pub key_pub fingerprint
    TLS_CERT=; TLS_KEY=
    if [ -n "$OPT_CERT" ] || [ -n "$OPT_KEY" ]; then
        if [ -z "$OPT_CERT" ] || [ -z "$OPT_KEY" ]; then die '--cert 与 --key 必须同时提供。'; fi
        if [ ! -r "$OPT_CERT" ] || [ ! -r "$OPT_KEY" ]; then die '无法读取证书或私钥。'; fi
        [ -n "$OPT_SNI" ] || die '使用自定义证书时必须提供 --sni 域名。'
        validate_hostname "$OPT_SNI" || die "SNI 不是有效域名：$OPT_SNI"
        openssl x509 -in "$OPT_CERT" -noout >/dev/null 2>&1 || die '证书不是有效 X.509 PEM。'
        openssl pkey -in "$OPT_KEY" -noout >/dev/null 2>&1 || die '私钥不是有效 PEM。'
        cert_pub=$(openssl x509 -in "$OPT_CERT" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
        key_pub=$(openssl pkey -in "$OPT_KEY" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
        [ "$cert_pub" = "$key_pub" ] || die '证书与私钥不匹配。'
        openssl x509 -in "$OPT_CERT" -checkend 86400 -noout >/dev/null 2>&1 || die '证书已过期或将在 24 小时内过期。'
        openssl x509 -in "$OPT_CERT" -checkhost "$OPT_SNI" -noout 2>/dev/null \
            | grep -Fq "Hostname $OPT_SNI does match certificate" \
            || die "证书 SAN 不包含 SNI：$OPT_SNI"
        fingerprint=$(cat "$OPT_CERT" "$OPT_KEY" | sha256sum | awk '{print substr($1,1,32)}')
        TLS_CERT="$TLS_DIR/${PROTO}-${fingerprint}.crt"
        TLS_KEY="$TLS_DIR/${PROTO}-${fingerprint}.key"
        install -m 0640 -o root -g "$SERVICE_GROUP" "$OPT_CERT" "$TLS_CERT"
        install -m 0640 -o root -g "$SERVICE_GROUP" "$OPT_KEY" "$TLS_KEY"
    else
        TLS_CERT=$TLS_DIR/selfsigned.crt; TLS_KEY=$TLS_DIR/selfsigned.key
        if [ ! -f "$TLS_CERT" ] || [ ! -f "$TLS_KEY" ]; then
            info '生成 ECDSA 自签名证书（仅适合未部署域名证书的场景）'
            openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 825 \
                -subj "/CN=$DEFAULT_CERT_CN" -addext "subjectAltName=DNS:$DEFAULT_CERT_CN" \
                -keyout "$TLS_KEY" -out "$TLS_CERT" >/dev/null 2>&1 || die '自签名证书生成失败。'
            chown root:"$SERVICE_GROUP" "$TLS_CERT" "$TLS_KEY"; chmod 0640 "$TLS_CERT" "$TLS_KEY"
        fi
    fi
}

cleanup_protocol_tls() {
    local protocol="$1" keep_cert='' keep_key='' item
    if [ -f "$(config_file "$protocol")" ]; then
        keep_cert=$(jq -r '.inbounds[0].tls.certificate_path // empty' "$(config_file "$protocol")")
        keep_key=$(jq -r '.inbounds[0].tls.key_path // empty' "$(config_file "$protocol")")
    fi
    for item in "$TLS_DIR/${protocol}-"*.crt "$TLS_DIR/${protocol}-"*.key; do
        [ -e "$item" ] || continue
        if [ "$item" != "$keep_cert" ] && [ "$item" != "$keep_key" ]; then rm -f "$item"; fi
    done
}

# ---- 协议构建 -------------------------------------------------------------
add_options() {
    PROTO=$(normalise_protocol "$1"); shift
    OPT_PORT=''; OPT_PASSWORD=''; OPT_SNI=''; OPT_CERT=''; OPT_KEY=''; OPT_UUID=''; OPT_SHORT_ID=''
    OPT_MODE=default FORCE=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -p|--port) shift; [ "$#" -gt 0 ] || die '-p/--port 需要值。'; OPT_PORT=$1 ;;
            -P|--password|--psk) shift; [ "$#" -gt 0 ] || die '-P/--password 需要值。'; OPT_PASSWORD=$1 ;;
            -s|--sni) shift; [ "$#" -gt 0 ] || die '-s/--sni 需要值。'; OPT_SNI=$1 ;;
            -c|--cert) shift; [ "$#" -gt 0 ] || die '-c/--cert 需要路径。'; OPT_CERT=$1 ;;
            -k|--key) shift; [ "$#" -gt 0 ] || die '-k/--key 需要路径。'; OPT_KEY=$1 ;;
            -u|--uuid) shift; [ "$#" -gt 0 ] || die '-u/--uuid 需要值。'; OPT_UUID=$1 ;;
            -i|--short-id) shift; [ "$#" -gt 0 ] || die '-i/--short-id 需要值。'; OPT_SHORT_ID=$1 ;;
            -m|--snell-mode) shift; [ "$#" -gt 0 ] || die '-m/--snell-mode 需要值。'; OPT_MODE=$1 ;;
            -f|--force) FORCE=1 ;;
            --help|-h) usage_add; exit 0 ;;
            *) die "未知选项：$1" ;;
        esac
        shift
    done
    [ -n "$OPT_PORT" ] || OPT_PORT=$(random_port)
    assert_port_available "$OPT_PORT" "$PROTO"
    if protocol_exists "$PROTO" && [ "$FORCE" != 1 ]; then
        die "$(protocol_name "$PROTO") 已存在；重建将轮换凭据，请显式添加 -f。"
    fi
}

build_protocol_config() {
    # 写入 $TXN_DIR/candidate.json；VLESS 另写 $TXN_DIR/state.json。
    local out="$TXN_DIR/candidate.json" pass sni uuid sid keys private public config_type
    case "$PROTO" in
        ss)
            pass=${OPT_PASSWORD:-$(generate_ss_password)}
            jq -n --argjson port "$OPT_PORT" --arg pass "$pass" --arg method "$SS_METHOD" \
                '{inbounds:[{type:"shadowsocks",tag:"ss-in",listen:"::",listen_port:$port,method:$method,password:$pass}]}' > "$out" ;;
        trojan|anytls|hy2)
            pass=${OPT_PASSWORD:-$(generate_password)}
            [ -n "$OPT_SNI" ] || OPT_SNI=$DEFAULT_CERT_CN
            prepare_tls
            config_type=$PROTO
            if [ "$PROTO" = hy2 ]; then config_type=hysteria2; fi
            jq -n --arg type "$config_type" --arg tag "${PROTO}-in" --argjson port "$OPT_PORT" --arg pass "$pass" --arg cert "$TLS_CERT" --arg key "$TLS_KEY" \
                '{inbounds:[{type:$type,tag:$tag,listen:"::",listen_port:$port,users:[{name:"user",password:$pass}],tls:{enabled:true,certificate_path:$cert,key_path:$key}}]}' > "$out"
            jq -n --arg sni "$OPT_SNI" '{sni:$sni}' > "$TXN_DIR/state.json" ;;
        vless)
            sni=${OPT_SNI:-$DEFAULT_SNI}
            uuid=${OPT_UUID:-$($BIN generate uuid)}
            sid=${OPT_SHORT_ID:-$(generate_hex 4)}
            printf '%s' "$sid" | grep -Eq '^[0-9a-fA-F]{1,16}$' || die '--short-id 必须是 1–16 位十六进制。'
            keys=$($BIN generate reality-keypair)
            private=$(printf '%s\n' "$keys" | awk '/^PrivateKey:/ {print $2}')
            public=$(printf '%s\n' "$keys" | awk '/^PublicKey:/ {print $2}')
            if [ -z "$private" ] || [ -z "$public" ]; then die '无法生成 Reality 密钥对。'; fi
            jq -n --argjson port "$OPT_PORT" --arg uuid "$uuid" --arg sni "$sni" --arg private "$private" --arg sid "$sid" \
                '{inbounds:[{type:"vless",tag:"vless-in",listen:"::",listen_port:$port,users:[{name:"user",uuid:$uuid,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:$sni,reality:{enabled:true,handshake:{server:$sni,server_port:443},private_key:$private,short_id:[$sid]}}}]}' > "$out"
            jq -n --arg public_key "$public" '{public_key:$public_key}' > "$TXN_DIR/state.json" ;;
        snell)
            case "$OPT_MODE" in default|unshaped|unsafe-raw) ;; *) die '--snell-mode 仅支持 default、unshaped、unsafe-raw。' ;; esac
            pass=${OPT_PASSWORD:-$(generate_password)}
            jq -n --argjson port "$OPT_PORT" --arg psk "$pass" --arg mode "$OPT_MODE" \
                '{inbounds:[{type:"snell",tag:"snell-in",listen:"::",listen_port:$port,version:6,psk:$psk,mode:$mode}]}' > "$out" ;;
    esac
}

cmd_add() {
    [ "$#" -gt 0 ] || die "用法：$APP a <协议> [选项]"
    ensure_runtime
    [ -f "$CONFIG_DIR/base.json" ] || die "未初始化；请先执行：$APP i"
    add_options "$@"
    assert_protocol_supported "$PROTO"
    build_protocol_config
    if [ -f "$TXN_DIR/state.json" ]; then
        commit_protocol "$PROTO" "$TXN_DIR/candidate.json" "$TXN_DIR/state.json"
    else
        commit_protocol "$PROTO" "$TXN_DIR/candidate.json"
    fi
    printf '\n连接信息（请安全保存）：\n'
    cmd_uri "$PROTO"
    if [ "$PROTO" = hy2 ]; then
        warn "请在防火墙/安全组放行 UDP/$OPT_PORT。"
    else
        warn "请在防火墙/安全组放行 $(protocol_transport "$PROTO")/$OPT_PORT。"
    fi
}

cmd_cert() {
    local protocol="${1:-}" cert='' key='' sni='' config state candidate old_cert old_key
    [ -n "$protocol" ] || die "用法：$APP cert <tj|at|hy> -s 域名 -c 证书 -k 私钥"
    protocol=$(normalise_protocol "$protocol"); shift
    case "$protocol" in trojan|anytls|hy2) ;; *) die 'cert 仅支持 tj、at、hy。' ;; esac
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -s|--sni) shift; [ "$#" -gt 0 ] || die '-s/--sni 需要值。'; sni=$1 ;;
            -c|--cert) shift; [ "$#" -gt 0 ] || die '-c/--cert 需要路径。'; cert=$1 ;;
            -k|--key) shift; [ "$#" -gt 0 ] || die '-k/--key 需要路径。'; key=$1 ;;
            *) die "未知选项：$1" ;;
        esac
        shift
    done
    if [ -z "$sni" ] || [ -z "$cert" ] || [ -z "$key" ]; then
        die "用法：$APP cert <tj|at|hy> -s 域名 -c 证书 -k 私钥"
    fi
    ensure_runtime
    protocol_exists "$protocol" || die "$(protocol_name "$protocol") 未配置。"
    PROTO=$protocol; OPT_SNI=$sni; OPT_CERT=$cert; OPT_KEY=$key
    prepare_tls
    config=$(config_file "$protocol"); state=$TXN_DIR/state.json; candidate=$TXN_DIR/candidate.json
    old_cert=$(jq -r '.inbounds[0].tls.certificate_path' "$config")
    old_key=$(jq -r '.inbounds[0].tls.key_path' "$config")
    jq --arg cert "$TLS_CERT" --arg key "$TLS_KEY" '.inbounds[0].tls.certificate_path=$cert | .inbounds[0].tls.key_path=$key' "$config" > "$candidate"
    jq -n --arg sni "$sni" '{sni:$sni}' > "$state"
    commit_protocol "$protocol" "$candidate" "$state"
    if [ "$old_cert" != "$TLS_CERT" ]; then
        case "$old_cert" in "$TLS_DIR/${protocol}-"*) rm -f "$old_cert" ;; esac
    fi
    if [ "$old_key" != "$TLS_KEY" ]; then
        case "$old_key" in "$TLS_DIR/${protocol}-"*) rm -f "$old_key" ;; esac
    fi
    ok "$(protocol_name "$protocol") 证书已原子更新；协议凭据未变。"
}

# ---- 查询、导出与删除 -----------------------------------------------------
endpoint() {
    if [ -n "${SB_ENDPOINT:-}" ]; then printf '%s' "$SB_ENDPOINT"; return; fi
    local ip
    for url in https://api.ipify.org https://ifconfig.me/ip https://ipinfo.io/ip; do
        ip=$(curl -fsS --connect-timeout 3 --max-time 6 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        [ -n "$ip" ] && { printf '%s' "$ip"; return; }
    done
    die '无法自动获取公网地址；请设置环境变量 SB_ENDPOINT 后重试。'
}

host_for_uri() { case "$1" in \[*\]) printf '%s' "$1" ;; *:*) printf '[%s]' "$1" ;; *) printf '%s' "$1" ;; esac; }
uri_escape() { jq -nr --arg s "$1" '$s|@uri'; }
tls_insecure() {
    if [ "$(jq -r '.inbounds[0].tls.certificate_path' "$(config_file "$1")")" = "$TLS_DIR/selfsigned.crt" ]; then echo 1; else echo 0; fi
}
tls_sni() {
    jq -r --arg fallback "$DEFAULT_CERT_CN" '.sni // $fallback' "$(state_file "$1")" 2>/dev/null || printf '%s' "$DEFAULT_CERT_CN"
}

print_uri() {
    local p=$1 host=$2 f port pass method sni uuid pub sid mode insecure auth
    f=$(config_file "$p"); port=$(jq -r '.inbounds[0].listen_port' "$f")
    case "$p" in
        ss)
            method=$(jq -r '.inbounds[0].method' "$f"); pass=$(jq -r '.inbounds[0].password' "$f")
            auth=$(printf '%s:%s' "$method" "$pass" | base64 | tr -d '\n=' | tr '+/' '-_')
            printf 'ss://%s@%s:%s#SS-2022\n' "$auth" "$host" "$port" ;;
        trojan)
            pass=$(jq -r '.inbounds[0].users[0].password' "$f"); sni=$(tls_sni trojan); insecure=$(tls_insecure trojan)
            printf 'trojan://%s@%s:%s?security=tls&allowInsecure=%s&sni=%s&type=tcp#Trojan\n' "$(uri_escape "$pass")" "$host" "$port" "$insecure" "$(uri_escape "$sni")" ;;
        anytls)
            pass=$(jq -r '.inbounds[0].users[0].password' "$f"); sni=$(tls_sni anytls); insecure=$(tls_insecure anytls)
            printf 'anytls://%s@%s:%s/?insecure=%s&sni=%s#AnyTLS\n' "$(uri_escape "$pass")" "$host" "$port" "$insecure" "$(uri_escape "$sni")" ;;
        hy2)
            pass=$(jq -r '.inbounds[0].users[0].password' "$f"); sni=$(tls_sni hy2); insecure=$(tls_insecure hy2)
            printf 'hysteria2://%s@%s:%s/?insecure=%s&sni=%s#Hysteria2\n' "$(uri_escape "$pass")" "$host" "$port" "$insecure" "$(uri_escape "$sni")" ;;
        vless)
            uuid=$(jq -r '.inbounds[0].users[0].uuid' "$f"); sni=$(jq -r '.inbounds[0].tls.server_name' "$f")
            sid=$(jq -r '.inbounds[0].tls.reality.short_id[0]' "$f"); pub=$(jq -r '.public_key // empty' "$(state_file vless)")
            [ -n "$pub" ] || die 'VLESS Reality 公钥状态文件缺失，无法安全导出 URI。'
            printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&flow=xtls-rprx-vision&type=tcp#VLESS-Reality\n' "$uuid" "$host" "$port" "$(uri_escape "$sni")" "$pub" "$sid" ;;
        snell)
            pass=$(jq -r '.inbounds[0].psk' "$f"); mode=$(jq -r '.inbounds[0].mode // "default"' "$f")
            printf 'Snell = snell, %s, %s, psk=%s, mode=%s, version=6, tfo=true\n' "$host" "$port" "$pass" "$mode" ;;
    esac
}

cmd_uri() {
    local requested=all p server=
    if [ "$#" -gt 0 ]; then
        case "$1" in -s|--server) ;; *) requested=$1; shift ;; esac
    fi
    while [ "$#" -gt 0 ]; do
        case "$1" in -s|--server) shift; [ "$#" -gt 0 ] || die '-s/--server 需要地址。'; server=$1 ;;
            *) die "未知选项：$1" ;; esac
        shift
    done
    ensure_runtime
    [ -n "$server" ] || server=$(endpoint)
    server=$(host_for_uri "$server")
    if [ "$requested" = all ]; then
        for p in $PROTOCOLS; do protocol_exists "$p" || continue; printf '[%s]\n' "$(protocol_name "$p")"; print_uri "$p" "$server"; done
    else
        p=$(normalise_protocol "$requested"); protocol_exists "$p" || die "$(protocol_name "$p") 未配置。"; print_uri "$p" "$server"
    fi
}

cmd_list() {
    [ "$#" -eq 0 ] || die "用法：$APP l"
    local p f port status=stopped
    ensure_runtime
    if svc_active; then status=running; fi
    printf '%-20s %-7s %-8s %s\n' '协议' '端口' '传输' '状态'
    printf '%s\n' '--------------------------------------------------------'
    for p in $PROTOCOLS; do
        f=$(config_file "$p"); [ -f "$f" ] || continue
        port=$(jq -r '.inbounds[0].listen_port' "$f")
        printf '%-20s %-7s %-8s %s\n' "$(protocol_name "$p")" "$port" "$(protocol_transport "$p")" "$status"
    done
}

cmd_check() {
    [ "$#" -eq 0 ] || die "用法：$APP c"
    ensure_runtime
    validate_config_dir "$CONFIG_DIR"
    if svc_active; then ok '配置有效；服务运行中。'; else warn '配置有效；服务当前未运行。'; fi
}

cmd_remove() {
    local p yes=0
    [ "$#" -gt 0 ] || die "用法：$APP d <协议> -y"
    p=$(normalise_protocol "$1"); shift
    while [ "$#" -gt 0 ]; do
        case "$1" in -y|--yes) [ "$yes" = 0 ] || die '确认参数重复。'; yes=1 ;; *) die "未知选项：$1" ;; esac
        shift
    done
    [ "$yes" = 1 ] || die '删除协议需要显式添加 -y。'
    ensure_runtime
    remove_protocol_transaction "$p"
}

cmd_logs() {
    local follow=0
    while [ "$#" -gt 0 ]; do
        case "$1" in -f|--follow) follow=1 ;; *) die "未知选项：$1" ;; esac
        shift
    done
    if [ "$follow" = 1 ]; then tail -n 100 -F "$LOG_FILE"; else tail -n 100 "$LOG_FILE" 2>/dev/null || true; fi
}

# ---- 备份 / 恢复 ----------------------------------------------------------
backup_path_safe() {
    local path="$1" name
    case "$path" in /*|..|../*|*/../*|*/..|*//*) return 1 ;; esac
    case "$path" in
        sing-box/config.d|sing-box/config.d/|sing-box/state|sing-box/state/|sing-box/tls|sing-box/tls/) return 0 ;;
        sing-box/config.d/*.json) name=${path#sing-box/config.d/} ;;
        sing-box/state/*.json) name=${path#sing-box/state/} ;;
        sing-box/tls/*.crt|sing-box/tls/*.key) name=${path#sing-box/tls/} ;;
        *) return 1 ;;
    esac
    case "$name" in ''|*/*) return 1 ;; esac
    return 0
}

backup_safe() {
    local archive="$1" list meta type count total
    list=$(tar -tzf "$archive") || return 1
    meta=$(tar -tvzf "$archive") || return 1
    count=$(printf '%s\n' "$list" | wc -l | tr -d ' ')
    total=$(printf '%s\n' "$meta" | awk '{sum += $3} END {print sum+0}')
    [ "$count" -le 100 ] && [ "$total" -le 67108864 ] || return 1
    printf '%s\n' "$list" | while IFS= read -r path; do backup_path_safe "$path" || exit 1; done || return 1
    # 拒绝链接、设备、FIFO 等非普通类型。
    type=$(printf '%s\n' "$meta" | awk '($1 !~ /^[-d]/) {print; exit}')
    [ -z "$type" ]
}

backup_dir_safe() {
    local dir="$1" uid mode group other
    uid=$(stat -c %u "$dir") || return 1
    mode=$(stat -c %a "$dir") || return 1
    group=$(printf '%s' "$mode" | sed 's/.*\(.\).$/\1/')
    other=${mode#"${mode%?}"}
    [ "$uid" = 0 ] || return 1
    case "$group$other" in *[2367]*) return 1 ;; esac
    return 0
}

cmd_backup() {
    local out="${1:-./sing-box-backup-$(date +%Y%m%d-%H%M%S).tar.gz}" out_dir base temp
    [ "$#" -le 1 ] || die "用法：$APP bak [输出文件]"
    [ -f "$CONFIG_DIR/base.json" ] || die '不存在可备份的 sing-box 配置。'
    out_dir=$(dirname "$out"); base=$(basename "$out")
    if [ "$base" = . ] || [ "$base" = .. ]; then die '备份文件名无效。'; fi
    out_dir=$(cd "$out_dir" 2>/dev/null && pwd -P) || die "备份目录不存在：$(dirname "$out")"
    backup_dir_safe "$out_dir" || die '备份目录必须由 root 所有且不可被组或其他用户写入。'
    out="$out_dir/$base"
    case "$out" in "$ROOT"/*|"$DATA_DIR"/*|"$LOG_DIR"/*) die '备份不能保存到 sing-box 配置、数据或日志目录。' ;; esac
    [ -L "$out" ] && die '备份输出不能是符号链接。'
    [ -e "$out" ] && die "备份文件已存在：$out"
    temp=$(mktemp "$out_dir/.sing-box-backup.XXXXXX") || die '无法创建安全备份临时文件。'
    chmod 0600 "$temp"
    if ! tar -C "$(dirname "$ROOT")" -czf "$temp" "$(basename "$ROOT")/config.d" "$(basename "$ROOT")/state" "$(basename "$ROOT")/tls"; then
        rm -f "$temp"
        die '导出备份失败。'
    fi
    [ "$(stat -c %h "$temp")" = 1 ] || { rm -f "$temp"; die '备份临时文件链接数异常。'; }
    if [ -e "$out" ] || [ -L "$out" ]; then
        rm -f "$temp"
        die "备份目标在导出期间出现：$out"
    fi
    mv -f "$temp" "$out" || { rm -f "$temp"; die '原子写入备份失败。'; }
    ok "备份已写入：$out"
    warn '备份含私钥与节点凭据；请离线加密保存。'
}

cmd_restore() {
    [ "$#" -eq 2 ] || die "用法：$APP res <备份.tar.gz> -y"
    local archive="${1:-}" yes="${2:-}" archive_copy extract verify config_new state_new tls_new config_old state_old tls_old file
    if [ -z "$archive" ] || { [ "$yes" != --yes ] && [ "$yes" != -y ]; }; then die "用法：$APP res <备份.tar.gz> -y"; fi
    [ -f "$archive" ] || die '备份文件不存在。'
    ensure_runtime
    ensure_layout
    archive_copy=$TXN_DIR/backup.tar.gz
    cp -p "$archive" "$archive_copy" || die '无法复制备份到私有事务目录。'
    chmod 0600 "$archive_copy"
    backup_safe "$archive_copy" || die '备份结构不安全或不兼容，已拒绝恢复。'
    extract=$TXN_DIR/restore
    verify=$TXN_DIR/verify-config
    mkdir -p "$extract" "$verify"
    tar -xzf "$archive_copy" -C "$extract"
    [ -f "$extract/sing-box/config.d/base.json" ] || die '备份缺少 base.json。'

    # 将证书绝对路径仅在验证副本中改写到隔离目录，不触碰线上材料。
    for file in "$extract/sing-box/config.d/"*.json; do
        [ -f "$file" ] || continue
        sed "s#$TLS_DIR#$extract/sing-box/tls#g" "$file" > "$verify/$(basename "$file")"
    done
    validate_config_dir "$verify" || die '备份配置未通过 sing-box 校验。'

    config_new="$ROOT/.config.d.new.$$"; state_new="$ROOT/.state.new.$$"; tls_new="$ROOT/.tls.new.$$"
    config_old="$ROOT/.config.d.old.$$"; state_old="$ROOT/.state.old.$$"; tls_old="$ROOT/.tls.old.$$"
    install -d -m 0700 "$(dirname "$TRANSACTION_FILE")"
    printf '%s\n' "$$" > "$TRANSACTION_FILE"
    cp -a "$extract/sing-box/config.d" "$config_new"
    cp -a "$extract/sing-box/state" "$state_new"
    cp -a "$extract/sing-box/tls" "$tls_new"
    RESTORE_WAS_ACTIVE=0
    if svc_active; then RESTORE_WAS_ACTIVE=1; fi
    RESTORE_GUARD=1
    mv "$CONFIG_DIR" "$config_old"; mv "$STATE_DIR" "$state_old"; mv "$TLS_DIR" "$tls_old"
    mv "$config_new" "$CONFIG_DIR"; mv "$state_new" "$STATE_DIR"; mv "$tls_new" "$TLS_DIR"
    harden_permissions

    if has_any_protocol; then
        svc_enable
        if ! svc_restart; then
            warn '恢复后服务启动失败，正在回滚所有配置与证书。'
            rollback_restore_dirs
            die '恢复失败，旧配置已恢复。'
        fi
    else
        svc_stop; svc_disable
    fi
    # 新目录已稳定运行后先清除持久标记，再删除旧目录；断电时最多遗留可安全清理的 old 目录。
    rm -f "$TRANSACTION_FILE"
    RESTORE_GUARD=0
    rm -rf "$config_old" "$state_old" "$tls_old"
    ok '备份已恢复。'
}

remove_service_identity() {
    local marked current
    if [ -f "$USER_MARKER" ] && id -u "$SERVICE_USER" >/dev/null 2>&1; then
        marked=$(cat "$USER_MARKER" 2>/dev/null || true); current=$(id -u "$SERVICE_USER")
        if [ -n "$marked" ] && [ "$marked" = "$current" ]; then
            if [ "$OS_FAMILY" = debian ]; then
                userdel "$SERVICE_USER" >/dev/null 2>&1 || warn "无法删除服务账户 $SERVICE_USER"
            else
                deluser "$SERVICE_USER" >/dev/null 2>&1 || warn "无法删除服务账户 $SERVICE_USER"
            fi
        else
            warn "服务账户 UID 已变化，跳过删除：$SERVICE_USER"
        fi
    fi
    if [ -f "$GROUP_MARKER" ]; then
        marked=$(cat "$GROUP_MARKER" 2>/dev/null || true)
        if [ "$OS_FAMILY" = debian ]; then
            current=$(getent group "$SERVICE_GROUP" 2>/dev/null | cut -d: -f3)
            if [ -n "$marked" ] && [ "$marked" = "$current" ]; then groupdel "$SERVICE_GROUP" >/dev/null 2>&1 || true; fi
        else
            current=$(awk -F: -v g="$SERVICE_GROUP" '$1==g {print $3}' /etc/group)
            if [ -n "$marked" ] && [ "$marked" = "$current" ]; then delgroup "$SERVICE_GROUP" >/dev/null 2>&1 || true; fi
        fi
    fi
}

cmd_uninstall() {
    local purge=0 yes=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -p|--purge) [ "$purge" = 0 ] || die '清除参数重复。'; purge=1 ;;
            -y|--yes) [ "$yes" = 0 ] || die '确认参数重复。'; yes=1 ;;
            *) die "未知选项：$1" ;;
        esac
        shift
    done
    [ "$yes" = 1 ] || die "用法：$APP un [-p] -y"
    svc_stop; svc_disable
    rm -f "$BIN" "$(service_file)" /etc/logrotate.d/sing-box "$SELF_TARGET"
    rm -f "$TRANSACTION_FILE"
    if [ "$OS_FAMILY" = debian ]; then systemctl daemon-reload; fi
    if [ "$purge" = 1 ]; then
        rm -rf "$ROOT" "$DATA_DIR" "$LOG_DIR"
        remove_service_identity
        rm -rf "$IDENTITY_DIR"
    fi
    ok 'sing-box 服务与内核已移除。'
    [ "$purge" = 1 ] || warn "配置、证书及节点凭据仍保留在 $ROOT；如需销毁请加 --purge。"
}

# ---- 帮助与入口 -----------------------------------------------------------
usage_short() {
    cat <<EOF
$APP — sing-box 极简管理器

  $APP i [-v 版本]              安装
  $APP a <协议> [选项]          添加/重建
  $APP d <协议> -y              删除
  $APP l                        列表
  $APP u [协议] [-s 地址]       URI
  $APP c                        检查
  $APP v                        版本/状态
  $APP cert <协议> [选项]       仅轮换证书
  $APP log [-f]                 日志
  $APP up [-v 版本]             更新内核
  $APP self-up [--check]        更新管理脚本
  $APP bak [文件]               备份
  $APP res <文件> -y            恢复
  $APP un [-p] -y               卸载

协议：ss  tj  vl  at  hy  sn
常用：-p 端口  -s SNI  -c 证书  -k 私钥  -f 强制重建
详细帮助：$APP help
EOF
}

usage() {
    cat <<EOF
$APP — sing-box 极简生产管理器

命令：
  i [ -v 版本 ]                         安装
  a <协议> [选项]                       添加或重建
  d <协议> -y                           删除
  l | c | v | log [-f]                 查询
  u [协议|all] [-s 地址]                URI
  cert <tj|at|hy> -s 域名 -c 证书 -k 私钥  轮换证书
  up [--check] [-v 版本]                检查或更新内核
  self-up [--check] [-f]                检查或更新管理脚本
  bak [文件] | res <文件> -y            备份或恢复
  un [-p] -y                            卸载

协议：ss  tj  vl  at  hy  sn
选项：-p 端口  -P 密码  -s SNI  -c 证书  -k 私钥  -f 强制重建
EOF
}
usage_install() { echo "用法：$APP i [-v vX.Y.Z]"; }
usage_update()  { echo "用法：$APP up [--check] [-v vX.Y.Z]"; }
usage_add()     { echo "用法：$APP a <ss|tj|vl|at|hy|sn> [-p 端口] [-f]"; }

main() {
    local command=${1:-}
    case "$command" in
        '') usage_short; return ;;
        help|--help|-h) usage; return ;;
    esac
    need_root; detect_os; acquire_lock
    recover_interrupted_restore
    cleanup_orphan_transactions
    shift || true
    case "$command" in
        i|install) cmd_install "$@" ;;
        up|update) cmd_update "$@" ;;
        self-up|self-update) cmd_self_update "$@" ;;
        a|add) cmd_add "$@" ;;
        d|del|rm|remove) cmd_remove "$@" ;;
        l|ls|list) cmd_list "$@" ;;
        c|check) cmd_check "$@" ;;
        v|version) cmd_version "$@" ;;
        cert) cmd_cert "$@" ;;
        u|uri) cmd_uri "$@" ;;
        log|logs) cmd_logs "$@" ;;
        bak|backup) cmd_backup "$@" ;;
        res|restore) cmd_restore "$@" ;;
        un|uninstall) cmd_uninstall "$@" ;;
        *) die "未知命令：$command；执行 '$APP help' 查看帮助。" ;;
    esac
}

main "$@"
