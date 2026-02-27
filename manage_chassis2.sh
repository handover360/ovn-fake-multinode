#!/bin/bash

usage() {
    echo "Usage: $0 <action: add|del> <start_num> <end_num>"
    exit 1
}

if [ "$#" -ne 3 ]; then usage; fi

ACTION=$1
START=$2
END=$3
LOG_FILE="chassis_test.csv"

# 파일이 없으면 헤더 생성
if [ ! -f "$LOG_FILE" ]; then
    echo "timestamp,target_index,nb_leader,sb_leader,active_northd,c1_cpu,c1_mem,c1_disk,c2_cpu,c2_mem,c2_disk,c3_cpu,c3_mem,c3_disk" > "$LOG_FILE"
fi

collect_stats_csv() {
    local target_idx=$1
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    local nb_leader=0
    local sb_leader=0
    local active_northd=0

    # 1. Leader/Active 인덱스 추출
    for i in {1..3}; do
        local node="ovn-central-az1-$i"
        # Role이 leader인 노드 번호 찾기
        if podman exec $node ovs-appctl -t /var/run/ovn/ovnnb_db.ctl cluster/status OVN_Northbound 2>/dev/null | grep -q "Role: leader"; then nb_leader=$i; fi
        if podman exec $node ovs-appctl -t /var/run/ovn/ovnsb_db.ctl cluster/status OVN_Southbound 2>/dev/null | grep -q "Role: leader"; then sb_leader=$i; fi
        # Northd status가 active인 노드 번호 찾기
        if podman exec $node ovn-appctl -t ovn-northd status 2>/dev/null | grep -q "Status: active"; then active_northd=$i; fi
    done

    # 2. 자원 사용량 추출 (단위 제거 및 숫자만 추출)
    local stats_raw=$(podman stats --no-stream --format "{{.CPUPerc}},{{.MemUsage}}" ovn-central-az1-1 ovn-central-az1-2 ovn-central-az1-3)
    
    # 각 노드별 데이터 파싱 (%, MB 등 문자 제거)
    local c1_cpu=$(echo "$stats_raw" | sed -n '1p' | cut -d',' -f1 | tr -d '% ')
    local c1_mem=$(echo "$stats_raw" | sed -n '1p' | cut -d',' -f2 | awk '{print $1}' | sed 's/MB//;s/GB//;s/KB//')
    
    local c2_cpu=$(echo "$stats_raw" | sed -n '2p' | cut -d',' -f1 | tr -d '% ')
    local c2_mem=$(echo "$stats_raw" | sed -n '2p' | cut -d',' -f2 | awk '{print $1}' | sed 's/MB//;s/GB//;s/KB//')
    
    local c3_cpu=$(echo "$stats_raw" | sed -n '3p' | cut -d',' -f1 | tr -d '% ')
    local c3_mem=$(echo "$stats_raw" | sed -n '3p' | cut -d',' -f2 | awk '{print $1}' | sed 's/MB//;s/GB//;s/KB//')

    # 3. 디스크 사용량 (숫자만 추출)
    local c1_disk=$(podman exec ovn-central-az1-1 df -m /etc/openvswitch | tail -1 | awk '{print $3}') # 사용 중인 용량(MB) 기준
    local c2_disk=$(podman exec ovn-central-az1-2 df -m /etc/openvswitch | tail -1 | awk '{print $3}')
    local c3_disk=$(podman exec ovn-central-az1-3 df -m /etc/openvswitch | tail -1 | awk '{print $3}')

    # CSV 한 줄 생성
    local csv_row="$timestamp,$target_idx,$nb_leader,$sb_leader,$active_northd,$c1_cpu,$c1_mem,$c1_disk,$c2_cpu,$c2_mem,$c2_disk,$c3_cpu,$c3_mem,$c3_disk"
    
    echo "$csv_row" | tee -a "$LOG_FILE"
}

# 메인 루프
echo "Starting Action: $ACTION from $START to $END. Logging to $LOG_FILE"

for i in $(seq "$START" "$END"); do
    CHASSIS_NAME="ovn-chassis-$i"

    if [ "$ACTION" == "add" ]; then
        ./ovn_cluster.sh add-chassis "$CHASSIS_NAME" > /dev/null
    elif [ "$ACTION" == "del" ]; then
        ./ovn_cluster.sh stop-chassis "$CHASSIS_NAME" > /dev/null
    fi

    # 통계 수집 및 출력
    collect_stats_csv "$i"
    sleep 1
done
