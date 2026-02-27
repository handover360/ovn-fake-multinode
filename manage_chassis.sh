#!/bin/bash

# 사용법 안내
usage() {
    echo "Usage: $0 <action: add|del> <start_num> <end_num>"
    echo "Example: $0 add 3 10"
    exit 1
}

if [ "$#" -ne 3 ]; then usage; fi

ACTION=$1
START=$2
END=$3
LOG_FILE="chassis_test.log"

# 화면과 파일에 동시에 기록하는 함수
log_msg() {
    local msg="$1"
    echo -e "$msg" | tee -a "$LOG_FILE"
}

# 상태 및 자원 수집 함수
collect_stats() {
    log_msg "\n--- [Status Check: $(date '+%Y-%m-%d %H:%M:%S')] ---"
    
    # 1. DB Leader 및 Northd Active 체크
    log_msg "[Leader/Active Status]"
    for i in {1..3}; do
        local node="ovn-central-az1-$i"
        
        # NB/SB Leader 확인 (명령어 결과에서 'leader' 문자열 포함 여부 체크)
        local nb_role=$(podman exec $node ovs-appctl -t /var/run/ovn/ovnnb_db.ctl cluster/status OVN_Northbound | grep "Role:" | awk '{print $2}')
        local sb_role=$(podman exec $node ovs-appctl -t /var/run/ovn/ovnsb_db.ctl cluster/status OVN_Southbound | grep "Role:" | awk '{print $2}')
        
        # Northd Active 확인 (ovn-northd 로그나 status 확인 - 환경에 따라 다를 수 있으나 보통 status 명령어로 확인)
        local northd_status=$(podman exec $node ovn-appctl -t ovn-northd status 2>/dev/null | grep "Status:" | awk '{print $2}')
        [ -z "$northd_status" ] && northd_status="standby/unknown"

        log_msg "  Node $node: NB=$nb_role, SB=$sb_role, Northd=$northd_status"
    done

    # 2. Central 컨테이너 자원 사용량 (CPU, MEM, DISK)
    log_msg "[Resource Usage]"
    # podman stats를 사용하여 CPU/MEM 수집
    log_msg "  $(podman stats --no-stream --format "NAME: {{.Name}} | CPU: {{.CPUPerc}} | MEM: {{.MemUsage}}" ovn-central-az1-1 ovn-central-az1-2 ovn-central-az1-3)"
    
    # Disk 사용량 (컨테이너 내부 DB 저장 경로 /var/lib/ovn 또는 /etc/ovn 기준)
    for i in {1..3}; do
        local node="ovn-central-az1-$i"
        local disk_usage=$(podman exec $node df -h /etc/openvswitch | tail -1 | awk '{print $5}')
        log_msg "  Node $node Disk(/etc/ovs): $disk_usage"
    done
}

# 메인 루프
log_msg "\n=================================================="
log_msg "Starting Action: $ACTION from $START to $END"
log_msg "=================================================="

for i in $(seq "$START" "$END"); do
    CHASSIS_NAME="ovn-chassis-$i"

    if [ "$ACTION" == "add" ]; then
        log_msg "\n>>> Adding $CHASSIS_NAME..."
        ./ovn_cluster.sh add-chassis "$CHASSIS_NAME"
    elif [ "$ACTION" == "del" ]; then
        log_msg "\n>>> Stopping $CHASSIS_NAME..."
        ./ovn_cluster.sh stop-chassis "$CHASSIS_NAME"
    fi

    # 작업 직후 상태 수집 호출
    collect_stats
    
    # 시스템 안정화를 위한 짧은 대기
    sleep 1
done

log_msg "\n=================================================="
log_msg "Action '$ACTION' completed."
log_msg "=================================================="
