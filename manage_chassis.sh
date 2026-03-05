#!/bin/bash

# 사용법 안내 함수
usage() {
    echo "Usage: $0 <action: add|del> <start_num> <end_num>"
    echo "Example: $0 add 3 10"
    exit 1
}

# 인자 개수 확인
if [ "$#" -ne 3 ]; then
    usage
fi

ACTION=$1
START=$2
END=$3
LOG_FILE="chassis_test_detailed.csv"

# 1. CSV 헤더 생성 (파일이 없을 경우에만)
if [ ! -f "$LOG_FILE" ]; then
    HEADER="timestamp,target_index,nb_leader,sb_leader,active_northd"
    for i in {1..3}; do
        # cN_nb_sz: NB DB 파일 크기(MB), cN_sb_sz: SB DB 파일 크기(MB)
        HEADER+=",c${i}_cpu,c${i}_mem,c${i}_nb_sz,c${i}_sb_sz,c${i}_nb_cpu,c${i}_nb_mem,c${i}_sb_cpu,c${i}_sb_mem,c${i}_nr_cpu,c${i}_nr_mem"
    done
    echo "$HEADER" > "$LOG_FILE"
fi

# 2. 통계 수집 함수
collect_stats_csv() {
    local target_idx=$1
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local nb_leader=0
    local sb_leader=0
    local active_northd=0

    # A. Leader 및 Active 노드 인덱스 확인
    for i in {1..3}; do
        local node="ovn-central-az1-$i"
        if podman exec $node ovs-appctl -t /var/run/ovn/ovnnb_db.ctl cluster/status OVN_Northbound 2>/dev/null | grep -q "Role: leader"; then nb_leader=$i; fi
        if podman exec $node ovs-appctl -t /var/run/ovn/ovnsb_db.ctl cluster/status OVN_Southbound 2>/dev/null | grep -q "Role: leader"; then sb_leader=$i; fi
        if podman exec $node ovn-appctl -t ovn-northd status 2>/dev/null | grep -q "Status: active"; then active_northd=$i; fi
    done

    local row="$timestamp,$target_idx,$nb_leader,$sb_leader,$active_northd"

    # B. 각 Central 노드별 자원 상세 수집
    for i in {1..3}; do
        local node="ovn-central-az1-$i"
        
        # 전체 컨테이너 통계 (CPU %, MEM MB)
        local c_stats=$(podman stats --no-stream --format "{{.CPUPerc}},{{.MemUsage}}" $node)
        local c_cpu=$(echo "$c_stats" | cut -d',' -f1 | tr -d '% ')
        local c_mem=$(echo "$c_stats" | cut -d',' -f2 | awk '{print $1}' | sed 's/MB//;s/GB//;s/KB//')

        # [수정] 지정하신 경로에서 DB 파일 사이즈 조회 (MB 단위, 파일 부재 시 0)
        local nb_sz=$(podman exec $node du -m /etc/ovn/ovnnb_db.db 2>/dev/null | awk '{print $1}')
        local sb_sz=$(podman exec $node du -m /etc/ovn/ovnsb_db.db 2>/dev/null | awk '{print $1}')
        
        [ -z "$nb_sz" ] && nb_sz=0
        [ -z "$sb_sz" ] && sb_sz=0

        # 프로세스별 상세 통계 (CPU %, RSS MB)
        # NB DB
        local nb_stats=$(podman exec $node ps -aux | grep ovnnb_db | grep -v grep | awk '{cpu+=$3; mem+=$6} END {if(NR>0) printf "%.2f,%.2f", cpu, mem/1024; else printf "0,0"}')
        # SB DB
        local sb_stats=$(podman exec $node ps -aux | grep ovnsb_db | grep -v grep | awk '{cpu+=$3; mem+=$6} END {if(NR>0) printf "%.2f,%.2f", cpu, mem/1024; else printf "0,0"}')
        # Northd
        local nr_stats=$(podman exec $node ps -aux | grep ovn-northd | grep -v grep | awk '{cpu+=$3; mem+=$6} END {if(NR>0) printf "%.2f,%.2f", cpu, mem/1024; else printf "0,0"}')

        row+=",$c_cpu,$c_mem,$nb_sz,$sb_sz,$nb_stats,$sb_stats,$nr_stats"
    done

    # 결과 기록 및 화면 출력
    echo "$row" | tee -a "$LOG_FILE"
}

# 3. 메인 실행 루프
echo "=================================================="
echo "Starting OVN Scale Test: $ACTION Chassis $START to $END"
echo "Logging to: $LOG_FILE"
echo "=================================================="

for i in $(seq "$START" "$END"); do
    CHASSIS_NAME="ovn-chassis-$i"

    if [ "$ACTION" == "add" ]; then
        ./ovn_cluster.sh add-chassis "$CHASSIS_NAME" > /dev/null 2>&1
    elif [ "$ACTION" == "del" ]; then
        ./ovn_cluster.sh stop-chassis "$CHASSIS_NAME" > /dev/null 2>&1
    else
        echo "Invalid action: $ACTION"
        usage
    fi

    # 통계 수집 호출
    collect_stats_csv "$i"
    
    # 시스템 안정화를 위한 대기
    sleep 1
done

echo "=================================================="
echo "Action '$ACTION' completed."
echo "=================================================="
