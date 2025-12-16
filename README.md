# OpenShift ETCD Audit Tool

**A precision diagnostic tool for OpenShift Administrators to analyze ETCD storage consumption, fragmentation, and object distribution.**

![License](https://img.shields.io/badge/license-MIT-blue.svg)

## 💡 The Idea Behind This Tool

As an OpenShift Administrator, you often face a disconnect between **Logical Kubernetes Objects** (what the API Server sees) and **Physical ETCD Storage** (what is actually on the disk).

* **The Problem:** You might see alerts about ETCD database size limits or slow disk performance ("apply request took too long"). Standard tools like `oc get` only show you the *count* of objects. However, 1,000 empty Secrets take up significantly less space than 10 huge ConfigMaps containing binary data or massive CRDs.
* **The Solution:** This script bridges that gap. It allows you to:
    1.  Check the physical health and fragmentation of the ETCD database.
    2.  Correlate API object counts with physical storage keys.
    3.  Estimate JSON sizes of resources via the API.
    4.  **Measure the exact Protobuf size** of resources directly on the storage layer.

It is designed to follow a "Drill-Down" workflow: starting with a safe overview and moving to deep forensic analysis only when explicitly requested.

---

## 🚀 Installation & Prerequisites

### Prerequisites
* OpenShift Client (`oc`) installed.
* Logged in as a user with **cluster-admin** privileges.
* Access to the `openshift-etcd` namespace (to execute commands in ETCD pods).

### Installation

    git clone [https://github.com/your-repo/ocp-etcd-audit.git](https://github.com/your-repo/ocp-etcd-audit.git)
    cd ocp-etcd-audit
    chmod +x ocp-etcd-audit.sh

---

## 🛠 Usage & Parameters

The script uses a safe-by-default approach. Hazardous operations require explicit flags and confirmation.

    ./ocp-etcd-audit.sh [OPTIONS]

| Option | Description |
| :--- | :--- |
| `-n <number>` | Show top `<number>` objects by count (Default: 15). |
| `-a`, `--all` | Show **ALL** objects (Focus Mode: hides cluster health info). |
| `-s`, `--size` | Add an **Estimated JSON Size** column to the output list. |
| `-e <res>` | **Exact Mode:** Calculate the exact physical size for **ONE** specific resource (e.g., `-e secrets`). |
| `-y`, `--yes` | Skip interactive confirmations (Ignored in Forensic Mode). |
| `--forensic` | **Forensic Mode:** Deep scan of ALL resources to measure exact physical size on disk. |
| `--throttle <sec>`| Set wait time between forensic checks in seconds (Default: 1s). |
| `-h`, `--help` | Show the help message. |

---

## 📖 The Admin Workflow

This tool is designed to support a structured troubleshooting process ("From broad overview to deep details").

### 1. The "Morning Check" (Overview)
Start here to get a quick pulse of the cluster. This runs fast and creates no load.

    ./ocp-etcd-audit.sh

**What you see:**
* **Cluster Health:** Operator status and ETCD Pod stability.
* **DB Size & Fragmentation:** Is the DB full? Is there high fragmentation (unused space)?
* **Total Object Count:** A comparison between API Objects (logical) and ETCD Keys (physical).
* **Top Consumers:** The top 15 resources by count.

### 2. The Size Estimation (Drill-Down)
If the DB size is high, but the object counts look normal, you need to check if specific objects are unusually large.

    ./ocp-etcd-audit.sh -s

**What happens:**
* The script calculates the counts as usual.
* For the displayed items, it estimates the size based on the API JSON output.
* *Goal:* Identify "heavy" objects (e.g., huge CRDs or ConfigMaps) that don't appear in the top count list.

### 3. The Proof (Exact Measurement)
You suspect a specific resource (e.g., `apirequestcounts` or `secrets`) is the culprit. You want the raw truth from the storage layer without scanning the whole DB.

    ./ocp-etcd-audit.sh -e secrets

**What happens:**
* The script identifies the exact storage path in ETCD for this resource.
* It calculates the raw Protobuf size of that specific key prefix directly from the DB.
* *Goal:* Confirm the physical footprint of a specific resource.

### 4. Forensic Mode (The Deep Scan)
**⚠️ Use with Caution**

If the issue remains a mystery and the numbers don't add up, you can perform a full forensic audit. This will map every API resource to its physical storage path and measure the exact size on disk.

    ./ocp-etcd-audit.sh --forensic

* **Safety First:** This mode ignores `-y`. You must manually type `confirm` to proceed.
* **Throttling:** To protect the cluster from I/O saturation, the script sleeps by default for 1 second between checks. You can adjust this with `--throttle`.
* **Output:** A complete table comparing **API Count**, **ETCD Key Count**, and **Real Storage Size**.

---

## ⚖️ License & Authors

This project is licensed under the MIT License.

**Authors:**
* **Chris Tawfik** (ctawfik@redhat.com)
* **toughIQ** (toughiq@gmail.com)

*Developed with support from Gemini AI.*
