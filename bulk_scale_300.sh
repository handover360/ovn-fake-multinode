#!/bin/bash
# bulk_scale_300.sh

CHASSIS_COUNT=300
SWITCH_NAME="sw01"
CENTRAL_NODE="ovn-central-az1-1"

echo "Step 1: Creating 300 Logical Ports on $SWITCH_NAME..."
for i in $(seq 1 $CHASSIS_COUNT); do
    PORT_NAME="lp-$i"
    MAC="50:54:00:00:$(printf '%02x\n' $((i/256))):$(printf '%02x\n' $((i%256)))"
    IP="11.0.1.$(($i % 254 + 1))" # 중복 방지를 위한 간단한 계산
    
    # NB DB에 포트 생성
    podman exec $CENTRAL_NODE ovn-nbctl lsp-add $SWITCH_NAME $PORT_NAME \
        -- lsp-set-addresses $PORT_NAME "$MAC $IP"
done

echo "Step 2: Binding ports to each Chassis..."
for i in $(seq 1 $CHASSIS_COUNT); do
    CHASSIS_NAME="ovn-chassis-$i"
    PORT_NAME="lp-$i"
    NS_NAME="ns-$i"
    
    # 각 Chassis 컨테이너 내부에서 가짜 VM(Namespace) 생성 및 OVS 바인딩
    # 백그라운드로 실행하여 속도 향상
    podman exec $CHASSIS_NAME bash -c "
        ip netns add $NS_NAME
        ovs-vsctl add-port br-int $PORT_NAME -- set Interface $PORT_NAME type=internal
        ip link set $PORT_NAME netns $NS_NAME
        ip netns exec $NS_NAME ip link set $PORT_NAME up
        # OVN에 이 포트가 여기에 있다고 알림 (핵심)
        ovs-vsctl set Interface $PORT_NAME external_ids:iface-id=$PORT_NAME
    " &
    
    # 50대마다 잠깐 휴식 (부하 조절)
    if [ $((i % 50)) -eq 0 ]; then
        wait
        echo "Progress: $i / $CHASSIS_COUNT Chassis bound..."
    fi
done
wait
echo "All 300 nodes are scaled and bound!"
