#!/bin/bash

# 설정 변수
LS_NAME="test-ls"
SUBNET="30.0.0.0/16"
MASK="16"
GW="30.0.255.255"      # 테스트용 가상 GW (필요 시 수정)
MTU="1400"         # OVN 터널링 오버헤드를 고려한 기본값
CENTRAL_NODES=("ovn-central-az1-1" "ovn-central-az1-2" "ovn-central-az1-3")
#CENTRAL_CONTAINER="ovn-central-az1-1"

# [신규] OVN Northbound DB Leader 노드를 찾는 함수
find_leader() {
    for node in "${CENTRAL_NODES[@]}"; do
        # 해당 컨테이너가 실행 중인지 먼저 확인
        if ! podman ps --format "{{.Names}}" | grep -q "^$node$"; then
            continue
        fi

        # cluster/status 명령어로 Role: leader 인지 확인
        ROLE=$(podman exec "$node" ovn-appctl -t /var/run/ovn/ovnnb_db.ctl cluster/status OVN_Northbound | grep "Role: leader")

        if [ -n "$ROLE" ]; then
            echo "$node"
            return 0
        fi
    done
    echo "" # 리더를 찾지 못한 경우
}

# 리더 노드 할당
LEADER_NODE=$(find_leader)

if [ -z "$LEADER_NODE" ]; then
    echo "ERROR: Could not find OVN NBDB Leader. Please check central containers."
    exit 1
else
    echo "Current OVN NBDB Leader: $LEADER_NODE"
fi

# 1. Logical Switch 생성
create_ls() {
    echo "--- Checking Logical Switch: $LS_NAME via Leader ($LEADER_NODE) ---"
    exists=$(podman exec $LEADER_NODE ovn-nbctl ls-list | grep "$LS_NAME")
    if [ -z "$exists" ]; then
        podman exec $LEADER_NODE ovn-nbctl ls-add $LS_NAME
        podman exec $LEADER_NODE ovn-nbctl set logical_switch $LS_NAME other_config:subnet="$SUBNET"
        echo "Logical Switch $LS_NAME created."
    else
        echo "Logical Switch $LS_NAME already exists."
    fi
}

# 2. Logical Switch 삭제
delete_ls() {
    echo "--- Deleting Logical Switch: $LS_NAME via Leader ($LEADER_NODE) ---"
    podman exec $LEADER_NODE ovn-nbctl ls-del $LS_NAME 2>/dev/null
    echo "Logical Switch $LS_NAME deleted."
}

# 3. Port 생성 (Leader 노드에 LSP 추가)
add_ports() {
    start=$1
    end=$2
    for i in $(seq $start $end); do
        CHASSIS="ovn-chassis-$i"
        PORT="lp$i"
        NS="ns-$PORT"
        q=$((i / 255)); r=$((i % 255))
        IP="30.0.$q.$r"
        MAC=$(printf "30:51:00:00:%02x:%02x" $q $r)

        echo "[Chassis $i] Creating Port $PORT (IP: $IP, MAC: $MAC) via Leader ($LEADER_NODE)"
        
        # NBDB 명령은 리더에게 전달
        podman exec $LEADER_NODE ovn-nbctl lsp-add $LS_NAME $PORT
        podman exec $LEADER_NODE ovn-nbctl lsp-set-addresses $PORT "$MAC $IP"

        # 섀시 내부 설정은 해당 섀시 컨테이너에서 수행
        podman exec $CHASSIS bash -c "
	    # 1. Namespace 생성 및 기본 설정
            ip netns add $NS 2>/dev/null || true
            ip netns exec $NS ip link set lo up

	    # 2. Veth pair 생성 및 연결
	    # $NS-p는 호스트(Chassis)측 포트, $NS는 Namespace 내부 포트
            ip link add $NS-p type veth peer name $NS 2>/dev/null || true
            ip link set $NS netns $NS
            ip link set $NS-p up

	    # 3. OVS 브릿지(br-int)에 호스트측 veth 추가 및 ID 바인딩
            ovs-vsctl --may-exist add-port br-int $NS-p -- set Interface $NS-p external_ids:iface-id=$PORT

	    # 4. Namespace 내부 인터페이스 상세 설정 (MAC, MTU, IP, GW)
            ip netns exec $NS ip link set $NS address $MAC
            ip netns exec $NS ip link set $NS mtu $MTU
            ip netns exec $NS ip addr add $IP/$MASK dev $NS 2>/dev/null || true
            ip netns exec $NS ip link set $NS up

	    # GW 설정 (필요 시)
	    # ip netns exec $NS ip route add default via $GW dev $NS
        "
    done
}

# 4. Port 삭제
del_ports() {
    start=$1
    end=$2
    for i in $(seq $start $end); do
        CHASSIS="ovn-chassis-$i"
        PORT="lp$i"; NS="ns-$PORT"
        echo "[Chassis $i] Cleaning up Port $PORT via Leader ($LEADER_NODE)"

	# OVN 포트 삭제
        podman exec $LEADER_NODE ovn-nbctl lsp-del $PORT 2>/dev/null

	# Chassis 내부 자원 삭제
        podman exec $CHASSIS bash -c "
            ovs-vsctl del-port br-int $NS-p 2>/dev/null
            ip netns del $NS 2>/dev/null
            ip link delete $NS-p 2>/dev/null
        "
    done
}

# 5. 전체 노드 통신 무결성 체크
check_connectivity() {
    start=$1
    end=$2
    echo "--- Checking Connectivity from Chassis 1 to others ($start ~ $end) ---"
    success=0; fail=0
    for i in $(seq $start $end); do
        if [ "$i" -eq 1 ]; then continue; fi
        q=$((i / 255)); r=$((i % 255))
        target_ip="30.0.$q.$r"
        if podman exec ovn-chassis-1 ip netns exec ns-lp1 ping -c 1 -W 1 $target_ip > /dev/null 2>&1; then
            echo "[OK] Chassis 1 -> Chassis $i ($target_ip)"
            ((success++))
        else
            echo "[FAIL] Chassis 1 -> Chassis $i ($target_ip)"
            ((fail++))
        fi
    done
    echo "--- Test Result: Success $success, Fail $fail ---"
}

# 6. 리더 상태 및 클러스터 현황 출력
check_status() {
    echo "--- OVN Cluster Status (Leader: $LEADER_NODE) ---"
    podman exec $LEADER_NODE ovn-appctl -t /var/run/ovn/ovnnb_db.ctl cluster/status OVN_Northbound
    
    echo -e "\n--- Southbound DB Chassis Count ---"
    ch_count=$(podman exec $LEADER_NODE ovn-sbctl list chassis | grep -E "^name" | wc -l)
    echo "Current Chassis in SB DB: $ch_count"

    echo -e "\n--- System Memory Status ---"
    free -h
}

# 7. [신규] 클러스터 타이머 및 Probe 간격 최적화
optimize_cluster() {
    echo "--- Optimizing OVN Cluster Timers via Leader ($LEADER_NODE) ---"

    # 1) Raft Election Timer 변경 (1s -> 10s)
    # 현재 값의 최대 2배씩만 증가 가능하므로 단계별로 실행
    for db in "nb" "sb"; do
        case $db in
            nb) db_name="OVN_Northbound"; ctl_file="ovnnb_db.ctl" ;;
            sb) db_name="OVN_Southbound"; ctl_file="ovnsb_db.ctl" ;;
        esac

        echo "[Step 1] Changing $db_name election timer to 10000ms..."
        for timer in 2000 4000 8000 10000; do
            podman exec "$LEADER_NODE" ovn-appctl -t "/var/run/ovn/$ctl_file" \
                cluster/change-election-timer "$db_name" "$timer"
            sleep 1 # 클러스터 합의를 위한 짧은 대기
        done
    done

    # 2) Northd Probe Interval 변경 (5s -> 180s)
    echo "[Step 2] Changing Northd Probe Interval to 180000ms..."
    podman exec "$LEADER_NODE" ovn-nbctl set NB_Global . options:northd_probe_interval=180000

    echo "Optimization commands initiated."
    echo "Wait a few seconds for Southbound DB synchronization..."
    sleep 3

    # 결과 확인 호출
    check_opt_result
}

# 8. [신규] 최적화 결과 확인 함수
check_opt_result() {
    echo -e "\n--- Checking Optimization Results ---"

    # Raft Timer 확인
    echo "[Raft Election Timers]"
    echo "NB DB:"
    podman exec "$LEADER_NODE" ovn-appctl -t /var/run/ovn/ovnnb_db.ctl cluster/status OVN_Northbound | grep "Election timer"
    echo "SB DB:"
    podman exec "$LEADER_NODE" ovn-appctl -t /var/run/ovn/ovnsb_db.ctl cluster/status OVN_Southbound | grep "Election timer"

    # Probe Interval 확인
    echo -e "\n[Northd Probe Interval]"
    echo -n "NB Global: "
    podman exec "$LEADER_NODE" ovn-nbctl get NB_Global . options:northd_probe_interval
    echo -n "SB Global (Synced): "
    podman exec "$LEADER_NODE" ovn-sbctl get SB_Global . options:northd_probe_interval
}

# 실행 가이드
case "$1" in
    ls-add)    create_ls ;;
    ls-del)    delete_ls ;;
    port-add)  add_ports $2 $3 ;;
    port-del)  del_ports $2 $3 ;;
    check)     check_connectivity $2 $3 ;;
    optimize)  optimize_cluster ;;
    status)    check_status ;;
    *) echo "Usage: $0 {ls-add|ls-del|port-add|port-del|check|status|optimize} [start_idx] [end_idx]" ;;
esac
