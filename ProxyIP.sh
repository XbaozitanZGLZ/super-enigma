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

# 检查是否有参数以启用无交互模式并作为端口号
NON_INTERACTIVE=0
PORT_PARAM=""
if [ -n "$1" ]; then
    NON_INTERACTIVE=1
    PORT_PARAM="$1"
fi

# Cloudflare IPv4地址段
cf_ipv4_ranges=(
    "103.21.244.0/22"
    "103.22.200.0/22"
    "103.31.4.0/22"
    "104.16.0.0/13"
    "104.24.0.0/14"
    "108.162.192.0/18"
    "131.0.72.0/22"
    "141.101.64.0/18"
    "162.158.0.0/15"
    "172.64.0.0/13"
    "173.245.48.0/20"
    "188.114.96.0/20"
    "190.93.240.0/20"
    "197.234.240.0/22"
    "198.41.128.0/17"
)

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
    if [ $# -eq 0 ]; then
        echo -e "${red}未提供软件包参数!${re}"
        return 1
    fi

    for package in "$@"; do
        if command -v "$package" &>/dev/null; then
            echo -e "${green}${package}已经安装了！${re}"
            continue
        fi
        echo -e "${yellow}正在安装 ${package}...${re}"
        
        if [ "$package" == "dig" ]; then
            if command -v apt &>/dev/null; then
                package="dnsutils"
            elif command -v dnf &>/dev/null; then
                package="bind-utils"
            elif command -v yum &>/dev/null; then
                package="bind-utils"
            elif command -v apk &>/dev/null; then
                package="bind-tools"
            fi
        fi

        if command -v apt &>/dev/null; then
            apt install -y "$package"
        elif command -v dnf &>/dev/null; then
            dnf install -y "$package"
        elif command -v yum &>/dev/null; then
            yum install -y "$package"
        elif command -v apk &>/dev/null; then
            apk add "$package"
        else
            echo -e"${red}暂不支持你的系统!${re}"
            return 1
        fi
    done

    return 0
}

get_cf_ipv4() {
    # 随机选择一个Cloudflare IP
    random_ipv4=$(shuf -e \
        103.21.244.1 \
        104.16.0.1 \
        172.64.0.1 \
        198.41.128.1 \
        -n 1)
    echo "$random_ipv4"
}

del_iptables() {
    # 清除现有的NAT规则
    sudo iptables -t nat -F
    echo "已清除所有iptables NAT规则"
}

start_ipv4_forwarding() {
    local non_interactive=${1:-0}
    
    if [ $non_interactive -eq 1 ]; then
        echo -e "自动安装依赖包..."
        install sudo iptables
    else
        echo -e "脚本所需依赖包 ${yellow}sudo,iptables ${re}"
        read -p "是否允许脚本自动安装以上所需的依赖包(Y): " install_apps
        install_apps=${install_apps^^} # 转换为大写
        if [ "$install_apps" == "Y" ]; then
            install sudo iptables
        fi
    fi

    echo "检查IPv4的流量转发功能"
    if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
        echo "IPv4的流量转发 成功添加"
    fi

    # 应用配置
    sudo sysctl -p
    echo "IPv4的流量转发 已开启"

    # 获取随机Cloudflare IP
    cf_ip=$(get_cf_ipv4)
    echo -e "随机选择的Cloudflare IPv4地址: ${yellow}${cf_ip}${re}"

    del_iptables

    if [ $non_interactive -eq 1 ]; then
        local_port=$PORT_PARAM
    else
        read -p $'请输入你的本地监听端口（默认 443）' local_port
        local_port=${local_port:-443}
    fi
    
    if ss -tuln | grep -q ":${local_port} "; then
        echo -e "${local_port}端口已被占用，退出脚本。请自行检查${local_port}端口占用问题"
        exit 1
    fi

    # 验证端口号是否有效
    if ! [[ "$local_port" =~ ^[0-9]+$ ]] || [ "$local_port" -lt 1 ] || [ "$local_port" -gt 65535 ]; then
        echo -e "${red}错误: 无效的端口号! 端口必须是1-65535之间的数字。${re}"
        return 1
    fi
    
    echo -e "添加 ${yellow}${cf_ip}${re} 的PREROUTING链中的${local_port}端口转发规则"
    sudo iptables -t nat -A PREROUTING -p tcp --dport $local_port -j DNAT --to-destination $cf_ip:443

    # 启用MASQUERADE
    sudo iptables -t nat -A POSTROUTING -j MASQUERADE

    echo "保存iptables规则"
    # 确保目录存在
    if [ ! -d "/etc/iptables" ]; then
        echo "创建 /etc/iptables 目录"
        sudo mkdir -p /etc/iptables
    fi
    
    # 保存规则
    sudo iptables-save | sudo tee /etc/iptables/rules.v4 >/dev/null
    echo "规则已保存到 /etc/iptables/rules.v4"

    # 配置自动加载规则
    if [ -f "/etc/network/if-pre-up.d/iptables" ]; then
        echo "iptables恢复脚本已存在"
    else
        echo "#!/bin/sh
/sbin/iptables-restore < /etc/iptables/rules.v4" | sudo tee /etc/network/if-pre-up.d/iptables >/dev/null
        sudo chmod +x /etc/network/if-pre-up.d/iptables
        echo "已创建iptables恢复脚本"
    fi
}

#########################主菜单##############################

if [ $NON_INTERACTIVE -eq 1 ]; then
    echo "检测到无交互参数 ${PORT_PARAM}，自动开启Cloudflare IPv4转发..."
    echo "你是否明白你当前的操作意味着什么？"
    echo -e "${purple}这个操作将会把你的服务器配置为Cloudflare流量转发节点${re}"
    start_ipv4_forwarding 1
    echo -e "开启IPv4转发成功，端口:${yellow}${PORT_PARAM}${re}"
    exit 0
fi

while true; do
clear
echo -e "${yellow} ____                      ___ ____         __   ${re}"
echo -e "${yellow}|  _ \\ _ __ _____  ___   _|_ _|  _ \\__   __/ /_  ${re}"
echo -e "${yellow}| |_) | '__/ _ \\ \\/ / | | || || |_) \\ \\ / / '_ \\ ${re}"
echo -e "${yellow}|  __/| | | (_) >  <| |_| || ||  __/ \\ V /| (_) |${re}"
echo -e "${yellow}|_|   |_|  \\___/_/\\_\\\\__,  |___|_|     \\_/  \\___/ ${re}"
echo -e " 作者: cmliu         ${yellow}|___/${re} TG交流群: t.me/CMLiussss"    
echo "-------------------------------------------------------------------"
echo -e " 1. ${green}开启 Cloudflare IPv4 流量转发 ${re}"
echo -e " 2. ${purple}清除所有iptables NAT规则 ${re}"
echo "-------------------------------------------------------------------"
echo -e " 3. 查看 iptables 所有规则信息"
echo -e " 4. 清空 iptables 所有规则信息"
echo "-------------------------------------------------------------------"
echo -e "\033[0;97m 0. 退出脚本" 
echo "-------------------------------------------------------------------"
read -p $'\033[1;91m请输入你的选择: \033[0m' choice

case $choice in
  1)
    clear
    echo "你是否明白你当前的操作意味着什么？"
    echo -e "${purple}这个操作将会把你的服务器配置为Cloudflare流量转发节点${re}"
    read -p "你确定你要自行承担这个风险了吗？（Y/N 默认N）" confirm
    confirm=${confirm^^} # 转换为大写
    if [ "$confirm" == "Y" ]; then
        start_ipv4_forwarding 0
    fi
    ;;

  2)
    del_iptables
    ;;

  3)
    sudo iptables -t nat -L -v -n
    ;;

  4)
    read -p "这将清空所有iptables NAT规则，你确定要执行吗（Y/N 默认N）" confirm
    confirm=${confirm^^} # 转换为大写
    if [ "$confirm" == "Y" ]; then
        sudo iptables -t nat -F
    fi
    ;;

  0)
    clear
    exit
    ;;

  *)
    read -p "无效的输入!"
    ;;
esac
    break_end
done
