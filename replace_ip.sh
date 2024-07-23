#!/bin/sh

# 检查是否传入文件名参数
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <original_file> <new_ips_file>"
    exit 1
fi

original_file=$1
new_ips_file=$2
log_file="replace_ips.log"

# 开始日志记录
echo "[$(date)] 脚本开始运行" > $log_file
echo "原文件: $original_file" >> $log_file
echo "新IP文件: $new_ips_file" >> $log_file

# 提取原文件中的所有IP地址并排除0.0.0.0
echo "[$(date)] 提取原文件中的IP地址" >> $log_file
grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' "$original_file" | grep -v '0\.0\.0\.0' > original_ips.tmp
cat original_ips.tmp >> $log_file

# 读取新IP文件中的IP地址
echo "[$(date)] 读取新IP文件中的IP地址" >> $log_file
cat "$new_ips_file" | tr -d '\r' > new_ips.tmp  # 去除所有换行符
cat new_ips.tmp >> $log_file

# 确保新IP文件中的IP地址数量不少于原IP文件中的IP地址数量
original_ip_count=$(wc -l < original_ips.tmp)
new_ip_count=$(wc -l < new_ips.tmp)

if [ "$new_ip_count" -lt "$original_ip_count" ]; then
    echo "[$(date)] 错误: 新IP文件中的IP地址数量少于原文件中的IP地址数量" >> $log_file
    exit 1
fi

# 将新IP地址按顺序替换原文件中的IP地址
echo "[$(date)] 使用 awk 按顺序替换 IP 地址" >> $log_file
awk '
BEGIN {
    while ((getline < "new_ips.tmp") > 0) {
        new_ips[++i] = $0
    }
    close("new_ips.tmp")
}
FNR==NR {
    ips[FNR] = $0
    next
}
{
    for (j in ips) {
        if ($0 ~ ips[j]) {
            if (ip_index < length(new_ips)) {
                sub(/([0-9]{1,3}\.){3}[0-9]{1,3}/, new_ips[++ip_index])
            }
            break
        }
    }
    gsub(/\n+$/, "")  # 去除行尾多余的换行符
    print
}' original_ips.tmp "$original_file" > replaced_file.tmp

# 替换原文件内容
mv replaced_file.tmp "$original_file"

# 清理临时文件
rm original_ips.tmp new_ips.tmp

# 结束日志记录
echo "[$(date)] 脚本运行结束" >> $log_file
