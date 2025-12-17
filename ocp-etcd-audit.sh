#!/bin/bash

# ====================================================================================
# Script Name: ocp-etcd-audit.sh
# Target:      OpenShift 4.x (Universal)
# Author:      Chris Tawfik (ctawfik@redhat.com) | toughIQ (toughiq@gmail.com)
#              (with support from Gemini AI)
# Description: ETCD Audit Tool for Admins.
#              Includes 'Forensic Mode', Precision Math & Log Analysis.
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
FORENSIC_MODE=false
THROTTLE_SEC=1
SHOW_LOGS=false
SINCE="1h"

# Function: Usage Help
usage() {
    echo -e "${BOLD}OpenShift ETCD Audit Tool${NC}"
    echo -e "Usage: $0 [OPTIONS]"
    echo -e "\nStandard Options:"
    echo -e "  -n <number>        Show top <number> objects by COUNT (Default: 15)"
    echo -e "  -a, --all          Show ALL objects (Focus Mode)"
    echo -e "  -s, --size         Add JSON size column (Focus Mode)"
    echo -e "  -e, --exact <res>  Calculate EXACT size via ETCD for ONE resource (Focus Mode)"
    echo -e "  -l, --logs         Show ALL slow request log entries (Focus Mode)"
    echo -e "  -t, --since <time> Set log lookback duration (e.g., 30m, 48h). Use 'h' (no 'd'). Default: 1h"
    echo -e "  -y, --yes          Skip interactive confirmations (Disabled in Forensic Mode)"
    
    echo -e "\n${RED}Dangerous Options:${NC}"
    echo -e "  --forensic         ${RED}DEEP SCAN ALL RESOURCES.${NC} Measures exact Protobuf size in ETCD."
    echo -e "                     Requires manual input 'confirm'. Ignores -y."
    echo -e "  --throttle <sec>   Wait time between checks in forensic mode (Default: 1s)"
    
    echo -e "\n  -h, --help         Show this help message"
    exit 0
}

# Parse Arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -a|--all) 
            SHOW_ALL=true
            FULL_REPORT=false 
            ;;
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
        -l|--logs)
            SHOW_LOGS=true
            FULL_REPORT=false
            ;;
        -t|--time|--since)
            SINCE="$2"
            shift
            ;;
        --forensic)
            FORENSIC_MODE=true
            FULL_REPORT=false
            ;;
        --throttle)
            THROTTLE_SEC="$2"
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
ETCD_POD=$(oc get pods -n openshift-etcd -l app=etcd --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')

if [ -z "$ETCD_POD" ]; then
    echo -e "${RED}Error: No running ETCD pods found! Cannot proceed.${NC}"
    exit 1
fi

# Show chosen pod if we are in any report mode
if [ "$FULL_REPORT" = true ] || [ "$FORENSIC_MODE" = true ] || [ "$SHOW_LOGS" = true ]; then
    echo -e "Using pod for diagnostics: ${YELLOW}$ETCD_POD${NC}"
fi


# ====================================================================================
# FORENSIC MODE (Deep Scan with Discovery Logic)
# ====================================================================================
if [ "$FORENSIC_MODE" = true ]; then
    echo -e "\n${RED}${BOLD}!!! WARNING: FORENSIC MODE INITIATED !!!${NC}"
    echo -e "This mode will:"
    echo -e "1. Download the full list of ETCD keys (Metadata only)."
    echo -e "2. Discover the exact storage path for each resource."
    echo -e "3. Measure the EXACT storage size (Protobuf) with decimal precision."
    echo -e "${YELLOW}- This generates I/O load. Throttle is set to ${BOLD}${THROTTLE_SEC}s${NC}${YELLOW} (Use --throttle <sec> to change).${NC}"
    echo ""
    echo -e "To proceed, you must type ${BOLD}'confirm'${NC} (case-insensitive)."
    
    read -p "> " USER_INPUT
    
    if [[ "${USER_INPUT,,}" != "confirm" ]]; then
        echo -e "${RED}Confirmation failed. Aborting.${NC}"
        exit 1
    fi
    
    echo -e "\n${GREEN}Step 1: Mapping ETCD Storage Paths (Downloading Key List)...${NC}"
    KEY_MAP=$(mktemp)
    
    # Dump all keys (keys only, no values) to a temp file.
    MAP_CMD="export ETCDCTL_API=3; etcdctl get / --prefix --keys-only"
    oc exec -n openshift-etcd "$ETCD_POD" -c etcd -- /bin/bash -c "$MAP_CMD" > "$KEY_MAP"
    
    KEY_COUNT=$(wc -l < "$KEY_MAP")
    echo -e "Mapped ${BOLD}$KEY_COUNT${NC} keys. Proceeding to analysis."
    
    echo "---------------------------------------------------------------------------------------------------"
    printf "%-50s %-15s %-15s %-15s\n" "Resource" "API Count" "ETCD Keys" "REAL SIZE (Proto)"
    echo "---------------------------------------------------------------------------------------------------"
    
    # Iterate API Resources
    oc get --raw /metrics | grep 'apiserver_storage_objects' | grep -v '#' | \
    awk '{ match($0, /resource="([^"]+)"/, m); print $2, m[1] }' | \
    awk '{a[$2]+=$1} END {for (i in a) print a[i], i}' | \
    sort -nr | \
    while read api_count resource; do
        if [ "$api_count" -eq 0 ]; then
             printf "%-50s %-15s %-15s %-15s\n" "$resource" "0" "0" "0 B"
             continue
        fi
        SEARCH_NAME="${resource%%.*}"
        SAMPLE_KEY=$(grep -m 1 "/${SEARCH_NAME}/" "$KEY_MAP")
        
        if [ -z "$SAMPLE_KEY" ]; then
            printf "%-50s %-15s %-15s %-15s\n" "$resource" "$api_count" "?" "Path not found"
        else
            PREFIX="${SAMPLE_KEY%/${SEARCH_NAME}/*}/${SEARCH_NAME}"
            ETCD_COUNT=$(grep -c "^$PREFIX/" "$KEY_MAP")
            SIZE_CMD="export ETCDCTL_API=3; etcdctl get \"$PREFIX\" --prefix | wc -c"
            BYTES=$(oc exec -n openshift-etcd "$ETCD_POD" -c etcd -- /bin/bash -c "$SIZE_CMD" 2>/dev/null)
            
            if [ "$BYTES" -gt 1048576 ]; then 
                VAL=$(echo "scale=2; $BYTES / 1048576" | bc 2>/dev/null)
                if [ -z "$VAL" ]; then VAL="$((BYTES / 1048576))"; fi 
                SIZE_STR="${VAL} MB"
            elif [ "$BYTES" -gt 1024 ]; then 
                VAL=$(echo "scale=2; $BYTES / 1024" | bc 2>/dev/null)
                if [ -z "$VAL" ]; then VAL="$((BYTES / 1024))"; fi 
                SIZE_STR="${VAL} KB"
            else 
                SIZE_STR="$BYTES B"
            fi
            
            if [ "$BYTES" -gt 52428800 ]; then S_COLOR=$RED; elif [ "$BYTES" -gt 10485760 ]; then S_COLOR=$YELLOW; else S_COLOR=$NC; fi

            printf "%-50s %-15s %-15s ${S_COLOR}%-15s${NC}\n" "$resource" "$api_count" "$ETCD_COUNT" "$SIZE_STR"
            sleep "$THROTTLE_SEC"
        fi
    done
    rm "$KEY_MAP"
    echo "---------------------------------------------------------------------------------------------------"
    echo -e "${BLUE}Forensic Audit Complete.${NC}"
    exit 0
fi


# ------------------------------------------------------------------------------------
# MODE: EXACT ETCD SIZE CALCULATION (Single Resource -e)
# ------------------------------------------------------------------------------------
if [ ! -z "$EXACT_RESOURCE" ]; then
    echo -e "\n${BOLD}MODE: Exact ETCD Size Calculation for '${EXACT_RESOURCE}'${NC}"
    echo -e "${YELLOW}Scanning ETCD keys to discover storage path...${NC}"

    API_RES_OUT=$(oc api-resources --no-headers | grep -wi "^${EXACT_RESOURCE%%.*}" | head -1)
    if [ ! -z "$API_RES_OUT" ]; then SEARCH_NAME=$(echo "$API_RES_OUT" | awk '{print $1}'); else SEARCH_NAME="${EXACT_RESOURCE%%.*}"; fi

    FIND_CMD="export ETCDCTL_API=3; etcdctl get / --prefix --keys-only | grep -m 1 '/${SEARCH_NAME}/'"
    FOUND_KEY=$(oc exec -n openshift-etcd "$ETCD_POD" -c etcd -- /bin/bash -c "$FIND_CMD" 2>/dev/null)

    if [ -z "$FOUND_KEY" ]; then
        echo -e "${RED}Error: Could not find any keys for resource '${SEARCH_NAME}' in ETCD.${NC}"
        exit 1
    fi

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

    echo -e "\n${BOLD}2. ETCD Member Pod Details:${NC}"
    echo "------------------------------------------------------------------------------------------------------------------------"
    oc get pods -n openshift-etcd -l app=etcd -o custom-columns="NAME:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase,IP:.status.podIP,RESTARTS:.status.containerStatuses[0].restartCount,START_TIME:.metadata.creationTimestamp"
    echo "------------------------------------------------------------------------------------------------------------------------"
    
    echo -e "\n${BOLD}3. Database Size & Fragmentation (Endpoint Status):${NC}"
    printf "${BOLD}%-25s %-15s %-15s %-20b${NC}\n" "Node IP" "Phys. Size" "Used Data" "Fragmentation"
    echo "--------------------------------------------------------------------------------"

    ETCD_CMD_STRING="export ETCDCTL_API=3; etcdctl endpoint status -w json"
    RAW_JSON=$(oc exec -n openshift-etcd "$ETCD_POD" -c etcd -- /bin/bash -c "$ETCD_CMD_STRING")

    echo "$RAW_JSON" | sed 's/{"Endpoint"/\n{"Endpoint"/g' | grep '"Endpoint"' | while read -r line; do
        NODE_IP=$(echo "$line" | grep -o '"Endpoint":"[^"]*"' | sed 's/.*"https:\/\///;s/:.*//')
        SIZE_BYTES=$(echo "$line" | grep -o '"dbSize":[0-9]*' | awk -F: '{print $2}')
        USED_BYTES=$(echo "$line" | grep -o '"dbSizeInUse":[0-9]*' | awk -F: '{print $2}')
        
        SIZE_MB=0; USED_MB=0
        if [ ! -z "$SIZE_BYTES" ]; then SIZE_MB=$((SIZE_BYTES / 1024 / 1024)); fi
        if [ ! -z "$USED_BYTES" ]; then USED_MB=$((USED_BYTES / 1024 / 1024)); fi
        
        SIZE_DISPLAY="${SIZE_MB} MB"
        if [ "$SIZE_MB" -gt 1500 ]; then SIZE_DISPLAY="${RED}${SIZE_MB} MB (!)${NC}"; fi
        USED_DISPLAY="${USED_MB} MB"
        
        FRAG_MSG=""
        if [ "$SIZE_MB" -gt 0 ]; then
             FRAG_VAL=$(( (SIZE_MB - USED_MB) * 100 / SIZE_MB ))
             if [ "$FRAG_VAL" -gt 45 ]; then FRAG_MSG="${RED}${FRAG_VAL}% (High)${NC}"; else FRAG_MSG="${GREEN}${FRAG_VAL}%${NC}"; fi
        fi
        printf "%-25s %-15s %-15s %-20b\n" "$NODE_IP" "$SIZE_DISPLAY" "$USED_DISPLAY" "$FRAG_MSG"
    done
    echo "--------------------------------------------------------------------------------"
    echo -e "Note: Fragmentation = (Phys. Size - Used Data) / Phys. Size."
fi


# ------------------------------------------------------------------------------------
# OBJECT ANALYSIS (Standard Workflow)
# ------------------------------------------------------------------------------------
if [ "$FULL_REPORT" = true ] || [ "$CALC_SIZE" = true ] || [ "$SHOW_ALL" = true ]; then

    if [ "$FULL_REPORT" = true ]; then echo -e "\n${BOLD}4. Storage Consumers:${NC}"; else echo -e "\n${BOLD}Storage Consumers Analysis:${NC}"; fi

    API_TOTAL=$(oc get --raw /metrics | grep 'apiserver_storage_objects' | grep -v '#' | awk '{s+=$2} END {print s}')
    ETCD_RAW_CMD="export ETCDCTL_API=3; etcdctl get / --prefix --count-only --write-out=fields"
    ETCD_RAW=$(oc exec -n openshift-etcd "$ETCD_POD" -c etcd -- /bin/bash -c "$ETCD_RAW_CMD" 2>/dev/null | grep "Count" | awk '{print $NF}' | tr -d '"')

    FILTER_CMD="head -n $LIMIT"
    [ "$SHOW_ALL" = true ] && FILTER_CMD="cat"

    LIST_BUFFER=$(mktemp)
    oc get --raw /metrics | grep 'apiserver_storage_objects' | grep -v '#' | \
    awk '{ match($0, /resource="([^"]+)"/, m); print $2, m[1] }' | \
    awk '{a[$2]+=$1} END {for (i in a) print a[i], i}' | \
    sort -nr | $FILTER_CMD > "$LIST_BUFFER"

    DISPLAYED_SUM=$(awk '{s+=$1} END {print s}' "$LIST_BUFFER")

    echo "------------------------------------------------------------"
    printf "Total Keys (ETCD Raw):    ${BOLD}%-10s${NC} (Physical DB Entries)\n" "$ETCD_RAW"
    printf "Total Objects (API):      ${BOLD}%-10s${NC} (Logical K8s Resources)\n" "$API_TOTAL"
    printf "Displayed in list:        ${BOLD}%-10s${NC} (Sum of listed items)\n" "$DISPLAYED_SUM"
    echo "------------------------------------------------------------"

    if [ "$CALC_SIZE" = true ]; then
        echo -e "${YELLOW}Ordered by: Count (Includes estimated JSON size)${NC}"
        printf "%-10s %-45s %-25s\n" "Count" "Resource" "Est. JSON Size (API)"
        echo "------------------------------------------------------------------------------------------"
        if [ "$SHOW_ALL" = true ] && [ "$CONFIRM_ALL" = false ]; then
            echo -e "${RED}Warning: Calculating size for ALL $API_TOTAL items generates load.${NC}"
            read -p "Proceed? (y/N): " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then rm "$LIST_BUFFER"; exit 0; fi
        fi
    else
        echo -e "${YELLOW}Ordered by: Count${NC}"
        printf "%-10s %-50s\n" "Count" "Resource"
        echo "------------------------------------------------------------"
    fi

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
    done < "$LIST_BUFFER"
    rm "$LIST_BUFFER"
    if [ "$CALC_SIZE" = true ]; then echo "------------------------------------------------------------------------------------------"; else echo "------------------------------------------------------------"; fi
fi


# ------------------------------------------------------------------------------------
# DISK PERFORMANCE CHECK (Logs)
# ------------------------------------------------------------------------------------
if [ "$FULL_REPORT" = true ] || [ "$SHOW_LOGS" = true ]; then
    
    if [ "$FULL_REPORT" = true ]; then
        echo -e "\n${BOLD}5. Disk Performance Check (WAL Fsync - Last $SINCE):${NC}"
    else
        echo -e "\n${BOLD}Disk Performance Analysis (Last $SINCE Logs):${NC}"
    fi
    
    # Capture relevant logs based on SINCE parameter
    LOG_BUFFER=$(mktemp)
    oc logs -n openshift-etcd "$ETCD_POD" -c etcd --since="$SINCE" > "$LOG_BUFFER"
    
    # Filter for Slow Requests
    RAW_SLOW=$(grep "apply request took too long" "$LOG_BUFFER")
    SLOW_COUNT=$(echo "$RAW_SLOW" | grep -c "apply request took too long")
    
    # Helper to Prettify JSON logs
    prettify_log() {
        sed -E 's/.*"ts":"([^"]+)".*"msg":"([^"]+)","took":"([^"]+)".*/[\1] \2 (\3)/'
    }

    if [ "$SLOW_COUNT" -gt 0 ]; then
        echo -e "Result: ${RED}Found $SLOW_COUNT slow requests.${NC} (Check storage latency)" 
        
        if [ "$SHOW_LOGS" = true ]; then
            echo -e "${YELLOW}All occurrences (Last $SINCE):${NC}"
            echo "$RAW_SLOW" | prettify_log
        else
            echo -e "${YELLOW}Latest 5 occurrences (Last $SINCE):${NC}"
            echo "$RAW_SLOW" | tail -n 5 | prettify_log
            if [ "$SLOW_COUNT" -gt 5 ]; then
                echo -e "... (Use ${BOLD}-l or --logs${NC} to view all $SLOW_COUNT entries)"
            fi
        fi
        
        # Correlate with potential triggers
        echo -e "\n${BOLD}Diagnosis:${NC}"
        TRIGGERS=$(grep -E -i "defrag|snapshot|compact" "$LOG_BUFFER" | grep -v "apply request took too long" | tail -n 3)
        if [ ! -z "$TRIGGERS" ]; then
             echo -e "Found maintenance tasks in logs that might cause latency:"
             # Prettify generic triggers
             echo "$TRIGGERS" | sed -E 's/.*"ts":"([^"]+)".*"msg":"([^"]+)".*/[\1] \2/' | sed 's/}/ /g' 
        else
             echo -e "No obvious maintenance tasks (defrag/snapshot) found near the events."
             echo -e "This suggests ${RED}underlying storage/disk latency${NC}."
        fi
        
    else
        echo -e "Result: ${GREEN}No performance warnings found in logs (Last $SINCE).${NC}"
    fi
    rm "$LOG_BUFFER"

    echo -e "\n${BLUE}${BOLD}>>> Audit Complete.${NC}"
fi
