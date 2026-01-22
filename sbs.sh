#!/bin/bash

SBS_VERSION="v2025.11-optimized"

# Display banner
echo -e '# ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## #'
echo -e '#              Simple-Bench-Script              #'
echo -e '#                     '$SBS_VERSION'            #'
echo -e '# ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## #'

echo -e
date
TIME_START=$(date '+%Y%m%d-%H%M%S')
SBS_START_TIME=$(date +%s)

# Set locale
if locale -a 2>/dev/null | grep ^C$ > /dev/null; then
	export LC_ALL=C
else
	echo -e "\nWarning: locale 'C' not detected. Test outputs may not be parsed correctly."
fi

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
	x86_64) ARCH="x64" ;;
	i?86) ARCH="x86" ;;
	aarch*|arm*)
		KERNEL_BIT=$(getconf LONG_BIT)
		if [[ $KERNEL_BIT == *64* ]]; then
			ARCH="aarch64"
		else
			ARCH="arm"
		fi
		echo -e "\nARM compatibility is considered *experimental*"
		;;
	*)
		echo -e "Architecture not supported by SBS."
		exit 1
		;;
esac

# Parse command line flags
unset SKIP_FIO SKIP_SYSBENCH_CPU SKIP_SYSBENCH_MEM PRINT_HELP SAVE_REPORT
while getopts 'cdmsh' flag; do
	case "${flag}" in
		c) SKIP_SYSBENCH_CPU="True" ;;
		d) SKIP_FIO="True" ;;
		m) SKIP_SYSBENCH_MEM="True" ;;
		s) SAVE_REPORT="True" ;;
		h) PRINT_HELP="True" ;;
		*) exit 1 ;;
	esac
done

# Check for required binaries
command -v fio >/dev/null 2>&1 && LOCAL_FIO=true || unset LOCAL_FIO
command -v sysbench >/dev/null 2>&1 && LOCAL_SYSBENCH=true || unset LOCAL_SYSBENCH

# Print help if requested
if [ ! -z "$PRINT_HELP" ]; then
	echo -e
	echo -e "Usage: ./sbs.sh [-flags]"
	echo -e
	echo -e "Flags:"
	echo -e "       -c : skip CPU benchmark test"
	echo -e "       -d : skip disk benchmark test"
	echo -e "       -m : skip memory benchmark test"
	echo -e "       -s : save report to file in current directory"
	echo -e "       -h : print help message"
	echo -e
	echo -e "Detected Arch: $ARCH"
	echo -e
	echo -e "Detected Flags:"
	[[ ! -z $SKIP_FIO ]] && echo -e "       -d, skipping disk benchmark test"
	[[ ! -z $SKIP_SYSBENCH_CPU ]] && echo -e "       -c, skipping CPU benchmark test"
	[[ ! -z $SKIP_SYSBENCH_MEM ]] && echo -e "       -m, skipping memory benchmark test"
	echo -e
	echo -e "Local Binary Check:"
	[[ -z $LOCAL_FIO ]] && echo -e "       fio not detected" || echo -e "       fio detected"
	[[ -z $LOCAL_SYSBENCH ]] && echo -e "       sysbench not detected" || echo -e "       sysbench detected"
	echo -e
	echo -e "Exiting..."
	exit 0
fi

# Check for required dependencies
MISSING_DEPS=0
if [[ -z "$LOCAL_FIO" && -z "$SKIP_FIO" ]]; then
	echo -e "\nError: fio is not installed but disk benchmarks are enabled."
	echo -e "Please install fio or use -d flag to skip disk tests."
	echo -e "Install: apt install fio  (Debian/Ubuntu)"
	echo -e "         yum install fio  (RHEL/CentOS)"
	echo -e "         brew install fio (macOS)"
	MISSING_DEPS=1
fi

if [[ -z "$LOCAL_SYSBENCH" && (-z "$SKIP_SYSBENCH_CPU" || -z "$SKIP_SYSBENCH_MEM") ]]; then
	echo -e "\nError: sysbench is not installed but CPU/Memory benchmarks are enabled."
	echo -e "Please install sysbench or use -c/-m flags to skip CPU/memory tests."
	echo -e "Install: apt install sysbench  (Debian/Ubuntu)"
	echo -e "         yum install sysbench  (RHEL/CentOS)"
	echo -e "         brew install sysbench (macOS)"
	MISSING_DEPS=1
fi

if [ $MISSING_DEPS -eq 1 ]; then
	echo -e "\nExiting due to missing dependencies...\n"
	exit 1
fi

# Format size in human readable format
function format_size {
	RAW=$1
	RESULT=$RAW
	local DENOM=1
	local UNIT="KiB"

	re='^[0-9]+$'
	if ! [[ $RAW =~ $re ]] ; then
		echo ""
		return 0
	fi

	if [ "$RAW" -ge 1073741824 ]; then
		DENOM=1073741824
		UNIT="TiB"
	elif [ "$RAW" -ge 1048576 ]; then
		DENOM=1048576
		UNIT="GiB"
	elif [ "$RAW" -ge 1024 ]; then
		DENOM=1024
		UNIT="MiB"
	fi

	RESULT=$(awk -v a="$RESULT" -v b="$DENOM" 'BEGIN { print a / b }')
	RESULT=$(echo $RESULT | awk -F. '{ printf "%0.1f",$1"."substr($2,1,2) }')
	RESULT="$RESULT $UNIT"
	echo $RESULT
}

# Format speed in human readable format
function format_speed {
	RAW=$1
	RESULT=$RAW
	local DENOM=1
	local UNIT="KB/s"

	if [ -z "$RAW" ]; then
		echo ""
		return 0
	fi

	if [ "$RAW" -ge 1000000 ]; then
		DENOM=1000000
		UNIT="GB/s"
	elif [ "$RAW" -ge 1000 ]; then
		DENOM=1000
		UNIT="MB/s"
	fi

	RESULT=$(awk -v a="$RESULT" -v b="$DENOM" 'BEGIN { print a / b }')
	RESULT=$(echo $RESULT | awk -F. '{ printf "%0.2f",$1"."substr($2,1,2) }')
	RESULT="$RESULT $UNIT"
	echo $RESULT
}

# Format IOPS in human readable format
function format_iops {
	RAW=$1
	RESULT=$RAW

	if [ -z "$RAW" ]; then
		echo ""
		return 0
	fi

	if [ "$RAW" -ge 1000 ]; then
		RESULT=$(awk -v a="$RESULT" 'BEGIN { print a / 1000 }')
		RESULT=$(echo $RESULT | awk -F. '{ printf "%0.1f",$1"."substr($2,1,1) }')
		RESULT="$RESULT"k
	fi

	echo $RESULT
}

# Get CPU information (unified for x86/ARM)
function get_cpu_info {
	if [[ $ARCH = *aarch64* || $ARCH = *arm* ]]; then
		CPU_PROC=$(lscpu | grep "Model name" | sed 's/Model name: *//g')
		CPU_CORES=$(lscpu | grep "^[[:blank:]]*CPU(s):" | sed 's/CPU(s): *//g')
		CPU_FREQ=$(lscpu | grep "CPU max MHz" | sed 's/CPU max MHz: *//g')
		[[ -z "$CPU_FREQ" ]] && CPU_FREQ="???"
		CPU_FREQ="${CPU_FREQ} MHz"
	else
		CPU_PROC=$(awk -F: '/model name/ {name=$2} END {print name}' /proc/cpuinfo | sed 's/^[ \t]*//;s/[ \t]*$//')
		CPU_CORES=$(awk -F: '/model name/ {core++} END {print core}' /proc/cpuinfo)
		CPU_FREQ=$(awk -F: ' /cpu MHz/ {freq=$2} END {print freq " MHz"}' /proc/cpuinfo | sed 's/^[ \t]*//;s/[ \t]*$//')
	fi
}

# Initialize report variables
REPORT_FILE=""
declare -A REPORT_DATA

# Add data to report
function add_to_report {
	local key="$1"
	local value="$2"
	REPORT_DATA["$key"]="$value"
}

# Gather system information
echo -e
echo -e "Basic System Information:"
echo -e "---------------------------------"

UPTIME=$(uptime | awk -F'( |,|:)+' '{d=h=m=0; if ($7=="min") m=$6; else {if ($7~/^day/) {d=$6;h=$8;m=$9} else {h=$6;m=$7}}} {print d+0," days,",h+0," hours,",m+0," minutes"}')
echo -e "Uptime     : $UPTIME"
add_to_report "uptime" "$UPTIME"

get_cpu_info
echo -e "Processor  : $CPU_PROC"
echo -e "CPU cores  : $CPU_CORES @ $CPU_FREQ"
add_to_report "cpu_model" "$CPU_PROC"
add_to_report "cpu_cores" "$CPU_CORES"
add_to_report "cpu_freq" "$CPU_FREQ"

CPU_AES=$(cat /proc/cpuinfo | grep aes)
[[ -z "$CPU_AES" ]] && CPU_AES="❌ Disabled" || CPU_AES="✔ Enabled"
echo -e "AES-NI     : $CPU_AES"
add_to_report "aes_ni" "$CPU_AES"

CPU_VIRT=$(cat /proc/cpuinfo | grep 'vmx\|svm')
[[ -z "$CPU_VIRT" ]] && CPU_VIRT="❌ Disabled" || CPU_VIRT="✔ Enabled"
echo -e "VM-x/AMD-V : $CPU_VIRT"
add_to_report "virtualization" "$CPU_VIRT"

TOTAL_RAM_RAW=$(free | awk 'NR==2 {print $2}')
TOTAL_RAM=$(format_size $TOTAL_RAM_RAW)
echo -e "RAM        : $TOTAL_RAM"
add_to_report "ram" "$TOTAL_RAM"

TOTAL_SWAP_RAW=$(free | grep Swap | awk '{ print $2 }')
TOTAL_SWAP=$(format_size $TOTAL_SWAP_RAW)
echo -e "Swap       : $TOTAL_SWAP"
add_to_report "swap" "$TOTAL_SWAP"

TOTAL_DISK_RAW=$(df -t simfs -t ext2 -t ext3 -t ext4 -t btrfs -t xfs -t vfat -t ntfs -t swap --total 2>/dev/null | grep total | awk '{ print $2 }')
TOTAL_DISK=$(format_size $TOTAL_DISK_RAW)
echo -e "Disk       : $TOTAL_DISK"
add_to_report "disk" "$TOTAL_DISK"

DISTRO=$(grep 'PRETTY_NAME' /etc/os-release 2>/dev/null | cut -d '"' -f 2)
[[ -z "$DISTRO" ]] && DISTRO="Unknown"
echo -e "Distro     : $DISTRO"
add_to_report "distro" "$DISTRO"

KERNEL=$(uname -r)
echo -e "Kernel     : $KERNEL"
add_to_report "kernel" "$KERNEL"

VIRT=$(systemd-detect-virt 2>/dev/null)
VIRT=${VIRT^^}
[[ -z "$VIRT" ]] && VIRT="UNKNOWN"
echo -e "VM Type    : $VIRT"
add_to_report "vm_type" "$VIRT"

# Setup working directory
DATE=$(date -Iseconds | sed -e "s/:/_/g")
SBS_PATH=./$DATE
touch "$DATE.test" 2> /dev/null
if [ ! -f "$DATE.test" ]; then
	echo -e
	echo -e "You do not have write permission in this directory. Switch to an owned directory and re-run the script.\nExiting..."
	exit 1
fi
rm "$DATE.test"
mkdir -p "$SBS_PATH"

# Setup trap for cleanup
trap catch_abort INT

function catch_abort() {
	echo -e "\n** Aborting SBS. Cleaning up files...\n"
	rm -rf "$SBS_PATH"
	unset LC_ALL
	exit 0
}

# Disk test function
function disk_test {
	if [[ "$ARCH" = "aarch64" || "$ARCH" = "arm" ]]; then
		FIO_SIZE=512M
	else
		FIO_SIZE=2G
	fi

	echo -en "Generating fio test file..."
	fio --name=setup --ioengine=libaio --rw=read --bs=64k --iodepth=64 --numjobs=2 --size=$FIO_SIZE --runtime=1 --gtod_reduce=1 --filename="$DISK_PATH/test.fio" --direct=1 --minimal &> /dev/null
	echo -en "\r\033[0K"

	BLOCK_SIZES=("$@")

	for BS in "${BLOCK_SIZES[@]}"; do
		echo -en "Running fio random mixed R+W disk test with $BS block size..."
		DISK_TEST=$(timeout 35 fio --name=rand_rw_$BS --ioengine=libaio --rw=randrw --rwmixread=50 --bs=$BS --iodepth=64 --numjobs=2 --size=$FIO_SIZE --runtime=30 --gtod_reduce=1 --direct=1 --filename="$DISK_PATH/test.fio" --group_reporting --minimal 2> /dev/null | grep rand_rw_$BS)
		DISK_IOPS_R=$(echo $DISK_TEST | awk -F';' '{print $8}')
		DISK_IOPS_W=$(echo $DISK_TEST | awk -F';' '{print $49}')
		DISK_IOPS=$(awk -v a="$DISK_IOPS_R" -v b="$DISK_IOPS_W" 'BEGIN { print a + b }')
		DISK_TEST_R=$(echo $DISK_TEST | awk -F';' '{print $7}')
		DISK_TEST_W=$(echo $DISK_TEST | awk -F';' '{print $48}')
		DISK_TEST=$(awk -v a="$DISK_TEST_R" -v b="$DISK_TEST_W" 'BEGIN { print a + b }')
		DISK_RESULTS_RAW+=( "$DISK_TEST" "$DISK_TEST_R" "$DISK_TEST_W" "$DISK_IOPS" "$DISK_IOPS_R" "$DISK_IOPS_W" )

		DISK_IOPS=$(format_iops $DISK_IOPS)
		DISK_IOPS_R=$(format_iops $DISK_IOPS_R)
		DISK_IOPS_W=$(format_iops $DISK_IOPS_W)
		DISK_TEST=$(format_speed $DISK_TEST)
		DISK_TEST_R=$(format_speed $DISK_TEST_R)
		DISK_TEST_W=$(format_speed $DISK_TEST_W)

		DISK_RESULTS+=( "$DISK_TEST" "$DISK_TEST_R" "$DISK_TEST_W" "$DISK_IOPS" "$DISK_IOPS_R" "$DISK_IOPS_W" )
		echo -en "\r\033[0K"
	done
}

# Check disk space and run disk tests
AVAIL_SPACE=$(df -k . | awk 'NR==2{print $4}')
if [[ -z "$SKIP_FIO" && "$AVAIL_SPACE" -lt 2097152 && "$ARCH" != "aarch64" && "$ARCH" != "arm" ]]; then
	echo -e "\nLess than 2GB of space available. Skipping disk test..."
	SKIP_FIO="True"
elif [[ -z "$SKIP_FIO" && "$AVAIL_SPACE" -lt 524288 && ("$ARCH" = "aarch64" || "$ARCH" = "arm") ]]; then
	echo -e "\nLess than 512MB of space available. Skipping disk test..."
	SKIP_FIO="True"
fi

if [ -z "$SKIP_FIO" ]; then
	# Simplified ZFS check - just warn if on ZFS with low space
	if [[ -f "/sys/module/zfs/parameters/spa_asize_inflation" ]]; then
		CURRENT_PATH_FS=$(df -Th . | awk 'NR==2 {print $2}')
		if [[ "$CURRENT_PATH_FS" == "zfs" ]]; then
			FREE_SPACE_GB=$(df -BG . | awk 'NR==2 {print $4}' | sed 's/G//')
			MIN_REQUIRED=$(cat /sys/module/zfs/parameters/spa_asize_inflation)
			MIN_REQUIRED=$((MIN_REQUIRED * 2))
			if [[ $FREE_SPACE_GB -lt $MIN_REQUIRED ]]; then
				echo -en "\nWarning: Running on ZFS with limited space. Disk test results may be affected.\n"
			fi
		fi
	fi

	echo -en "\nPreparing system for disk tests..."

	DISK_PATH=$SBS_PATH/disk
	mkdir -p "$DISK_PATH"

	echo -en "\r\033[0K"

	declare -a DISK_RESULTS DISK_RESULTS_RAW
	BLOCK_SIZES=( "4k" "64k" "512k" "1m" )

	disk_test "${BLOCK_SIZES[@]}"

	# Display disk test results
	if [[ ${#DISK_RESULTS[@]} -gt 0 ]]; then
		CURRENT_PARTITION=$(df -P . 2>/dev/null | tail -1 | cut -d' ' -f 1)

		echo -e "fio Disk Speed Tests (Mixed R/W 50/50) (Partition $CURRENT_PARTITION):"
		echo -e "---------------------------------"

		add_to_report "disk_test_type" "fio"
		add_to_report "disk_partition" "$CURRENT_PARTITION"

		# Display all 4 block sizes (4k, 64k, 512k, 1m)
		echo -e ""
		printf "%-10s | %-20s | %-20s\n" "Block Size" "4k" "64k"
		printf "%-10s | %-11s %8s | %-11s %8s\n" "  ------" "---" "---- " "----" "---- "
		printf "%-10s | %-11s %8s | %-11s %8s\n" "Read" "${DISK_RESULTS[1]}" "(${DISK_RESULTS[4]})" "${DISK_RESULTS[7]}" "(${DISK_RESULTS[10]})"
		printf "%-10s | %-11s %8s | %-11s %8s\n" "Write" "${DISK_RESULTS[2]}" "(${DISK_RESULTS[5]})" "${DISK_RESULTS[8]}" "(${DISK_RESULTS[11]})"
		printf "%-10s | %-11s %8s | %-11s %8s\n" "Total" "${DISK_RESULTS[0]}" "(${DISK_RESULTS[3]})" "${DISK_RESULTS[6]}" "(${DISK_RESULTS[9]})"

		echo -e ""
		printf "%-10s | %-20s | %-20s\n" "Block Size" "512k" "1m"
		printf "%-10s | %-11s %8s | %-11s %8s\n" "  ------" "---" "---- " "----" "---- "
		printf "%-10s | %-11s %8s | %-11s %8s\n" "Read" "${DISK_RESULTS[13]}" "(${DISK_RESULTS[16]})" "${DISK_RESULTS[19]}" "(${DISK_RESULTS[22]})"
		printf "%-10s | %-11s %8s | %-11s %8s\n" "Write" "${DISK_RESULTS[14]}" "(${DISK_RESULTS[17]})" "${DISK_RESULTS[20]}" "(${DISK_RESULTS[23]})"
		printf "%-10s | %-11s %8s | %-11s %8s\n" "Total" "${DISK_RESULTS[12]}" "(${DISK_RESULTS[15]})" "${DISK_RESULTS[18]}" "(${DISK_RESULTS[21]})"

		# Store all block size results in report
		add_to_report "disk_4k_read" "${DISK_RESULTS[1]} (${DISK_RESULTS[4]} IOPS)"
		add_to_report "disk_4k_write" "${DISK_RESULTS[2]} (${DISK_RESULTS[5]} IOPS)"
		add_to_report "disk_4k_total" "${DISK_RESULTS[0]} (${DISK_RESULTS[3]} IOPS)"

		add_to_report "disk_64k_read" "${DISK_RESULTS[7]} (${DISK_RESULTS[10]} IOPS)"
		add_to_report "disk_64k_write" "${DISK_RESULTS[8]} (${DISK_RESULTS[11]} IOPS)"
		add_to_report "disk_64k_total" "${DISK_RESULTS[6]} (${DISK_RESULTS[9]} IOPS)"

		add_to_report "disk_512k_read" "${DISK_RESULTS[13]} (${DISK_RESULTS[16]} IOPS)"
		add_to_report "disk_512k_write" "${DISK_RESULTS[14]} (${DISK_RESULTS[17]} IOPS)"
		add_to_report "disk_512k_total" "${DISK_RESULTS[12]} (${DISK_RESULTS[15]} IOPS)"

		add_to_report "disk_1m_read" "${DISK_RESULTS[19]} (${DISK_RESULTS[22]} IOPS)"
		add_to_report "disk_1m_write" "${DISK_RESULTS[20]} (${DISK_RESULTS[23]} IOPS)"
		add_to_report "disk_1m_total" "${DISK_RESULTS[18]} (${DISK_RESULTS[21]} IOPS)"
	else
		echo -e "\nError: fio disk tests failed. Please check your disk and try again.\n"
	fi
fi

# CPU benchmark
function launch_sysbench_cpu {
	CPU_CORES=$(lscpu | grep "^[[:blank:]]*CPU(s):" | sed 's/CPU(s): *//g')
	sysbench cpu --threads=$CPU_CORES run
}

# Memory benchmark
function launch_sysbench_mem {
	CPU_CORES=$(lscpu | grep "^[[:blank:]]*CPU(s):" | sed 's/CPU(s): *//g')
	sysbench memory --threads=$CPU_CORES run
}

# Run CPU benchmark
if [ -z "$SKIP_SYSBENCH_CPU" ]; then
	echo -e
	echo -e "CPU Benchmark Test:"
	echo -e "---------------------------------"
	CPU_RESULT=$(launch_sysbench_cpu 2>&1)
	echo "$CPU_RESULT"

	# Extract CPU benchmark score
	CPU_EVENTS=$(echo "$CPU_RESULT" | grep "events per second:" | awk '{print $4}')
	CPU_TIME=$(echo "$CPU_RESULT" | grep "total time:" | awk '{print $3}')
	[[ ! -z "$CPU_EVENTS" ]] && add_to_report "cpu_events_per_sec" "$CPU_EVENTS"
	[[ ! -z "$CPU_TIME" ]] && add_to_report "cpu_total_time" "$CPU_TIME"
fi

# Run memory benchmark
if [ -z "$SKIP_SYSBENCH_MEM" ]; then
	echo -e
	echo -e "Memory Benchmark Test:"
	echo -e "---------------------------------"
	MEM_RESULT=$(launch_sysbench_mem 2>&1)
	echo "$MEM_RESULT"

	# Extract memory benchmark score
	MEM_SPEED=$(echo "$MEM_RESULT" | grep "MiB/sec" | tail -1 | awk '{print $(NF-1) " " $NF}')
	MEM_TIME=$(echo "$MEM_RESULT" | grep "total time:" | awk '{print $3}')
	[[ ! -z "$MEM_SPEED" ]] && add_to_report "mem_speed" "$MEM_SPEED"
	[[ ! -z "$MEM_TIME" ]] && add_to_report "mem_total_time" "$MEM_TIME"
fi

# Generate report
if [ ! -z "$SAVE_REPORT" ]; then
	REPORT_FILE="benchmark_report_${TIME_START}.txt"
	echo -e "\n================================================" | tee "$REPORT_FILE"
else
	echo -e "\n================================================"
fi

if [ ! -z "$SAVE_REPORT" ]; then
	echo -e "        BENCHMARK REPORT SUMMARY" | tee -a "$REPORT_FILE"
	echo -e "================================================" | tee -a "$REPORT_FILE"
	echo -e "Generated: $(date)" | tee -a "$REPORT_FILE"
	echo -e "Version: $SBS_VERSION" | tee -a "$REPORT_FILE"
	echo -e "" | tee -a "$REPORT_FILE"

	echo -e "SYSTEM INFORMATION" | tee -a "$REPORT_FILE"
	echo -e "------------------" | tee -a "$REPORT_FILE"
	echo -e "CPU Model    : ${REPORT_DATA[cpu_model]}" | tee -a "$REPORT_FILE"
	echo -e "CPU Cores    : ${REPORT_DATA[cpu_cores]}" | tee -a "$REPORT_FILE"
	echo -e "CPU Freq     : ${REPORT_DATA[cpu_freq]}" | tee -a "$REPORT_FILE"
	echo -e "RAM          : ${REPORT_DATA[ram]}" | tee -a "$REPORT_FILE"
	echo -e "Disk         : ${REPORT_DATA[disk]}" | tee -a "$REPORT_FILE"
	echo -e "OS           : ${REPORT_DATA[distro]}" | tee -a "$REPORT_FILE"
	echo -e "Kernel       : ${REPORT_DATA[kernel]}" | tee -a "$REPORT_FILE"
	echo -e "Virtualization: ${REPORT_DATA[vm_type]}" | tee -a "$REPORT_FILE"
	echo -e "" | tee -a "$REPORT_FILE"
else
	echo -e "        BENCHMARK REPORT SUMMARY"
	echo -e "================================================"
	echo -e "Generated: $(date)"
	echo -e "Version: $SBS_VERSION"
	echo -e ""

	echo -e "SYSTEM INFORMATION"
	echo -e "------------------"
	echo -e "CPU Model    : ${REPORT_DATA[cpu_model]}"
	echo -e "CPU Cores    : ${REPORT_DATA[cpu_cores]}"
	echo -e "CPU Freq     : ${REPORT_DATA[cpu_freq]}"
	echo -e "RAM          : ${REPORT_DATA[ram]}"
	echo -e "Disk         : ${REPORT_DATA[disk]}"
	echo -e "OS           : ${REPORT_DATA[distro]}"
	echo -e "Kernel       : ${REPORT_DATA[kernel]}"
	echo -e "Virtualization: ${REPORT_DATA[vm_type]}"
	echo -e ""
fi

if [[ ! -z "${REPORT_DATA[cpu_events_per_sec]}" ]]; then
	if [ ! -z "$SAVE_REPORT" ]; then
		echo -e "CPU BENCHMARK" | tee -a "$REPORT_FILE"
		echo -e "-------------" | tee -a "$REPORT_FILE"
		echo -e "Events/sec   : ${REPORT_DATA[cpu_events_per_sec]}" | tee -a "$REPORT_FILE"
		echo -e "Total time   : ${REPORT_DATA[cpu_total_time]}" | tee -a "$REPORT_FILE"
		echo -e "" | tee -a "$REPORT_FILE"
	else
		echo -e "CPU BENCHMARK"
		echo -e "-------------"
		echo -e "Events/sec   : ${REPORT_DATA[cpu_events_per_sec]}"
		echo -e "Total time   : ${REPORT_DATA[cpu_total_time]}"
		echo -e ""
	fi
fi

if [[ ! -z "${REPORT_DATA[mem_speed]}" ]]; then
	if [ ! -z "$SAVE_REPORT" ]; then
		echo -e "MEMORY BENCHMARK" | tee -a "$REPORT_FILE"
		echo -e "----------------" | tee -a "$REPORT_FILE"
		echo -e "Speed        : ${REPORT_DATA[mem_speed]}" | tee -a "$REPORT_FILE"
		echo -e "Total time   : ${REPORT_DATA[mem_total_time]}" | tee -a "$REPORT_FILE"
		echo -e "" | tee -a "$REPORT_FILE"
	else
		echo -e "MEMORY BENCHMARK"
		echo -e "----------------"
		echo -e "Speed        : ${REPORT_DATA[mem_speed]}"
		echo -e "Total time   : ${REPORT_DATA[mem_total_time]}"
		echo -e ""
	fi
fi

if [[ ! -z "${REPORT_DATA[disk_test_type]}" ]]; then
	if [ ! -z "$SAVE_REPORT" ]; then
		echo -e "DISK BENCHMARK (fio)" | tee -a "$REPORT_FILE"
		echo -e "--------------" | tee -a "$REPORT_FILE"
		echo -e "Partition    : ${REPORT_DATA[disk_partition]}" | tee -a "$REPORT_FILE"
		for bs in "4k" "64k" "512k" "1m"; do
			if [[ ! -z "${REPORT_DATA[disk_${bs}_read]}" ]]; then
				echo -e "" | tee -a "$REPORT_FILE"
				echo -e "Block Size: $bs" | tee -a "$REPORT_FILE"
				echo -e "  Read     : ${REPORT_DATA[disk_${bs}_read]}" | tee -a "$REPORT_FILE"
				echo -e "  Write    : ${REPORT_DATA[disk_${bs}_write]}" | tee -a "$REPORT_FILE"
				echo -e "  Total    : ${REPORT_DATA[disk_${bs}_total]}" | tee -a "$REPORT_FILE"
			fi
		done
		echo -e "" | tee -a "$REPORT_FILE"
	else
		echo -e "DISK BENCHMARK (fio)"
		echo -e "--------------"
		echo -e "Partition    : ${REPORT_DATA[disk_partition]}"
		for bs in "4k" "64k" "512k" "1m"; do
			if [[ ! -z "${REPORT_DATA[disk_${bs}_read]}" ]]; then
				echo -e ""
				echo -e "Block Size: $bs"
				echo -e "  Read     : ${REPORT_DATA[disk_${bs}_read]}"
				echo -e "  Write    : ${REPORT_DATA[disk_${bs}_write]}"
				echo -e "  Total    : ${REPORT_DATA[disk_${bs}_total]}"
			fi
		done
		echo -e ""
	fi
fi

if [ ! -z "$SAVE_REPORT" ]; then
	echo -e "================================================" | tee -a "$REPORT_FILE"
else
	echo -e "================================================"
fi

# Cleanup
echo -e
rm -rf "$SBS_PATH"

SBS_END_TIME=$(date +%s)

# Calculate and display time taken
function calculate_time_taken() {
	end_time=$1
	start_time=$2

	time_taken=$(( ${end_time} - ${start_time} ))
	if [ ${time_taken} -gt 60 ]; then
		min=$(expr $time_taken / 60)
		sec=$(expr $time_taken % 60)
		echo "SBS completed in ${min} min ${sec} sec"
	else
		echo "SBS completed in ${time_taken} sec"
	fi
}

TIME_MSG=$(calculate_time_taken $SBS_END_TIME $SBS_START_TIME)
echo "$TIME_MSG"

if [ ! -z "$SAVE_REPORT" ]; then
	echo "" >> "$REPORT_FILE"
	echo "$TIME_MSG" >> "$REPORT_FILE"
	echo "" >> "$REPORT_FILE"
	echo "Full report saved to: $REPORT_FILE"
fi

unset LC_ALL
