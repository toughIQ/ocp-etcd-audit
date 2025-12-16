#!/bin/bash

# ====================================================================================
# Script Name: ocp-etcd-audit.sh
# Target:      OpenShift 4.x (Universal)
# Description: Audits ETCD health, DB size, fragmentation, and object distribution.
#              Fixed formatting (Custom Columns & JSON Parsing).
# Usage:       ./ocp-etcd-audit.sh [options]
# ====================================================================================

# Formatting / Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Defaults
LIMIT=15
SHOW_ALL=false
CALC_SIZE=false
CONFIRM_ALL=false
EXACT_RESOURCE=""
FULL_REPORT=true

# Function: Usage Help
usage() {
    echo -e "${BOLD}OpenShift ETCD Audit Tool${NC}"
    echo -e "Usage: $0 [OPTIONS]"
    echo -e "\nOptions:"
    echo -e "  -n <number>        Show top <number> storage consumers (Default: 15)"
    echo -e "  -a, --all          Show ALL storage consumers"
    echo -e "  -s, --size         Calculate JSON representation size (Focus Mode)"
    echo -e "                     ${YELLOW}Note: JSON is approx. 3x larger than actual ETCD binary storage.${NC}"
    echo -e "  -e, --exact <res>  Calculate EXACT size via ETCD for ONE resource (Focus Mode)"
    echo -e "                     ${RED}WARNING: Creates high I/O load on ETCD directly!${NC}"
    echo -e "  -y, --yes          Skip interactive confirmations"
    echo -e "  -h, --help         Show this help message"
    exit 0
}

# Parse Arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -a|--all) SHOW_ALL=true ;;
        -n|--number) LIMIT="$2"; shift ;;
        -s|--size) 
            CALC_SIZE=true 
            FULL_REPORT=false 
            ;;
        -e|--exact) 
            EXACT_RESOURCE="$2" 
            FULL_REPORT=false 
            shift 
            ;;
        -y|--yes) CONFIRM_ALL=true ;;
        -h|--help) usage ;;
        *) echo -e "${RED}Unknown parameter: $1${NC}"; usage ;;
    esac
    shift
done

echo -e "${BLUE}${BOLD}>>> Starting OpenShift ETCD Audit...${NC}"

# 1. Prerequisite Check
if ! oc whoami &> /dev/null; then
    echo -e "${RED}Error: Not logged in. Please run 'oc login' first.${NC}"
    exit 1
fi

# 2. Pod Selection
# Wir nutzen app=etcd, um sicherzustellen, dass wir einen echten Member erwischen
ETCD_POD=$(oc get pods -n openshift-etcd -l app=etcd --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')

if [ -z "$ETCD_POD" ]; then
    echo -e "${RED}Error: No running ETCD pods found! Cannot proceed.${NC}"
    exit 1
fi
if [ "$FULL_REPORT" = true ]; then
    echo -e "Using pod for diagnostics: ${YELLOW}$ETCD_POD${NC}"
fi


# ------------------------------------------------------------------------------------
# MODE: EXACT ETCD SIZE CALCULATION (Focus Mode -e)
# ------------------------------------------------------------------------------------
if [ ! -z "$EXACT_RESOURCE" ]; then
    echo -e "\n${BOLD}MODE: Exact ETCD Size Calculation for '${EXACT_RESOURCE}'${NC}"
    echo -e "${YELLOW}Scanning ETCD keys to discover storage path...${NC}"

    # Normalize Name
    API_RES_OUT=$(oc api-resources --no-headers | grep -wi "^${EXACT_RESOURCE%%.*}" | head -1)
    if [ ! -z "$API_RES_OUT" ]; then
        SEARCH_NAME=$(echo "$API_RES_OUT" | awk '{print $1}')
    else
        SEARCH_NAME="${EXACT_RESOURCE%%.*}"
    fi

    # Discovery
    FIND_CMD="export ETCDCTL_API=3; etcdctl get / --prefix --keys-only | grep -m 1 '/${SEARCH_NAME}/'"
    FOUND_KEY=$(oc exec -n openshift-etcd "$ETCD_POD" -c etcd -- /bin/bash -c "$FIND_CMD" 2>/dev/null)

    if [ -z "$FOUND_KEY" ]; then
        echo -e "${RED}Error: Could not find any keys for resource '${SEARCH_NAME}' in ETCD.${NC}"
        exit 1
    fi

    # Path Extraction
    PREFIX_FOUND="${FOUND_KEY%/${SEARCH_NAME}/*}/${SEARCH_NAME}"
    echo -e "Identified ETCD Path: ${GREEN}${PREFIX_FOUND}${NC}"
    
    echo -e "\n${RED}${BOLD}!!! CRITICAL WARNING !!!${NC}"
    echo -e "You are about to perform a full raw data dump of '${PREFIX_FOUND}'."
    
    if [ "$CONFIRM_ALL" = false ]; then
        read -p "Proceed with exact calculation? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then echo "Aborted."; exit 0; fi
    fi

    echo -e "\nCalculating..."
    SIZE_CMD="export ETCDCTL_API=3; etcdctl get \"$PREFIX_FOUND\" --prefix | wc -c"
    TOTAL_BYTES=$(oc exec -n openshift-etcd "$ETCD_POD" -c etcd -- /bin/bash -c "$SIZE_CMD")
    MB=$(echo "scale=2; $TOTAL_BYTES / 1024 / 1024" | bc 2>/dev/null || echo "$((TOTAL_BYTES / 1024 / 1024))")

    echo "------------------------------------------------------------"
    echo -e "Resource:       ${BOLD}${EXACT_RESOURCE}${NC}"
    echo -e "Path:           ${PREFIX_FOUND}"
    echo -e "Exact Size:     ${GREEN}${MB} MB${NC} (Raw Protobuf/ETCD Storage)"
    echo "------------------------------------------------------------"
    exit 0
fi


# ------------------------------------------------------------------------------------
# GENERAL CLUSTER HEALTH (Full Report Only)
# ------------------------------------------------------------------------------------
if [ "$FULL_REPORT" = true ]; then
    echo -e "\n${BOLD}1. Cluster Operator Health:${NC}"
    CO_AVAILABLE=$(oc get co etcd -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')
    CO_DEGRADED=$(oc get co etcd -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}')

    if [ "$CO_AVAILABLE" == "True" ] && [ "$CO_DEGRADED" == "False" ]; then
        echo -e "ETCD Operator Status: ${GREEN}Healthy (Available=True, Degraded=False)${NC}"
    else
        echo -e "ETCD Operator Status: ${RED}UNHEALTHY! Check 'oc get co etcd'${NC}"
    fi

    # ------------------------------------------------------------------------------------
    # SECTION 2: POD DETAILS (FIXED with custom-columns)
    # ------------------------------------------------------------------------------------
    echo -e "\n${BOLD}2. ETCD Member Pod Details:${NC}"
    echo "------------------------------------------------------------------------------------------------------------------------"
    # Using custom-columns to prevent misalignment with long hostnames.
    oc get pods -n openshift-etcd -l app=etcd -o custom-columns="NAME:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase,IP:.status.podIP,RESTARTS:.status.containerStatuses[0].restartCount,START_TIME:.metadata.creationTimestamp"
    echo "------------------------------------------------------------------------------------------------------------------------"
fi


# ------------------------------------------------------------------------------------
# SECTION 3: DATABASE SIZE & FRAGMENTATION (RESTORED ORIGINAL LOGIC)
# ------------------------------------------------------------------------------------
if [ "$FULL_REPORT" = true ]; then
    echo -e "\n${BOLD}3. Database Size & Fragmentation (Endpoint Status):${NC}"
    printf "${BOLD}%-25s %-15s %-15s %-20b${NC}\n" "Node IP" "Phys. Size" "Used Data" "Fragmentation"
    echo "--------------------------------------------------------------------------------"

    ETCD_CMD_STRING="export ETCDCTL_API=3; etcdctl endpoint status -w json"
    RAW_JSON=$(oc exec -n openshift-etcd "$ETCD_POD" -c etcd -- /bin/bash -c "$ETCD_CMD_STRING")

    if [ $? -ne 0 ]; then
        echo -e "${RED}Error executing etcdctl.${NC}"
        exit 1
    fi

    # WICHTIG: Hier nutzen wir wieder DEINE ursprüngliche Logik (sed + grep),
    # weil die zuverlässiger mit der JSON-Struktur von OCP Etcd umgeht als mein vorheriger Versuch.
    echo "$RAW_JSON" | sed 's/{"Endpoint"/\n{"Endpoint"/g' | grep '"Endpoint"' | while read -r line; do
        
        NODE_IP=$(echo "$line" | grep -o '"Endpoint":"[^"]*"' | sed 's/.*"https:\/\///;s/:.*//')
        SIZE_BYTES=$(echo "$line" | grep -o '"dbSize":[0-9]*' | awk -F: '{print $2}')
        USED_BYTES=$(echo "$line" | grep -o '"dbSizeInUse":[0-9]*' | awk -F: '{print $2}')
        
        # Fallback auf 0, falls leer, um Rechenfehler zu vermeiden
        SIZE_MB=0; USED_MB=0
        if [ ! -z "$SIZE_BYTES" ]; then SIZE_MB=$((SIZE_BYTES / 1024 / 1024)); fi
        if [ ! -z "$USED_BYTES" ]; then USED_MB=$((USED_BYTES / 1024 / 1024)); fi
        
        SIZE_DISPLAY="${SIZE_MB} MB"
        if [ "$SIZE_MB" -gt 1500 ]; then SIZE_DISPLAY="${RED}${SIZE_MB} MB (!)${NC}"; fi
        
        USED_DISPLAY="${USED_MB} MB"
        
        FRAG_MSG=""
        if [ "$SIZE_MB" -gt 0 ]; then
             FRAG_VAL=$(( (SIZE_MB - USED_MB) * 100 / SIZE_MB ))
             
             if [ "$FRAG_VAL" -gt 45 ]; then 
                FRAG_MSG="${RED}${FRAG_VAL}% (High)${NC}"
             else 
                FRAG_MSG="${GREEN}${FRAG_VAL}%${NC}"
             fi
        fi

        printf "%-25s %-15s %-15s %-20b\n" "$NODE_IP" "$SIZE_DISPLAY" "$USED_DISPLAY" "$FRAG_MSG"
    done
    echo "--------------------------------------------------------------------------------"
    echo -e "Note: Fragmentation = (Phys. Size - Used Data) / Phys. Size."
fi


# ------------------------------------------------------------------------------------
# OBJECT ANALYSIS (Full Report OR if -s is active)
# ------------------------------------------------------------------------------------
if [ "$FULL_REPORT" = true ] || [ "$CALC_SIZE" = true ]; then

    if [ "$SHOW_ALL" = true ]; then DISPLAY_TEXT="ALL objects"; PIPELINE_CMD="cat"; else DISPLAY_TEXT="Top $LIMIT objects"; PIPELINE_CMD="head -n $LIMIT"; fi

    echo -e "\n${BOLD}4. Storage Consumers ($DISPLAY_TEXT):${NC}"

    if [ "$CALC_SIZE" = true ]; then
        echo -e "${YELLOW}Source: API Server (JSON Export). Size is approx. 3x larger than binary ETCD storage.${NC}"
        echo "------------------------------------------------------------------------------------------"
        printf "%-10s %-45s %-25s\n" "Count" "Resource" "Est. JSON Size (API)"
        echo "------------------------------------------------------------------------------------------"
        
        echo -e "${RED}Calculating sizes via API (This generates CPU load on API server)...${NC}"
        if [ "$CONFIRM_ALL" = false ]; then
            read -p "Are you sure? (y/N): " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then exit 0; fi
        fi
    else
        echo -e "${YELLOW}Source: API Server Metrics. Ordered by Object Count.${NC}"
        echo "------------------------------------------------------------"
        printf "%-10s %-50s\n" "Count" "Resource"
        echo "------------------------------------------------------------"
    fi

    oc get --raw /metrics | grep 'apiserver_storage_objects' | grep -v '#' | \
    awk '{ match($0, /resource="([^"]+)"/, m); print $2, m[1] }' | \
    awk '{a[$2]+=$1} END {for (i in a) print a[i], i}' | \
    sort -nr | $PIPELINE_CMD | \
    while read count resource; do
        if [ "$count" -gt 20000 ]; then C_COLOR=$RED; elif [ "$count" -gt 10000 ]; then C_COLOR=$YELLOW; else C_COLOR=$NC; fi

        if [ "$CALC_SIZE" = true ]; then
            SIZE_BYTES=$(oc get "$resource" --all-namespaces -o json --ignore-not-found 2>/dev/null | wc -c)
            if [ "$SIZE_BYTES" -gt 1048576 ]; then SIZE_STR="$((SIZE_BYTES / 1024 / 1024)) MB"; else SIZE_STR="$((SIZE_BYTES / 1024)) KB"; fi
            if [ "$SIZE_BYTES" -gt 104857600 ]; then S_COLOR=$RED; elif [ "$SIZE_BYTES" -gt 52428800 ]; then S_COLOR=$YELLOW; else S_COLOR=$NC; fi
            printf "${C_COLOR}%-10s${NC} %-45s ${S_COLOR}%-25s${NC}\n" "$count" "$resource" "$SIZE_STR"
        else
            printf "${C_COLOR}%-10s${NC} %-50s\n" "$count" "$resource"
        fi
    done
    if [ "$CALC_SIZE" = true ]; then echo "------------------------------------------------------------------------------------------"; else echo "------------------------------------------------------------"; fi
fi


# ------------------------------------------------------------------------------------
# PERFORMANCE LOGS (Full Report Only)
# ------------------------------------------------------------------------------------
if [ "$FULL_REPORT" = true ]; then
    echo -e "\n${BOLD}5. Disk Performance Check (WAL Fsync):${NC}"
    SLOW_LOGS=$(oc logs -n openshift-etcd "$ETCD_POD" -c etcd --since=1h | grep -c "apply request took too long")
    if [ "$SLOW_LOGS" -gt 0 ]; then
        echo -e "Result: ${RED}Found $SLOW_LOGS slow requests.${NC} (Check storage latency)" 
    else
        echo -e "Result: ${GREEN}No performance warnings found in logs.${NC}"
    fi

    echo -e "\n${BLUE}${BOLD}>>> Audit Complete.${NC}"
fi
