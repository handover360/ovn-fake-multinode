#!/bin/bash -xe

PODMAN_BIN=${1:-podman}

# Raft 클러스터 상태 요약 출력 추가 (스크립트 상단에 넣으면 좋습니다)
echo "Checking Raft Cluster Status..."
$PODMAN_BIN exec -it ovn-central-az1-1 ovs-appctl -t /var/run/ovn/ovnnb_db.ctl cluster/status OVN_Northbound | grep -E "Role|Term|Leader"

# [수정] Raft 환경에서는 az1-1 노드를 기준으로 NB/SB 상태를 확인합니다.
CENTRAL_NODE="ovn-central-az1-1"

# Simple configuration sanity checks
$PODMAN_BIN exec -it $CENTRAL_NODE ovn-nbctl show > nb_show
$PODMAN_BIN exec -it $CENTRAL_NODE ovn-sbctl show > sb_show

# 논리 자원(Switch/Router) 존재 여부 확인
grep "(public1)" nb_show
grep "(sw01)" nb_show
grep "(sw11)" nb_show
grep "(lr1)" nb_show

# Chassis 등록 상태 확인
grep "Chassis ovn-gw-1" sb_show
grep "Chassis ovn-chassis-1" sb_show
grep "Chassis ovn-chassis-2" sb_show

# --- 네트워크 가용성 체크 (Underlay IP 기반) ---
# 170.168.0.2 : az1-1
# 170.168.0.3 : az1-2
# 170.168.0.4 : az1-3
# 170.168.0.5 : gw-1
# 170.168.0.6 : chassis-1
# 170.168.0.7 : chassis-2

# Chassis-1에서 DB 노드(3개) 및 Gateway 노드 핑 테스트
for ip in 170.168.0.2 170.168.0.3 170.168.0.4 170.168.0.5; do
    $PODMAN_BIN exec -it ovn-chassis-1 ping -c 1 -w 1 $ip
done

# Chassis-2에서 DB 노드(3개) 및 Gateway 노드 핑 테스트
for ip in 170.168.0.2 170.168.0.3 170.168.0.4 170.168.0.5; do
    $PODMAN_BIN exec -it ovn-chassis-2 ping -c 1 -w 1 $ip
done

# Gateway-1에서 모든 노드 핑 테스트
for ip in 170.168.0.2 170.168.0.3 170.168.0.4 170.168.0.6 170.168.0.7; do
    $PODMAN_BIN exec -it ovn-gw-1 ping -c 1 -w 1 $ip
done


# --- 가상 VM(Namespace) 내부 라우팅 체크 ---

# Chassis-1 내부의 가상 포트 네임스페이스 확인
$PODMAN_BIN exec -it ovn-chassis-1 ip netns

# sw01p1 : dual stack 라우팅 체크
$PODMAN_BIN exec -it ovn-chassis-1 \
    ip netns exec sw01p1 ip --color=never -4 route > sw01p1_route
$PODMAN_BIN exec -it ovn-chassis-1 \
    ip netns exec sw01p1 ip --color=never -6 route >> sw01p1_route

cat sw01p1_route
grep "11.0.0.0/24 dev sw01p1" sw01p1_route
grep "default via 11.0.0.1 dev sw01p1" sw01p1_route
grep "1001::/64 dev sw01p1" sw01p1_route
grep "default via 1001::a dev sw01p1" sw01p1_route

echo 'happy happy, joy joy - Raft Cluster is Healthy!'
