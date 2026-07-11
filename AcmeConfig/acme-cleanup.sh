#!/bin/bash

set -euo pipefail

# ============================================================================
# ACME.sh 清理脚本
# 功能：清理失败的安装，为重新安装做准备
# 用法：sudo bash acme-cleanup.sh
# ============================================================================

ACME_HOME="/var/lib/acme"

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

# 检查是否 root
if [[ $EUID -ne 0 ]]; then
    log_error "此脚本必须以 root 身份运行"
    exit 1
fi

log_info "========================================"
log_info "ACME.sh 清理脚本"
log_info "========================================"

# 停止和禁用 systemd 服务
log_info "停止 systemd 服务..."
systemctl stop acme-renew.timer 2>/dev/null || true
systemctl stop acme-renew.service 2>/dev/null || true
systemctl disable acme-renew.timer 2>/dev/null || true
systemctl disable acme-renew.service 2>/dev/null || true
rm -f /etc/systemd/system/acme-renew.service
rm -f /etc/systemd/system/acme-renew.timer
systemctl daemon-reload
systemctl reset-failed acme-renew.service 2>/dev/null || true
systemctl reset-failed acme-renew.timer 2>/dev/null || true

# 清理 acme.sh 安装
log_info "清理 acme.sh 安装..."
if [[ -d "$ACME_HOME/home/.acme.sh" ]]; then
    rm -rf "$ACME_HOME/home/.acme.sh"
    log_info "✓ 已清理 $ACME_HOME/home/.acme.sh"
fi

if [[ -d "$ACME_HOME/.acme.sh" ]]; then
    rm -rf "$ACME_HOME/.acme.sh"
    log_info "✓ 已清理 $ACME_HOME/.acme.sh"
fi

if [[ -f "$ACME_HOME/home/acme-install.sh" ]]; then
    rm -f "$ACME_HOME/home/acme-install.sh"
    log_info "✓ 已删除 $ACME_HOME/home/acme-install.sh"
fi

declare -a backup_dirs=()
shopt -s nullglob
backup_dirs=("$ACME_HOME"/home/.acme.sh.backup.*)
shopt -u nullglob
if (( ${#backup_dirs[@]} )); then
    rm -rf "${backup_dirs[@]}"
    log_info "✓ 已清理 ${#backup_dirs[@]} 个 acme.sh 备份目录"
fi

# 清理配置文件
log_info "清理配置文件..."
if [[ -f "$ACME_HOME/.profile" ]]; then
    rm -f "$ACME_HOME/.profile"
    log_info "✓ 已删除 $ACME_HOME/.profile"
fi

if [[ -d "$ACME_HOME/config" ]]; then
    find "$ACME_HOME/config" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    log_info "✓ 已清空 $ACME_HOME/config"
fi

if [[ -d "$ACME_HOME/certs" ]]; then
    find "$ACME_HOME/certs" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    log_info "✓ 已清空 $ACME_HOME/certs"
fi

if [[ -d "$ACME_HOME/logs" ]]; then
    find "$ACME_HOME/logs" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    log_info "✓ 已清空 $ACME_HOME/logs"
fi

# 清理 logrotate
rm -f /etc/logrotate.d/acme

# 清理 DNS 配置
log_info "清理 DNS 配置..."
rm -f /etc/acme/dns-config
rmdir /etc/acme 2>/dev/null || true

# 清理辅助脚本
log_info "清理辅助脚本..."
rm -f /usr/local/bin/acme-add
rm -f /usr/local/bin/acme-list
rm -f /usr/local/bin/acme-revoke

log_info "✓ 清理完成，现在可以重新运行 acme-init.sh"
