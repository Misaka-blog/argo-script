#!/bin/bash

export LANG=en_US.UTF-8

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

red(){
    echo -e "\033[31m\033[01m$1\033[0m"
}
green(){
    echo -e "\033[32m\033[01m$1\033[0m"
}
yellow(){
    echo -e "\033[33m\033[01m$1\033[0m"
}

REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "alpine")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Alpine")
PACKAGE_UPDATE=("apt -y update" "apt -y update" "yum -y update" "yum -y update")
PACKAGE_INSTALL=("apt -y install" "apt -y install" "yum -y install" "yum -y install" "apk add -f")
PACKAGE_REMOVE=("apt -y remove" "apt -y remove" "yum -y remove" "yum -y remove")

[[ $EUID -ne 0 ]] && yellow "请在root用户下运行脚本" && exit 1

CMD=("$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)" "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)" "$(lsb_release -sd 2>/dev/null)" "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)" "$(grep . /etc/redhat-release 2>/dev/null)" "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')")

for i in "${CMD[@]}"; do
    SYS="$i" && [[ -n $SYS ]] && break
done

for ((int = 0; int < ${#REGEX[@]}; int++)); do
    [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]] && SYSTEM="${RELEASE[int]}" && [[ -n $SYSTEM ]] && break
done

[[ -z $SYSTEM ]] && red "不支持当前VPS的操作系统，请使用主流的操作系统" && exit 1
if [[ -z $(type -P curl) ]]; then
    if [[ ! $SYSTEM == "CentOS" ]]; then
        ${PACKAGE_UPDATE[int]}
    fi
    ${PACKAGE_INSTALL[int]} curl
fi

archAffix() {
    case "$(uname -m)" in
        i686 | i386) echo '386' ;;
        x86_64 | amd64) echo 'amd64' ;;
        armv5tel | arm6l | armv7 | armv7l) echo 'arm' ;;
        armv8 | arm64 | aarch64) echo 'aarch64' ;;
        *) red "不支持的CPU架构！" && exit 1 ;;
    esac
}

back2menu() {
    yellow "所选操作执行完成"
    read -rp "请输入“y”退出，或按任意键返回主菜单：" back2menuInput
    case "$back2menuInput" in
        y) exit 1 ;;
        *) menu ;;
    esac
}

checkStatus() {
    [[ -z $(cloudflared -help 2>/dev/null) ]] && cloudflaredStatus="未安装"
    [[ -n $(cloudflared -help 2>/dev/null) ]] && cloudflaredStatus="已安装"
    [[ -f /root/.cloudflared/cert.pem ]] && loginStatus="已登录"
    [[ ! -f /root/.cloudflared/cert.pem ]] && loginStatus="未登录"
}

installCloudFlared() {
    [[ $cloudflaredStatus == "已安装" ]] && red "检测到已安装并登录CloudFlare Argo Tunnel，无需重复安装！！" && exit 1
    last_version=$(curl -Ls "https://api.github.com/repos/cloudflare/cloudflared/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    wget -N --no-check-certificate https://github.com/cloudflare/cloudflared/releases/download/$last_version/cloudflared-linux-$(archAffix) -O /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared
}

loginCloudFlared(){
    [[ $loginStatus == "已登录" ]] && red "检测到已登录CloudFlare Argo Tunnel，无需重复登录！！" && exit 1
    cloudflared tunnel login
    checkStatus
    if [[ $cloudflaredStatus == "未登录" ]]; then
        red "登录CloudFlare Argo Tunnel账户失败！！"
        back2menu
    else
        green "登录CloudFlare Argo Tunnel账户成功！！"
        back2menu
    fi
}

uninstallCloudFlared() {
    [[ $cloudflaredStatus == "未安装" ]] && red "检测到未安装CloudFlare Argo Tunnel客户端，无法执行操作！！！" && exit 1
    rm -f /usr/local/bin/cloudflared
    rm -rf /root/.cloudflared
    yellow "CloudFlared 客户端已卸载成功"
}

listTunnel() {
    [[ $cloudflaredStatus == "未安装" ]] && red "检测到未安装CloudFlare Argo Tunnel客户端，无法执行操作！！！" && exit 1
    [[ $loginStatus == "未登录" ]] && red "请登录CloudFlare Argo Tunnel客户端后再执行操作！！！" && exit 1
    cloudflared tunnel list
    back2menu
}

makeTunnel() {
    read -rp "请设置隧道名称：" tunnelName
    cloudflared tunnel create $tunnelName
    read -rp "请设置隧道域名：" tunnelDomain
    cloudflared tunnel route dns $tunnelName $tunnelDomain
    cloudflared tunnel list
    # 感谢yuuki410在其分支中提取隧道UUID的代码
    # Source: https://github.com/yuuki410/argo-tunnel-script
    tunnelUUID=$( $(cloudflared tunnel list | grep $tunnelName) = /[0-9a-f\-]+/)
    read -p "请输入隧道UUID（复制ID里面的内容）：" tunnelUUID
    read -p "输入传输协议（默认http）：" tunnelProtocol
    [[ -z $tunnelProtocol ]] && tunnelProtocol="http"
    read -p "输入反代端口（默认80）：" tunnelPort
    [[ -z $tunnelPort ]] && tunnelPort=80
    read -p "输入保存的配置文件名 [默认随机文件名]：" tunnelFileName
    [[ -z $tunnelFileName ]] && tunnelFileName = $(openssl rand -hex 16)
	cat <<EOF > /root/$tunnelFileName.yml
tunnel: $tunnelName
credentials-file: /root/.cloudflared/$tunnelUUID.json
originRequest:
  connectTimeout: 30s
  noTLSVerify: true
ingress:
  - hostname: $tunnelDomain
    service: $tunnelProtocol://localhost:$tunnelPort
  - service: http_status:404
EOF
    green "配置文件已保存至 /root/$tunnelFileName.yml"
    back2menu
}

runTunnel() {
    [[ $cloudflaredStatus == "未安装" ]] && red "检测到未安装CloudFlare Argo Tunnel客户端，无法执行操作！！！" && exit 1
    [[ $loginStatus == "未登录" ]] && red "请登录CloudFlare Argo Tunnel客户端后再执行操作！！！" && exit 1
    [[ -z $(type -P screen) ]] && ${PACKAGE_UPDATE[int]} && ${PACKAGE_INSTALL[int]} screen
    read -rp "请复制粘贴配置文件的位置（例：/root/tunnel.yml）：" ymlLocation
    read -rp "请输入创建Screen会话的名字：" screenName
    screen -USdm $screenName cloudflared tunnel --config $ymlLocation run
    green "隧道已运行成功，请等待1-3分钟启动并解析完毕"
    back2menu
}

killTunnel() {
    [[ $cloudflaredStatus == "未安装" ]] && red "检测到未安装CloudFlare Argo Tunnel客户端，无法执行操作！！！" && exit 1
    [[ $loginStatus == "未登录" ]] && red "请登录CloudFlare Argo Tunnel客户端后再执行操作！！！" && exit 1
    [[ -z $(type -P screen) ]] && ${PACKAGE_UPDATE[int]} && ${PACKAGE_INSTALL[int]} screen
    read -rp "请输入需要删除的Screen会话名字：" screenName
    screen -S $screenName -X quit
    green "Screen会话停止成功！"
    back2menu
}

deleteTunnel() {
    [[ $cloudflaredStatus == "未安装" ]] && red "检测到未安装CloudFlare Argo Tunnel客户端，无法执行操作！！！" && exit 1
    [[ $loginStatus == "未登录" ]] && red "请登录CloudFlare Argo Tunnel客户端后再执行操作！！！" && exit 1
    read -rp "请输入需要删除的隧道名称：" tunnelName
    cloudflared tunnel delete $tunnelName
    back2menu
}

argoCert() {
    [[ $cloudflaredStatus == "未安装" ]] && red "检测到未安装CloudFlare Argo Tunnel客户端，无法执行操作！！！" && exit 1
    [[ $loginStatus == "未登录" ]] && red "请登录CloudFlare Argo Tunnel客户端后再执行操作！！！" && exit 1
    sed -n "1, 5p" /root/.cloudflared/cert.pem >>/root/private.key
    sed -n "6, 24p" /root/.cloudflared/cert.pem >>/root/cert.crt
    green "CloudFlare Argo Tunnel证书提取成功！"
    yellow "证书crt路径如下：/root/cert.crt"
    yellow "私钥key路径如下：/root/private.key"
    green "使用证书提示："
    yellow "1. 当前证书仅限于CF Argo Tunnel隧道授权过的域名使用"
    yellow "2. 在需要使用证书的服务使用Argo Tunnel的域名，必须使用其证书"
    back2menu
}

menu() {
    checkStatus
    clear
    echo "#############################################################"
    echo -e "#           ${RED}CloudFlare Argo Tunnel 一键管理脚本${PLAIN}             #"
    echo -e "# ${GREEN}作者${PLAIN}: MisakaNo の 小破站                                  #"
    echo -e "# ${GREEN}博客${PLAIN}: https://blog.misaka.rest                            #"
    echo -e "# ${GREEN}GitHub 项目${PLAIN}: https://github.com/blog-misaka               #"
    echo -e "# ${GREEN}GitLab 项目${PLAIN}: https://gitlab.com/misakablog                #"
    echo -e "# ${GREEN}Telegram 频道${PLAIN}: https://t.me/misakablogchannel             #"
    echo -e "# ${GREEN}Telegram 群组${PLAIN}: https://t.me/+CLhpemKhaC8wZGIx             #"
    echo -e "# ${GREEN}YouTube 频道${PLAIN}: https://www.youtube.com/@misaka-blog        #"
    echo "#############################################################"
    echo ""
    echo -e " ${GREEN}1.${PLAIN} 安装 CloudFlare Argo Tunnel"
    echo -e " ${GREEN}2.${PLAIN} 登录 CloudFlare Argo Tunnel"
    echo -e " ${GREEN}3.${PLAIN} ${RED}卸载 CloudFlare Argo Tunnel${PLAIN}"
    echo " -------------"
    echo -e " ${GREEN}4.${PLAIN} 查看账户内 Argo Tunnel 隧道列表"
    echo " -------------"
    echo -e " ${GREEN}5.${PLAIN} 创建 Argo Tunnel 隧道"
    echo -e " ${GREEN}6.${PLAIN} 运行 Argo Tunnel 隧道"
    echo -e " ${GREEN}7.${PLAIN} 停止 Argo Tunnel 隧道"
    echo -e " ${GREEN}8.${PLAIN} ${RED}删除 Argo Tunnel 隧道${PLAIN}"
    echo " -------------"
    echo -e " ${GREEN}9.${PLAIN} 提取 Argo Tunnel 证书"
    echo -e " ${GREEN}0.${PLAIN} 退出脚本"
    echo ""
    echo -e "CloudFlared 客户端状态：$cloudflaredStatus   账户登录状态：$loginStatus"
    echo ""
    read -rp "请输入选项 [0-9]: " menuChoice
    case $menuChoice in
        1) installCloudFlared ;;
        2) loginCloudFlared ;;
        3) uninstallCloudFlared ;;
        4) listTunnel ;;
        5) makeTunnel ;;
        6) runTunnel ;;
        7) killTunnel ;;
        8) deleteTunnel ;;
        9) argoCert ;;
        *) red "请输入正确的选项！" && exit 1 ;;
    esac
}

archAffix
menu
