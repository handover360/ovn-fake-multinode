#!/bin/bash

# 사용법 안내 함수
usage() {
    echo "Usage: $0 <action: add|del> <start_num> <end_num>"
    echo "Example: $0 add 3 10  (ovn-chassis-3부터 10까지 추가)"
    echo "Example: $0 del 3 10  (ovn-chassis-3부터 10까지 삭제)"
    exit 1
}

# 인자 개수 확인
if [ "$#" -ne 3 ]; then
    usage
fi

ACTION=$1
START=$2
END=$3

# 시작 번호가 끝 번호보다 큰지 확인
if [ "$START" -gt "$END" ]; then
    echo "Error: Start number ($START) cannot be greater than end number ($END)."
    exit 1
fi

# 메인 루프
for i in $(seq "$START" "$END"); do
    CHASSIS_NAME="ovn-chassis-$i"

    if [ "$ACTION" == "add" ]; then
        echo "--------------------------------------------------"
        echo "Adding $CHASSIS_NAME..."
        ./ovn_cluster.sh add-chassis "$CHASSIS_NAME"
        
    elif [ "$ACTION" == "del" ]; then
        echo "--------------------------------------------------"
        echo "Stopping $CHASSIS_NAME..."
        ./ovn_cluster.sh stop-chassis "$CHASSIS_NAME"
        
    else
        echo "Invalid action: $ACTION"
        usage
    fi
done

echo "--------------------------------------------------"
echo "Action '$ACTION' completed for range $START to $END."
