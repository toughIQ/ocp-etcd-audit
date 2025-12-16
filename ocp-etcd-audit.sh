#!/bin/bash

# ====================================================================================
# Script Name: ocp-etcd-audit.sh
# Target:      OpenShift 4.x (Universal)
# Description: ETCD Audit Tool for Admins.
#              Workflow:
#              1. Standard: Overview + Top 15 Counts.
#              2. Focus (-a, -s, -e): Hides overview, focuses on object analysis.
#              3. Stats: Shows Total ETCD Keys vs. API Objects vs. Displayed.
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
    echo -e "  -n <number>        Show top <number> objects by COUNT (Default: 15)"
    echo -e "  -a, --all          Show ALL objects (Focus Mode: Hides Cluster Info)"
    echo -e "  -s, --size         Add JSON size column (Focus Mode: Hides Cluster Info)"
    echo -e "                     ${YELLOW}Note: Calculates size only for the displayed items.${NC}"
    echo -e "  -e, --exact <res>  Calculate EXACT size via ETCD for ONE resource (Focus Mode)"
    echo -e "                     ${RED}WARNING: Creates high I/O load on ETCD directly!${NC}"
    echo -e "  -y, --yes          Skip interactive confirmations"
    echo -e "  -h, --help         Show this help message"
    exit 0
}

# Parse Arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -a|--all) 
            SHOW_ALL=true
            FULL_REPORT=false # Focus Mode requested
            ;;
        -n|--number) LIMIT="$2"; shift ;;
        -s|--size) 
            CALC_SIZE=true 
            FULL_REPORT=false # Focus Mode requested
            ;;
        -e|--exact) 
            EXACT_RESOURCE="$2" 
            FULL_REPORT=false # Focus Mode requested
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

# 2. Pod Selection (Always needed for ETCD stats/size)
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
# GENERAL CLUSTER HEALTH (Only if FULL_REPORT is true)
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

    # SECTION 2: POD DETAILS
    echo -e "\n${BOLD}2. ETCD Member Pod Details:${NC}"
    echo "------------------------------------------------------------------------------------------------------------------------"
    oc get pods -n openshift-etcd -l app=etcd -o custom-columns="NAME:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase,IP:.status.podIP,RESTARTS:.status.containerStatuses[0].restartCount,START_TIME:.metadata.creationTimestamp"
    echo "------------------------------------------------------------------------------------------------------------------------"
    
    # SECTION 3: DB SIZE
    echo -e "\n${BOLD}3. Database Size & Fragmentation (Endpoint Status):${NC}"
    printf "${BOLD}%-25s %-15s %-15s %-20b${NC}\n" "Node IP" "Phys. Size" "Used Data" "Fragmentation"
    echo "--------------------------------------------------------------------------------"

    ETCD_CMD_STRING="export ETCDCTL_API=3; etcdctl endpoint status -w json"
    RAW_JSON=$(oc exec -n openshift-etcd "$ETCD_POD" -c etcd -- /bin/bash -c "$ETCD_CMD_STRING")

    if [ $? -ne 0 ]; then
        echo -e "${RED}Error executing etcdctl.${NC}"
        exit 1
    fi

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
# OBJECT ANALYSIS (Always Runs)
# ------------------------------------------------------------------------------------
# Header Logic based on mode
if [ "$FULL_REPORT" = true ]; then
    echo -e "\n${BOLD}4. Storage Consumers:${NC}"
else
    # In Focus mode (-a or -s), we skip the "4." numbering to make it cleaner
    echo -e "\n${BOLD}Storage Consumers Analysis:${NC}"
fi

# 1. GATHER TOTAL STATS
# ---------------------
# API Total (Logical)
API_TOTAL=$(oc get --raw /metrics | grep 'apiserver_storage_objects' | grep -v '#' | awk '{s+=$2} END {print s}')

# ETCD Raw Total (Physical)
# FIX: Use sed to extract only digits, ignoring spaces or colons to prevent parsing errors
ETCD_RAW=$(oc exec -n openshift-etcd "$ETCD_POD" -c etcd -- etcdctl get / --prefix --count-only --write-out=fields 2>/dev/null | grep "Count" | sed 's/[^0-9]*//g')


# 2. PREPARE LIST BUFFER
# ----------------------
# We buffer the output first to calculate the "Displayed Sum" before printing the table.
FILTER_CMD="head -n $LIMIT"
[ "$SHOW_ALL" = true ] && FILTER_CMD="cat"

LIST_BUFFER=$(mktemp)

# Pipeline: Get Metrics -> Parse -> Sort by Count -> Filter Top N -> Save to Buffer
oc get --raw /metrics | grep 'apiserver_storage_objects' | grep -v '#' | \
awk '{ match($0, /resource="([^"]+)"/, m); print $2, m[1] }' | \
awk '{a[$2]+=$1} END {for (i in a) print a[i], i}' | \
sort -nr | $FILTER_CMD > "$LIST_BUFFER"

# Calculate Sum of displayed items
DISPLAYED_SUM=$(awk '{s+=$1} END {print s}' "$LIST_BUFFER")


# 3. PRINT STATS HEADER
# ---------------------
echo "------------------------------------------------------------"
printf "Total Keys (ETCD Raw):    ${BOLD}%-10s${NC} (Physical DB Entries)\n" "$ETCD_RAW"
printf "Total Objects (API):      ${BOLD}%-10s${NC} (Logical K8s Resources)\n" "$API_TOTAL"
printf "Displayed in list:        ${BOLD}%-10s${NC} (Sum of listed items)\n" "$DISPLAYED_SUM"
echo "------------------------------------------------------------"

if [ "$CALC_SIZE" = true ]; then
    echo -e "${YELLOW}Ordered by: Count (Includes estimated JSON size)${NC}"
    printf "%-10s %-45s %-25s\n" "Count" "Resource" "Est. JSON Size (API)"
    echo "------------------------------------------------------------------------------------------"
    
    # Warn if huge
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


# 4. PRINT LIST FROM BUFFER
# -------------------------
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

# Cleanup
rm "$LIST_BUFFER"

if [ "$CALC_SIZE" = true ]; then echo "------------------------------------------------------------------------------------------"; else echo "------------------------------------------------------------"; fi


# ------------------------------------------------------------------------------------
# PERFORMANCE LOGS (Only if FULL_REPORT is true)
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
