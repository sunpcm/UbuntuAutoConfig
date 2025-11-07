#!/bin/bash

set -euo pipefail

# ============================================================================
# 快速修复当前 DNS 配置权限问题
# ============================================================================

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

# 检查是否 root
if [[ $EUID -ne 0 ]]; then
    log_error "此脚本必须以 root 身份运行"
    exit 1
fi

log_info "修复 DNS 配置文件权限..."

if [[ -f "/etc/acme/dns-config" ]]; then
    # 修复权限，让所有用户都能读取（这样 acme 用户才能加载环境变量）
    chmod 644 /etc/acme/dns-config
    chown root:root /etc/acme/dns-config
    
    log_info "✓ DNS 配置文件权限已修复"
    
    # 验证配置文件内容
    if grep -q "CF_Token" /etc/acme/dns-config; then
        log_info "✓ 检测到 Cloudflare 配置"
    fi
    
    # 测试能否加载
    if source /etc/acme/dns-config 2>/dev/null; then
        log_info "✓ DNS 配置文件可以正常加载"
    else
        log_error "✗ DNS 配置文件格式可能有问题"
    fi
    
else
    log_error "DNS 配置文件 /etc/acme/dns-config 不存在"
    log_info "请运行: sudo bash acme-dns-setup.sh 来创建配置"
    exit 1
fi

log_info ""
log_info "现在可以重新尝试 DNS 验证："
log_info "  sudo acme-add biubiuniu.com dns"
