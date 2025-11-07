#!/bin/bash

set -euo pipefail

# ============================================================================
# ACME 系统健康检查脚本
# 功能：检查 ACME 系统配置是否正常
# 用法：sudo bash acme-check.sh
# ============================================================================

ACME_USER="acme"
ACME_HOME="/var/lib/acme"
ACME_CERTS_DIR="$ACME_HOME/certs"
ACME_CONFIG_DIR="$ACME_HOME/config"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 检查是否 root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR]${NC} 此脚本必须以 root 身份运行"
    exit 1
fi

echo -e "${BLUE}========================================"
echo -e "ACME 系统健康检查"
echo -e "========================================${NC}"
echo ""

# ============================================================================
# 1. 检查用户和组
# ============================================================================
echo -e "${BLUE}[1/9]${NC} 检查用户和组配置..."

if id "$ACME_USER" &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} acme 用户存在"
    
    if groups "$ACME_USER" | grep -q ssl-cert; then
        echo -e "  ${GREEN}✓${NC} acme 在 ssl-cert 组"
    else
        echo -e "  ${RED}✗${NC} acme 不在 ssl-cert 组"
    fi
else
    echo -e "  ${RED}✗${NC} acme 用户不存在"
fi

if id www-data &>/dev/null; then
    if groups www-data | grep -q ssl-cert; then
        echo -e "  ${GREEN}✓${NC} www-data 在 ssl-cert 组"
    else
        echo -e "  ${YELLOW}!${NC} www-data 不在 ssl-cert 组（如使用 nginx 需要）"
    fi
fi

echo ""

# ============================================================================
# 2. 检查目录结构
# ============================================================================
echo -e "${BLUE}[2/9]${NC} 检查目录结构..."

for dir in "$ACME_HOME" "$ACME_HOME/home" "$ACME_CERTS_DIR" "$ACME_CONFIG_DIR" "$ACME_HOME/logs" "/etc/acme"; do
    if [[ -d "$dir" ]]; then
        echo -e "  ${GREEN}✓${NC} $dir 存在"
    else
        echo -e "  ${RED}✗${NC} $dir 不存在"
    fi
done

# 检查证书目录权限
if [[ -d "$ACME_CERTS_DIR" ]]; then
    CERT_DIR_PERMS=$(stat -c "%a" "$ACME_CERTS_DIR" 2>/dev/null || stat -f "%Lp" "$ACME_CERTS_DIR" 2>/dev/null || echo "unknown")
    CERT_DIR_OWNER=$(stat -c "%U:%G" "$ACME_CERTS_DIR" 2>/dev/null || stat -f "%Su:%Sg" "$ACME_CERTS_DIR" 2>/dev/null || echo "unknown")
    echo -e "  ${BLUE}ℹ${NC} 证书目录权限: $CERT_DIR_PERMS ($CERT_DIR_OWNER)"
fi

echo ""

# ============================================================================
# 3. 检查 acme.sh 安装
# ============================================================================
echo -e "${BLUE}[3/9]${NC} 检查 acme.sh 安装..."

if [[ -f "$ACME_HOME/home/.acme.sh/acme.sh" ]]; then
    echo -e "  ${GREEN}✓${NC} acme.sh 已安装"
    
    # 检查版本
    ACME_VERSION=$(sudo -u "$ACME_USER" bash -c "cd $ACME_HOME/home && ./.acme.sh/acme.sh --version 2>/dev/null | head -1" || echo "未知")
    echo -e "  ${BLUE}ℹ${NC} 版本: $ACME_VERSION"
else
    echo -e "  ${RED}✗${NC} acme.sh 未安装"
fi

echo ""

# ============================================================================
# 4. 检查 systemd 服务
# ============================================================================
echo -e "${BLUE}[4/9]${NC} 检查 systemd 自动续期..."

if systemctl is-enabled acme-renew.timer &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} acme-renew.timer 已启用"
else
    echo -e "  ${RED}✗${NC} acme-renew.timer 未启用"
fi

if systemctl is-active acme-renew.timer &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} acme-renew.timer 运行中"
    
    # 显示下次执行时间
    NEXT_RUN=$(systemctl status acme-renew.timer 2>/dev/null | grep -i "trigger" | head -1 || echo "  未知")
    echo -e "  ${BLUE}ℹ${NC} 下次执行: $NEXT_RUN"
else
    echo -e "  ${RED}✗${NC} acme-renew.timer 未运行"
fi

# 检查 service 文件
if [[ -f "/etc/systemd/system/acme-renew.service" ]]; then
    echo -e "  ${GREEN}✓${NC} acme-renew.service 文件存在"
    
    # 检查是否以 root 运行
    if grep -q "User=root" /etc/systemd/system/acme-renew.service; then
        echo -e "  ${GREEN}✓${NC} service 配置为 root 运行（可重启服务）"
    else
        echo -e "  ${YELLOW}!${NC} service 未配置为 root 运行（可能无法自动重启服务）"
    fi
fi

echo ""

# ============================================================================
# 5. 检查辅助脚本
# ============================================================================
echo -e "${BLUE}[5/9]${NC} 检查辅助脚本..."

for script in acme-add acme-list acme-revoke; do
    if [[ -x "/usr/local/bin/$script" ]]; then
        echo -e "  ${GREEN}✓${NC} $script 存在且可执行"
    else
        echo -e "  ${RED}✗${NC} $script 不存在或不可执行"
    fi
done

# 检查 acme-add 中的 xray 支持
if [[ -f "/usr/local/bin/acme-add" ]]; then
    if grep -q "systemctl restart xray" /usr/local/bin/acme-add 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} acme-add 包含 xray 重启逻辑"
    else
        echo -e "  ${YELLOW}!${NC} acme-add 不包含 xray 重启逻辑"
    fi
fi

echo ""

# ============================================================================
# 6. 检查 DNS 配置（如果存在）
# ============================================================================
echo -e "${BLUE}[6/9]${NC} 检查 DNS 配置..."

if [[ -f "/etc/acme/dns-config" ]]; then
    echo -e "  ${GREEN}✓${NC} DNS 配置文件存在"
    
    # 检查权限
    DNS_PERMS=$(stat -c "%a" /etc/acme/dns-config 2>/dev/null || stat -f "%Lp" /etc/acme/dns-config 2>/dev/null || echo "unknown")
    DNS_OWNER=$(stat -c "%U:%G" /etc/acme/dns-config 2>/dev/null || stat -f "%Su:%Sg" /etc/acme/dns-config 2>/dev/null || echo "unknown")
    echo -e "  ${BLUE}ℹ${NC} 权限: $DNS_PERMS ($DNS_OWNER)"
    
    if [[ "$DNS_PERMS" == "640" ]] && [[ "$DNS_OWNER" == "root:ssl-cert" ]]; then
        echo -e "  ${GREEN}✓${NC} DNS 配置权限正确"
    else
        echo -e "  ${YELLOW}!${NC} DNS 配置权限建议为 640 root:ssl-cert"
    fi
else
    echo -e "  ${YELLOW}!${NC} DNS 配置文件不存在（如使用 DNS 验证需要）"
fi

echo ""

# ============================================================================
# 7. 检查已安装证书
# ============================================================================
echo -e "${BLUE}[7/9]${NC} 检查已安装证书..."

if [[ -d "$ACME_HOME/home/.acme.sh" ]]; then
    CERT_COUNT=$(sudo -u "$ACME_USER" bash -c "cd $ACME_HOME/home && ./.acme.sh/acme.sh --list 2>/dev/null" | grep -c "Main_Domain" || echo "0")
    
    if [[ "$CERT_COUNT" -gt 0 ]]; then
        echo -e "  ${GREEN}✓${NC} 已安装 $CERT_COUNT 个证书"
        echo ""
        sudo -u "$ACME_USER" bash -c "cd $ACME_HOME/home && ./.acme.sh/acme.sh --list 2>/dev/null" | head -20
    else
        echo -e "  ${YELLOW}!${NC} 未安装任何证书"
    fi
else
    echo -e "  ${RED}✗${NC} 无法检查证书列表"
fi

echo ""

# ============================================================================
# 8. 检查证书 reload 命令
# ============================================================================
echo -e "${BLUE}[8/9]${NC} 检查证书 reload 命令..."

if [[ -d "$ACME_HOME/home/.acme.sh" ]]; then
    FOUND_CERTS=0
    for conf in "$ACME_HOME/home/.acme.sh"/*/*.conf; do
        [[ -f "$conf" ]] || continue
        FOUND_CERTS=1
        
        domain=$(basename "$(dirname "$conf")" | sed 's/_ecc$//')
        reload_cmd=$(grep "Le_ReloadCmd=" "$conf" 2>/dev/null | sed "s/.*__ACME_BASE64__START_//;s/__ACME_BASE64__END_.*//" | base64 -d 2>/dev/null || echo "未设置")
        
        echo -e "  ${BLUE}ℹ${NC} $domain: $reload_cmd"
    done
    
    if [[ $FOUND_CERTS -eq 0 ]]; then
        echo -e "  ${YELLOW}!${NC} 未找到任何证书配置"
    fi
else
    echo -e "  ${RED}✗${NC} 无法检查 reload 命令"
fi

echo ""

# ============================================================================
# 9. 检查服务状态
# ============================================================================
echo -e "${BLUE}[9/9]${NC} 检查相关服务状态..."

if systemctl is-active xray &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} xray 运行中"
elif systemctl list-units --all xray.service 2>/dev/null | grep -q xray; then
    echo -e "  ${YELLOW}!${NC} xray 已安装但未运行"
else
    echo -e "  ${BLUE}ℹ${NC} xray 未安装"
fi

if systemctl is-active nginx &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} nginx 运行中"
elif systemctl list-units --all nginx.service 2>/dev/null | grep -q nginx; then
    echo -e "  ${YELLOW}!${NC} nginx 已安装但未运行"
else
    echo -e "  ${BLUE}ℹ${NC} nginx 未安装"
fi

if systemctl is-active openresty &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} openresty 运行中"
elif systemctl list-units --all openresty.service 2>/dev/null | grep -q openresty; then
    echo -e "  ${YELLOW}!${NC} openresty 已安装但未运行"
else
    echo -e "  ${BLUE}ℹ${NC} openresty 未安装"
fi

echo ""

# ============================================================================
# 总结
# ============================================================================
echo -e "${BLUE}========================================"
echo -e "检查完成"
echo -e "========================================${NC}"
echo ""
echo -e "${BLUE}建议操作：${NC}"
echo -e "  - 如有 ${RED}✗${NC} 标记，请检查相应配置"
echo -e "  - 如有 ${YELLOW}!${NC} 标记，建议根据需要调整"
echo -e "  - 查看详细日志：journalctl -u acme-renew.service -n 50"
echo -e "  - 手动测试续期：sudo -u acme bash -c 'cd /var/lib/acme/home && ./.acme.sh/acme.sh --cron --home /var/lib/acme/home'"
echo ""
