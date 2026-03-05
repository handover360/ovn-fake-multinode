#!/bin/bash

# 설정 변수
LS_NAME="test-ls"
SUBNET="30.0.0.0/16"
MASK="16"
GW="30.0.255.255"      # 테스트용 가상 GW (필요 시 수정)
MTU="1400"         # OVN 터널링 오버헤드를 고려한 기본값
CENTRAL_CONTAINER="ovn-central-az1-1"

# 1. Logical Switch 생성 함수
create_ls() {
    echo "--- Checking Logical Switch: $LS_NAME ---"
    exists=$(podman exec $CENTRAL_CONTAINER ovn-nbctl ls-list | grep "$LS_NAME")
    if [ -z "$exists" ]; then
        podman exec $CENTRAL_CONTAINER ovn-nbctl ls-add $LS_NAME
        podman exec $CENTRAL_CONTAINER ovn-nbctl set logical_switch $LS_NAME other_config:subnet="$SUBNET"
        echo "Logical Switch $LS_NAME created."
    else
        echo "Logical Switch $LS_NAME already exists."
    fi
}

# 2. Logical Switch 삭제 함수
delete_ls() {
    echo "--- Deleting Logical Switch: $LS_NAME ---"
    podman exec $CENTRAL_CONTAINER ovn-nbctl ls-del $LS_NAME 2>/dev/null
    echo "Logical Switch $LS_NAME deleted."
}

# 3. Port 생성 함수 (create_fake_vm 로직 반영)
add_ports() {
    start=$1
    end=$2
    
    for i in $(seq $start $end); do
        CHASSIS="ovn-chassis-$i"
        PORT="lp$i"         # OVN Logical Port 이름
        NS="ns-$PORT"       # Chassis 내부 Netns 이름
        
        # IP/MAC 계산 (요청하신 255 진법 규칙)
        q=$((i / 255))
        r=$((i % 255))
        IP="30.0.$q.$r"
        MAC=$(printf "30:51:00:00:%02x:%02x" $q $r)

        echo "[Chassis $i] Creating Port $PORT (IP: $IP, MAC: $MAC)"

        # 3-1) OVN NBDB 설정
        podman exec $CENTRAL_CONTAINER ovn-nbctl lsp-add $LS_NAME $PORT
        podman exec $CENTRAL_CONTAINER ovn-nbctl lsp-set-addresses $PORT "$MAC $IP"

        # 3-2) Chassis 내부 "create_fake_vm" 동작 수행
        # 원본 함수처럼 veth 생성, OVS 포트 추가, external_ids 설정을 순서대로 진행합니다.
        podman exec $CHASSIS bash -c "
            # 1. Namespace 생성 및 기본 설정
            ip netns add $NS
            ip netns exec $NS ip link set lo up

            # 2. Veth pair 생성 및 연결
            # $NS-p는 호스트(Chassis)측 포트, $NS는 Namespace 내부 포트
            ip link add $NS-p type veth peer name $NS
            ip link set $NS netns $NS
            ip link set $NS-p up

            # 3. OVS 브릿지(br-int)에 호스트측 veth 추가 및 ID 바인딩
            ovs-vsctl add-port br-int $NS-p -- set Interface $NS-p external_ids:iface-id=$PORT

            # 4. Namespace 내부 인터페이스 상세 설정 (MAC, MTU, IP, GW)
            ip netns exec $NS ip link set $NS address $MAC
            ip netns exec $NS ip link set $NS mtu $MTU
            ip netns exec $NS ip addr add $IP/$MASK dev $NS
            ip netns exec $NS ip link set $NS up
            
            # GW 설정 (필요 시)
            # ip netns exec $NS ip route add default via $GW dev $NS
        "
    done
}

# 4. Port 삭제 함수 (역순 정리)
del_ports() {
    start=$1
    end=$2
    
    for i in $(seq $start $end); do
        CHASSIS="ovn-chassis-$i"
        PORT="lp$i"
        NS="ns-$PORT"

        echo "[Chassis $i] Cleaning up Port $PORT"

        # OVN 포트 삭제
        podman exec $CENTRAL_CONTAINER ovn-nbctl lsp-del $PORT 2>/dev/null

        # Chassis 내부 자원 삭제
        podman exec $CHASSIS bash -c "
            ovs-vsctl del-port br-int $NS-p 2>/dev/null
            ip netns del $NS 2>/dev/null
            ip link delete $NS-p 2>/dev/null
        "
    done
}

# 실행 가이드
case "$1" in
    ls-add)    create_ls ;;
    ls-del)    delete_ls ;;
    port-add)  add_ports $2 $3 ;;
    port-del)  del_ports $2 $3 ;;
    *) echo "Usage: $0 {ls-add|ls-del|port-add|port-del} [start_idx] [end_idx]" ;;
esac
