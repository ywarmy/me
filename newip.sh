#!/bin/bash

# 旧IP和新IP的文件
OLD_IP_FILE="/root/singbox/old.txt"
NEW_IP_FILE="/root/singbox/new.txt"

# 文件目录
DIRECTORY="/root/singbox"

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

# 循环处理目录中的每个文件
for FILE in "$DIRECTORY"/*; do
  if [ -f "$FILE" ]; then
    for ((i=0; i<${#OLD_IPS[@]}; i++)); do
      sed -i "s/${OLD_IPS[i]}/${NEW_IPS[i]}/g" "$FILE"
    done
    echo "Processed $FILE"
  fi
done
