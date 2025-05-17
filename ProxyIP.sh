#!/bin/bash
export LANG=en_US.UTF-8

# 定义颜色
re='\e[0m'
red='\e[1;91m'
white='\e[1;97m'
green='\e[1;32m'
yellow='\e[1;33m'
purple='\e[1;35m'
skyblue='\e[1;96m'

# 默认 Cloudflare 目标 IP
CF_IP="104.18.37.228"

# 检查是否有参数以启用无交互模式并作为端口号
NON_INTERACTIVE=0
PORT_PARAM=""
if [ -n "$1" ]; then
    NON_INTERACTIVE=1
    PORT_PARAM="$1"
fi

# 等待用户返回
break_end() {
    echo -e "${green}执行完成${re}"
    echo -e "${yellow}按任意键返回...${re}"
    read -n 1 -s -r -p ""
    echo ""
    clear
}

# 安装依赖包
install() {
    for package in "$@"; do
        if ! command -v "$package" &>/dev/null; then
            echo -e "${yellow}正在安装 ${package}...${re}"
            if command -v apt &>/dev/null; then
                sudo apt install -y "$package"
            elif command -v yum &>/dev/null; then
                sudo yum install -y "$package"
            elif command -v dnf &>/dev/null; then
                sudo dnf install -y "$package"
            else
                echo -e "${red}不支持的包管理器！${re}"
                return 1
            fi
        fi
    done
}

# 清除 iptables NAT 规则
del_iptables() {
    sudo iptables -t nat -F
    echo -e "${green}已清除所有 iptables NAT 规则${re}"
}

# 开启流量转发
start_forwarding() {
    local non_interactive=${1:-0}
    local local_port

    # 安装依赖
    install iptables curl

    # 启用 IPv4 转发
    if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
        sudo sysctl -p
        echo -e "${green}IPv4 流量转发已开启${re}"
    fi

    # 设置监听端口
    if [ $non_interactive -eq 1 ]; then
        local_port=$PORT_PARAM
    else
        read -p "请输入本地监听端口（默认 443）: " local_port
        local_port=${local_port:-443}
    fi

    # 检查端口占用
    if ss -tuln | grep -q ":${local_port} "; then
        echo -e "${red}错误：端口 ${local_port} 已被占用！${re}"
        return 1
    fi

    # 添加 iptables 规则
    echo -e "${yellow}正在添加转发规则：${re}"
    echo -e "本地端口 ${green}${local_port}${re} → Cloudflare IP ${green}${CF_IP}:443${re}"
    sudo iptables -t nat -A PREROUTING -p tcp --dport $local_port -j DNAT --to-destination $CF_IP:443
    sudo iptables -t nat -A POSTROUTING -j MASQUERADE

    # 保存规则
    sudo mkdir -p /etc/iptables
    sudo iptables-save | sudo tee /etc/iptables/rules.v4 >/dev/null
    echo -e "${green}规则已保存到 /etc/iptables/rules.v4${re}"

    # 设置开机加载
    if [ ! -f /etc/rc.local ]; then
        echo '#!/bin/bash
iptables-restore < /etc/iptables/rules.v4
exit 0' | sudo tee /etc/rc.local
        sudo chmod +x /etc/rc.local
    fi
}

######################### 主菜单 ##############################
clear
echo -e "${yellow} ____  _               _   ___ _               ${re}"
echo -e "${yellow}/ ___|| |_ __ _ _ __ | |_|_ _| | _____ _ __   ${re}"
echo -e "${yellow}\___ \| __/ _\` | '_ \| __|| || |/ / _ \ '__|  ${re}"
echo -e "${yellow} ___) | || (_| | | | | |_ | ||   <  __/ |     ${re}"
echo -e "${yellow}|____/ \__\__,_|_| |_|\__|___|_|\_\___|_|     ${re}"
echo "------------------------------------------------------"
echo -e " 目标 Cloudflare IP: ${green}${CF_IP}${re}"
echo "------------------------------------------------------"
echo -e " 1. ${green}开启 IPv4 流量转发到 Cloudflare${re}"
echo -e " 2. ${red}清除所有 iptables 规则${re}"
echo -e " 3. 查看当前 iptables 规则"
echo "------------------------------------------------------"
echo -e " 0. 退出脚本"
echo "------------------------------------------------------"
read -p "请输入选项 [0-3]: " choice

case $choice in
    1)
        echo -e "${purple}警告：这将修改服务器网络配置！${re}"
        read -p "确定继续吗？[y/N] " confirm
        if [[ $confirm =~ [yY] ]]; then
            start_forwarding 0
        fi
        ;;
    2)
        del_iptables
        ;;
    3)
        sudo iptables -t nat -L -v --line-numbers
        ;;
    0)
        exit 0
        ;;
    *)
        echo -e "${red}无效选项！${re}"
        ;;
esac

break_end
