# me
1. Mihomo 核心
安装 Mihomo
配置文件：/etc/mihomo/config.yaml
程序：/usr/local/bin/mihomo
systemd 服务：mihomo.service
开机自动启动
使用 systemd 管理 Mihomo
2. 代理端口
当前设计：
功能	端口	用途
混合代理	7890	给需要手动设置代理的客户端使用
TProxy	7893	透明代理核心端口
控制面板	9090	Mihomo 控制接口
DNS	53	Mihomo DNS
