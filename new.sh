#!/bin/bash

grep -E -o '([0-9]{1,3}[\.]){3}[0-9]{1,3}' /root/singbox/config.json | grep -Ev '0\.0\.0\.0' >"/root/singbox/old.txt"

# 检查是否提供了文件路径参数
if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <file_path>"
  exit 1
fi

FILE="$1"

# 旧IP和新IP的文件
OLD_IP_FILE="/root/singbox/old.txt"
NEW_IP_FILE="/root/singbox/new.txt"

# 检查文件是否存在
if [ ! -f "$OLD_IP_FILE" ] || [ ! -f "$NEW_IP_FILE" ]; then
  echo "Error: One or both IP files do not exist."
  exit 1
fi

# 读取IP地址到数组
OLD_IPS=($(<"$OLD_IP_FILE"))
NEW_IPS=($(<"$NEW_IP_FILE"))

# 检查数组长度是否相同
if [ ${#OLD_IPS[@]} -ne ${#NEW_IPS[@]} ]; then
  echo "Error: The number of old IPs and new IPs must be the same."
  exit 1
fi

# 检查目标文件是否存在
if [ ! -f "$FILE" ]; then
  echo "Error: The specified file does not exist."
  exit 1
fi

# 替换文件中的IP地址
for ((i=0; i<${#OLD_IPS[@]}; i++)); do
  sed -i "s/${OLD_IPS[i]}/${NEW_IPS[i]}/g" "$FILE"
done

echo "Processed $FILE"
