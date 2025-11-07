#!/bin/bash

set -euo pipefail

# ============================================================================
# ACME.sh 一键初始化脚本
# 功能：自动创建 acme 用户、目录、安装 acme.sh、配置 systemd
# 用法：sudo bash acme-init.sh
# ============================================================================

ACME_USER="acme"
ACME_HOME="/var/lib/acme"
ACME_CERTS_DIR="$ACME_HOME/certs"
ACME_CONFIG_DIR="$ACME_HOME/config"
ACME_EMAIL="${1:-admin@example.com}"  # 默认邮箱，可以第一个参数传入

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# ============================================================================
# 检查是否 root
# ============================================================================
if [[ $EUID -ne 0 ]]; then
    log_error "此脚本必须以 root 身份运行"
    exit 1
fi

log_info "========================================"
log_info "ACME.sh 自动化部署脚本"
log_info "========================================"
log_info "配置参数："
log_info "  ACME_USER: $ACME_USER"
log_info "  ACME_HOME: $ACME_HOME"
log_info "  ACME_EMAIL: $ACME_EMAIL"

# ============================================================================
# 第一步：创建 acme 用户
# ============================================================================
log_info "创建 acme 系统用户..."

# 检测 nologin 路径（P5 - 兼容性修复）
NOLOGIN_PATH=$(command -v nologin 2>/dev/null || echo "/usr/sbin/nologin")

if id "$ACME_USER" &>/dev/null; then
    log_warn "用户 $ACME_USER 已存在，跳过创建"
else
    useradd -r \
        -d "$ACME_HOME" \
        -s "$NOLOGIN_PATH" \
        -c "ACME certificate management" \
        "$ACME_USER"
    log_info "✓ 用户 $ACME_USER 创建成功"
fi

# ============================================================================
# 第二步：创建目录结构和安全配置
# ============================================================================
log_info "创建目录结构..."
mkdir -p "$ACME_HOME"/{home,certs,config,logs}

# P3 - 配置 umask 确保私钥安全（修复：写入正确的主目录）
if id "$ACME_USER" &>/dev/null; then
    log_info "配置 acme 用户安全设置..."
    # 为 acme 用户主目录创建 .profile
    cat > "$ACME_HOME/.profile" <<'EOF'
# ACME 用户安全配置
umask 077
export ACME_HOME=/var/lib/acme/home
EOF
    chown "$ACME_USER:$ACME_USER" "$ACME_HOME/.profile"
    chmod 0644 "$ACME_HOME/.profile"
    log_info "✓ acme 用户 umask 077 安全配置已生效"
fi

chown "$ACME_USER:$ACME_USER" "$ACME_HOME"/{home,config,logs}
chmod 0700 "$ACME_HOME"/{home,config,logs}

chown root:ssl-cert "$ACME_CERTS_DIR" 2>/dev/null || {
    # 如果 ssl-cert 组不存在，创建它
    groupadd -f ssl-cert
    chown root:ssl-cert "$ACME_CERTS_DIR"
}
chmod 0750 "$ACME_CERTS_DIR"

log_info "✓ 目录结构创建完成"
log_info "  $ACME_HOME/home    -> acme 用户 HOME"
log_info "  $ACME_CERTS_DIR    -> 证书存储目录"
log_info "  $ACME_CONFIG_DIR   -> 配置和日志"

# ============================================================================
# 第三步：安装 acme.sh
# ============================================================================
log_info "安装 acme.sh..."
if [[ -f "$ACME_HOME/home/.acme.sh/acme.sh" ]]; then
    log_warn "acme.sh 已安装，跳过重新安装"
else
    # P1 - 修复 curl|sh 安全漏洞：下载-校验-执行
    log_info "下载 acme.sh 安装脚本..."
    TEMP_SCRIPT=$(mktemp)
    trap "rm -f $TEMP_SCRIPT" EXIT
    
    if ! curl -fsSL https://get.acme.sh -o "$TEMP_SCRIPT"; then
        log_error "下载 acme.sh 安装脚本失败"
        exit 1
    fi
    
    # 基本安全校验
    if ! grep -q "acme.sh" "$TEMP_SCRIPT" || ! grep -q "install" "$TEMP_SCRIPT"; then
        log_error "下载的脚本不包含预期内容，可能被劫持"
        exit 1
    fi
    
    log_info "执行 acme.sh 安装..."
    
    # 复制临时脚本到 acme 用户可访问的位置
    ACME_TEMP_SCRIPT="$ACME_HOME/home/acme-install.sh"
    cp "$TEMP_SCRIPT" "$ACME_TEMP_SCRIPT"
    chown "$ACME_USER:$ACME_USER" "$ACME_TEMP_SCRIPT"
    chmod 0755 "$ACME_TEMP_SCRIPT"
    
    sudo -u "$ACME_USER" -H bash -c "
        cd $ACME_HOME/home
        # 确保加载安全配置
        if [[ -f $ACME_HOME/.profile ]]; then
            . $ACME_HOME/.profile
        fi
        bash $ACME_TEMP_SCRIPT email=$ACME_EMAIL 2>&1 | tee $ACME_CONFIG_DIR/install.log
    " || {
        log_error "acme.sh 安装失败，请检查日志：$ACME_CONFIG_DIR/install.log"
        exit 1
    }
    
    # 清理临时文件
    rm -f "$ACME_TEMP_SCRIPT"
    
    rm -f "$TEMP_SCRIPT"
    
    # 验证安装是否成功
    if [[ -f "$ACME_HOME/home/.acme.sh/acme.sh" ]]; then
        log_info "✓ acme.sh 安装成功"
    else
        log_error "acme.sh 安装失败，文件不存在"
        cat "$ACME_CONFIG_DIR/install.log" 2>/dev/null || echo "无法读取安装日志"
        exit 1
    fi
    
    # P2 - 加固 account.key 权限
    log_info "加固 ACME 账户私钥权限..."
    ACCOUNT_KEY="$ACME_HOME/home/.acme.sh/account.key"
    if [[ -f "$ACCOUNT_KEY" ]]; then
        chown root:acme "$ACCOUNT_KEY"
        chmod 0640 "$ACCOUNT_KEY"
        log_info "✓ account.key 权限已加固为 root:acme 640"
    fi
fi

# P10 - 设置默认 CA 为 Let's Encrypt
log_info "配置默认 CA 为 Let's Encrypt..."
sudo -u "$ACME_USER" -H bash -c "
    cd $ACME_HOME/home
    if [[ -f $ACME_HOME/.profile ]]; then
        . $ACME_HOME/.profile
    fi
    ./.acme.sh/acme.sh --set-default-ca --server letsencrypt
" 2>/dev/null || log_warn "设置默认 CA 失败，将使用 acme.sh 默认设置"

# ============================================================================
# 第四步：配置 nginx www-data 加入 ssl-cert 组
# ============================================================================
log_info "配置 nginx 权限..."
if id www-data &>/dev/null; then
    if groups www-data | grep -q ssl-cert; then
        log_warn "www-data 已在 ssl-cert 组中"
    else
        usermod -aG ssl-cert www-data
        log_info "✓ www-data 已加入 ssl-cert 组（重启 nginx 后生效）"
    fi
else
    log_warn "www-data 用户不存在，跳过组配置"
fi

# ============================================================================
# 第五步：创建 systemd service
# ============================================================================
log_info "配置 systemd 自动续期..."

cat > /etc/systemd/system/acme-renew.service <<'EOF'
[Unit]
Description=ACME certificate renewal
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=acme
Group=acme
WorkingDirectory=/var/lib/acme/home
Environment="HOME=/var/lib/acme/home"
# P6 - 显式指定 --home 参数
ExecStart=/var/lib/acme/home/.acme.sh/acme.sh --cron --home /var/lib/acme/home
StandardOutput=journal
StandardError=journal
SyslogIdentifier=acme-renew
EOF

cat > /etc/systemd/system/acme-renew.timer <<'EOF'
[Unit]
Description=Daily ACME certificate renewal check
Requires=acme-renew.service

[Timer]
# P11 - 移除冗余的 OnCalendar=daily，缩短随机延迟
OnCalendar=*-*-* 02:00:00
RandomizedDelaySec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable acme-renew.timer
systemctl start acme-renew.timer

log_info "✓ systemd 续期任务已配置和启动"

# P9 - 添加 logrotate 配置防止日志写满磁盘
log_info "配置日志轮替..."
cat > /etc/logrotate.d/acme <<'EOF'
/var/lib/acme/config/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    copytruncate
    create 644 acme acme
}
EOF

log_info "✓ logrotate 配置已创建"

# ============================================================================
# 第六步：创建 acme-add 辅助脚本
# ============================================================================
log_info "创建域名管理脚本..."

cat > /usr/local/bin/acme-add <<'SCRIPT'
#!/bin/bash
set -euo pipefail

# ============================================================================
# ACME 域名快速添加脚本
# 用法：sudo acme-add example.com [www.example.com] [dns/webroot]
# 示例：
#   sudo acme-add example.com                    # webroot 验证，单域名
#   sudo acme-add example.com www.example.com   # webroot 验证，多域名
#   sudo acme-add example.com dns                # DNS 验证（需配置 DNS API）
# ============================================================================

ACME_USER="acme"
ACME_HOME="/var/lib/acme"
ACME_CERTS_DIR="$ACME_HOME/certs"
ACME_CONFIG_DIR="$ACME_HOME/config"
WEBROOT="${WEBROOT:-/var/www/html}"
METHOD="${2:-webroot}"  # 默认 webroot，也可以是 dns 或其他

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $*"
}

# 检查参数
if [[ $# -lt 1 ]]; then
    echo "用法：sudo acme-add <domain1> [domain2] ... [dns|webroot]"
    echo "示例："
    echo "  sudo acme-add example.com                          # webroot 验证"
    echo "  sudo acme-add example.com www.example.com          # 多域名 webroot"
    echo "  sudo acme-add example.com dns                      # DNS 验证"
    echo "  sudo acme-add example.com '*.example.com' dns      # 泛域名 DNS"
    exit 1
fi

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
    log_error "此脚本必须以 root 身份运行"
    exit 1
fi

# 解析参数：最后一个参数可能是 dns/webroot
LAST_ARG="${@: -1}"
if [[ "$LAST_ARG" == "dns" ]]; then
    DOMAINS=("${@:1:$#-1}")
    METHOD="dns"
elif [[ "$LAST_ARG" == "webroot" ]]; then
    DOMAINS=("${@:1:$#-1}")
    METHOD="webroot"
else
    DOMAINS=("$@")
    METHOD="webroot"
fi

PRIMARY_DOMAIN="${DOMAINS[0]}"
log_info "========================================"
log_info "ACME 域名添加向导"
log_info "========================================"
log_info "主域名: $PRIMARY_DOMAIN"
log_info "其他域名: ${DOMAINS[*]:1}"
log_info "验证方式: $METHOD"

# ============================================================================
# 第一步：验证参数
# ============================================================================
log_step "验证参数..."
if [[ ! -d "$ACME_HOME/home/.acme.sh" ]]; then
    log_error "acme.sh 未安装，请先运行 acme-init.sh"
    exit 1
fi

if [[ "$METHOD" == "webroot" ]] && [[ ! -d "$WEBROOT" ]]; then
    log_warn "webroot 目录不存在，将自动创建: $WEBROOT"
    mkdir -p "$WEBROOT/.well-known/acme-challenge"
    chown www-data:www-data "$WEBROOT/.well-known/acme-challenge"
fi

log_info "✓ 参数验证通过"

# ============================================================================
# 第二步：申请证书
# ============================================================================
log_step "申请证书..."

# 构建 acme.sh 的域名参数
DOMAIN_ARGS=""
for domain in "${DOMAINS[@]}"; do
    DOMAIN_ARGS="$DOMAIN_ARGS -d $domain"
done

# 构建 acme.sh 命令
ACME_CMD="$ACME_HOME/home/.acme.sh/acme.sh --issue $DOMAIN_ARGS"

if [[ "$METHOD" == "webroot" ]]; then
    ACME_CMD="$ACME_CMD -w $WEBROOT"
elif [[ "$METHOD" == "dns" ]]; then
    log_warn "DNS 验证模式需要预先配置 DNS API 密钥"
    log_warn "例如 Cloudflare: export CF_Token='xxx' CF_Account_ID='yyy'"
    log_warn "建议将密钥存储在 /etc/acme/dns-config 文件中 (root:root 600)"
    ACME_CMD="$ACME_CMD --dns dns_cf"  # 默认 Cloudflare，可自定义
fi

ACME_CMD="$ACME_CMD --log $ACME_CONFIG_DIR/issue-$PRIMARY_DOMAIN.log"

# 执行申请
sudo -u "$ACME_USER" -H bash -c "
    cd $ACME_HOME/home
    if [[ -f $ACME_HOME/.profile ]]; then
        . $ACME_HOME/.profile
    fi
    $ACME_CMD
" || {
    log_error "证书申请失败，请检查日志："
    log_error "  $ACME_CONFIG_DIR/issue-$PRIMARY_DOMAIN.log"
    exit 1
}

log_info "✓ 证书申请成功"

# ============================================================================
# 第三步：安装证书
# ============================================================================
log_step "安装证书..."

CERT_KEY="$ACME_CERTS_DIR/$PRIMARY_DOMAIN.key"
CERT_CRT="$ACME_CERTS_DIR/$PRIMARY_DOMAIN.crt"
CERT_CA="$ACME_CERTS_DIR/$PRIMARY_DOMAIN.ca"

# P7 - 健壮化 reloadcmd，防止续期黑洞
RELOAD_CMD=""
if systemctl is-active -q nginx 2>/dev/null; then
    RELOAD_CMD="systemctl reload nginx || true"
    log_info "检测到 nginx 服务运行中，将配置自动重载"
elif systemctl is-active -q openresty 2>/dev/null; then
    RELOAD_CMD="systemctl reload openresty || true"
    log_info "检测到 openresty 服务运行中，将配置自动重载"
else
    RELOAD_CMD="true"
    log_warn "未检测到 nginx/openresty 服务，跳过自动重载配置"
fi

sudo -u "$ACME_USER" -H bash -c "
    cd $ACME_HOME/home
    if [[ -f $ACME_HOME/.profile ]]; then
        . $ACME_HOME/.profile
    fi
    $ACME_HOME/home/.acme.sh/acme.sh \
        --install-cert \
        -d $PRIMARY_DOMAIN \
        --key-file $CERT_KEY \
        --fullchain-file $CERT_CRT \
        --ca-file $CERT_CA \
        --reloadcmd '$RELOAD_CMD' \
        --log $ACME_CONFIG_DIR/install-$PRIMARY_DOMAIN.log
" || {
    log_error "证书安装失败，请检查日志："
    log_error "  $ACME_CONFIG_DIR/install-$PRIMARY_DOMAIN.log"
    exit 1
}

log_info "✓ 证书安装成功"

# ============================================================================
# 第四步：调整权限
# ============================================================================
log_step "调整文件权限..."
chown root:ssl-cert "$CERT_KEY" "$CERT_CRT" "$CERT_CA"
chmod 0640 "$CERT_KEY"
chmod 0644 "$CERT_CRT" "$CERT_CA"

log_info "✓ 权限调整完成"

# P12 - 证书安装后主动预检权限
log_step "预检证书权限..."
if id www-data &>/dev/null; then
    if sudo -u www-data cat "$CERT_KEY" > /dev/null 2>&1; then
        log_info "✓ www-data 用户可以正常读取私钥"
    else
        log_error "✗ www-data 用户无法读取私钥，请检查："
        log_error "  1. www-data 是否在 ssl-cert 组中: groups www-data"
        log_error "  2. 私钥文件权限: ls -la $CERT_KEY"
    fi
else
    log_warn "未找到 www-data 用户，跳过权限预检"
fi

# ============================================================================
# 第五步：输出完成信息
# ============================================================================
log_info "========================================"
log_info "✓ 域名 $PRIMARY_DOMAIN 添加成功！"
log_info "========================================"
log_info ""
log_info "证书文件位置："
log_info "  公钥：$CERT_CRT"
log_info "  私钥：$CERT_KEY"
log_info "  CA  ：$CERT_CA"
log_info ""
log_info "Nginx 配置示例："
log_info "  ssl_certificate $CERT_CRT;"
log_info "  ssl_certificate_key $CERT_KEY;"
log_info ""

# P13 - nginx 用户权限提醒
NGINX_USER=""
if systemctl is-active -q nginx 2>/dev/null; then
    NGINX_USER=$(ps -eo user,comm | grep -E 'nginx:|nginx$' | grep -v root | head -1 | awk '{print $1}')
elif systemctl is-active -q openresty 2>/dev/null; then
    NGINX_USER=$(ps -eo user,comm | grep -E 'openresty|nginx' | grep -v root | head -1 | awk '{print $1}')
fi

if [[ -n "$NGINX_USER" && "$NGINX_USER" != "www-data" ]]; then
    log_warn "检测到您的 Web 服务器运行用户是: $NGINX_USER"
    log_warn "请确保该用户在 ssl-cert 组中:"
    log_warn "  sudo usermod -aG ssl-cert $NGINX_USER"
    log_warn "  sudo systemctl restart nginx  # 或 openresty"
fi

log_info "后续操作："
log_info "  1. 在 nginx 中配置上述路径"
log_info "  2. 运行：nginx -t && systemctl reload nginx"
log_info "  3. 测试：curl -I https://$PRIMARY_DOMAIN"
log_info ""
log_info "日志位置："
log_info "  $ACME_CONFIG_DIR/issue-$PRIMARY_DOMAIN.log"
log_info "  $ACME_CONFIG_DIR/install-$PRIMARY_DOMAIN.log"
SCRIPT

chmod +x /usr/local/bin/acme-add

log_info "✓ 域名管理脚本已创建: /usr/local/bin/acme-add"

# ============================================================================
# 第七步：创建 acme-list 查询脚本 (P14)
# ============================================================================
log_info "创建证书查询脚本..."

cat > /usr/local/bin/acme-list <<'SCRIPT'
#!/bin/bash
set -euo pipefail

# ============================================================================
# ACME 证书查询脚本
# 用法：sudo acme-list [domain]
# 示例：
#   sudo acme-list                # 列出所有证书
#   sudo acme-list example.com    # 查询特定域名
# ============================================================================

ACME_USER="acme"
ACME_HOME="/var/lib/acme"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR]${NC} 此脚本必须以 root 身份运行"
    exit 1
fi

# 检查 acme.sh 是否安装
if [[ ! -f "$ACME_HOME/home/.acme.sh/acme.sh" ]]; then
    echo -e "${RED}[ERROR]${NC} acme.sh 未安装，请先运行 acme-init.sh"
    exit 1
fi

echo -e "${BLUE}========================================"
echo -e "ACME 证书列表"
echo -e "========================================${NC}"

if [[ $# -gt 0 ]]; then
    # 查询特定域名
    DOMAIN="$1"
    echo -e "${YELLOW}查询域名: $DOMAIN${NC}"
    echo ""
    
    sudo -u "$ACME_USER" -H bash -c "
        cd $ACME_HOME/home
        if [[ -f $ACME_HOME/.profile ]]; then
            . $ACME_HOME/.profile
        fi
        ./.acme.sh/acme.sh --list | grep -E '(Main_Domain|Created|Renew).*$DOMAIN' || echo '未找到该域名的证书'
    "
else
    # 列出所有证书
    echo -e "${YELLOW}所有已安装的证书:${NC}"
    echo ""
    
    sudo -u "$ACME_USER" -H bash -c "
        cd $ACME_HOME/home
        if [[ -f $ACME_HOME/.profile ]]; then
            . $ACME_HOME/.profile
        fi
        ./.acme.sh/acme.sh --list
    "
fi

echo ""
echo -e "${BLUE}证书文件位置: $ACME_HOME/certs/${NC}"
echo -e "${BLUE}配置和日志: $ACME_HOME/config/${NC}"

# 检查证书文件状态
if [[ -d "$ACME_HOME/certs" ]]; then
    echo ""
    echo -e "${YELLOW}证书文件状态:${NC}"
    ls -la "$ACME_HOME/certs"/ 2>/dev/null || echo "证书目录为空"
fi
SCRIPT

chmod +x /usr/local/bin/acme-list

log_info "✓ 证书查询脚本已创建: /usr/local/bin/acme-list"

# ============================================================================
# 第八步：创建 acme-revoke 吊销脚本 (P15)
# ============================================================================
log_info "创建证书吊销脚本..."

cat > /usr/local/bin/acme-revoke <<'SCRIPT'
#!/bin/bash
set -euo pipefail

# ============================================================================
# ACME 证书吊销和删除脚本
# 用法：sudo acme-revoke <domain> [--force]
# 示例：
#   sudo acme-revoke example.com           # 吊销证书（需确认）
#   sudo acme-revoke example.com --force   # 强制吊销（无需确认）
# ============================================================================

ACME_USER="acme"
ACME_HOME="/var/lib/acme"
ACME_CERTS_DIR="$ACME_HOME/certs"
ACME_CONFIG_DIR="$ACME_HOME/config"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# 检查参数
if [[ $# -lt 1 ]]; then
    echo "用法：sudo acme-revoke <domain> [--force]"
    echo "示例："
    echo "  sudo acme-revoke example.com           # 吊销证书"
    echo "  sudo acme-revoke example.com --force   # 强制吊销"
    exit 1
fi

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
    log_error "此脚本必须以 root 身份运行"
    exit 1
fi

DOMAIN="$1"
FORCE_MODE=""
if [[ "${2:-}" == "--force" ]]; then
    FORCE_MODE="yes"
fi

echo -e "${BLUE}========================================"
echo -e "ACME 证书吊销工具"
echo -e "========================================"
echo -e "域名: $DOMAIN${NC}"

# 检查证书是否存在
CERT_KEY="$ACME_CERTS_DIR/$DOMAIN.key"
CERT_CRT="$ACME_CERTS_DIR/$DOMAIN.crt"

if [[ ! -f "$CERT_CRT" ]]; then
    log_error "证书文件不存在: $CERT_CRT"
    exit 1
fi

# 显示证书信息
echo ""
log_info "证书信息："
openssl x509 -in "$CERT_CRT" -noout -subject -dates 2>/dev/null || log_warn "无法读取证书信息"

# 确认吊销
if [[ "$FORCE_MODE" != "yes" ]]; then
    echo ""
    log_warn "即将吊销域名 $DOMAIN 的证书，此操作不可恢复！"
    echo -n -e "${YELLOW}确认吊销? [yes/N]: ${NC}"
    read -r CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
        log_info "操作已取消"
        exit 0
    fi
fi

# 执行吊销
echo ""
log_info "吊销证书..."
sudo -u "$ACME_USER" -H bash -c "
    cd $ACME_HOME/home
    if [[ -f $ACME_HOME/.profile ]]; then
        . $ACME_HOME/.profile
    fi
    ./.acme.sh/acme.sh --revoke -d $DOMAIN --log $ACME_CONFIG_DIR/revoke-$DOMAIN.log
" || {
    log_error "证书吊销失败，请检查日志: $ACME_CONFIG_DIR/revoke-$DOMAIN.log"
    exit 1
}

# 删除证书文件
log_info "删除本地证书文件..."
rm -f "$ACME_CERTS_DIR/$DOMAIN.key"
rm -f "$ACME_CERTS_DIR/$DOMAIN.crt"
rm -f "$ACME_CERTS_DIR/$DOMAIN.ca"

log_info "✓ 域名 $DOMAIN 的证书已成功吊销并删除"
log_info ""
log_info "后续操作："
log_info "  1. 从 nginx 配置中移除该域名的 SSL 配置"
log_info "  2. 重载 nginx: systemctl reload nginx"
log_info ""
log_info "吊销日志: $ACME_CONFIG_DIR/revoke-$DOMAIN.log"
SCRIPT

chmod +x /usr/local/bin/acme-revoke

log_info "✓ 证书吊销脚本已创建: /usr/local/bin/acme-revoke"

# ============================================================================
# 完成总结
# ============================================================================
log_info ""
log_info "========================================"
log_info "✅ ACME.sh 系统初始化完成！"
log_info "========================================"
log_info "可用命令："
log_info "  acme-add <domain> [domain2] [dns|webroot]  # 申请证书"
log_info "  acme-list [domain]                         # 查询证书"
log_info "  acme-revoke <domain> [--force]             # 吊销证书"
log_info ""
log_info "示例用法："
log_info "  sudo acme-add example.com"
log_info "  sudo acme-add example.com www.example.com"
log_info "  sudo acme-add example.com '*.example.com' dns"
log_info "  sudo acme-list"
log_info "  sudo acme-revoke old-domain.com"
log_info ""
log_info "系统功能："
log_info "  ✓ 自动续期 (每日 2:00 检查)"
log_info "  ✓ 日志轮替 (防止磁盘满)"
log_info "  ✓ 权限预检 (避免配置错误)"
log_info "  ✓ 安全加固 (强化权限控制)"
log_info ""
log_info "重要提醒："
log_info "  - 证书文件: /var/lib/acme/certs/"
log_info "  - 配置日志: /var/lib/acme/config/"
log_info "  - 系统日志: journalctl -u acme-renew"
