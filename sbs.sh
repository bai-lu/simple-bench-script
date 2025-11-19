#!/bin/bash

SBS_VERSION="v2024-01-01"

echo -e '# ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## #'
echo -e '#              Simple-Bench-Script              #'
echo -e '#                     '$SBS_VERSION'                    #'
echo -e '# ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## #'

echo -e
date
TIME_START=$(date '+%Y%m%d-%H%M%S')
SBS_START_TIME=$(date +%s)

if locale -a 2>/dev/null | grep ^C$ > /dev/null; then
	export LC_ALL=C
else
	echo -e "\nWarning: locale 'C' not detected. Test outputs may not be parsed correctly."
fi

ARCH=$(uname -m)
if [[ $ARCH = *x86_64* ]]; then
	ARCH="x64"
elif [[ $ARCH = *i?86* ]]; then
	ARCH="x86"
elif [[ $ARCH = *aarch* || $ARCH = *arm* ]]; then
	KERNEL_BIT=$(getconf LONG_BIT)
	if [[ $KERNEL_BIT = *64* ]]; then
		ARCH="aarch64"
	else
		ARCH="arm"
	fi
	echo -e "\nARM compatibility is considered *experimental*"
else
	echo -e "Architecture not supported by SBS."
	exit 1
fi

unset SKIP_FIO SKIP_SYSBENCH_CPU SKIP_SYSBENCH_MEM PRINT_HELP

while getopts 'cdmh' flag; do
	case "${flag}" in
		c) SKIP_SYSBENCH_CPU="True" ;;
		d) SKIP_FIO="True" ;;
		m) SKIP_SYSBENCH_MEM="True" ;;
		h) PRINT_HELP="True" ;;
		*) exit 1 ;;
	esac
done

command -v fio >/dev/null 2>&1 && LOCAL_FIO=true || unset LOCAL_FIO
command -v sysbench >/dev/null 2>&1 && LOCAL_SYSBENCH=true || unset LOCAL_SYSBENCH

if [ ! -z "$PRINT_HELP" ]; then
	echo -e
	echo -e "Usage: ./sbs.sh [-flags]"
	echo -e
	echo -e "Flags:"
	echo -e "       -c : skip CPU benchmark test"
	echo -e "       -d : skip disk benchmark test"
	echo -e "       -m : skip memory benchmark test"
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

echo -e
echo -e "Basic System Information:"
echo -e "---------------------------------"
UPTIME=$(uptime | awk -F'( |,|:)+' '{d=h=m=0; if ($7=="min") m=$6; else {if ($7~/^day/) {d=$6;h=$8;m=$9} else {h=$6;m=$7}}} {print d+0,"days,",h+0,"hours,",m+0,"minutes"}')
echo -e "Uptime     : $UPTIME"
if [[ $ARCH = *aarch64* || $ARCH = *arm* ]]; then
	CPU_PROC=$(lscpu | grep "Model name" | sed 's/Model name: *//g')
else
	CPU_PROC=$(awk -F: '/model name/ {name=$2} END {print name}' /proc/cpuinfo | sed 's/^[ \t]*//;s/[ \t]*$//')
fi
echo -e "Processor  : $CPU_PROC"
if [[ $ARCH = *aarch64* || $ARCH = *arm* ]]; then
	CPU_CORES=$(lscpu | grep "^[[:blank:]]*CPU(s):" | sed 's/CPU(s): *//g')
	CPU_FREQ=$(lscpu | grep "CPU max MHz" | sed 's/CPU max MHz: *//g')
	[[ -z "$CPU_FREQ" ]] && CPU_FREQ="???"
	CPU_FREQ="${CPU_FREQ} MHz"
else
	CPU_CORES=$(awk -F: '/model name/ {core++} END {print core}' /proc/cpuinfo)
	CPU_FREQ=$(awk -F: ' /cpu MHz/ {freq=$2} END {print freq " MHz"}' /proc/cpuinfo | sed 's/^[ \t]*//;s/[ \t]*$//')
fi
echo -e "CPU cores  : $CPU_CORES @ $CPU_FREQ"
CPU_AES=$(cat /proc/cpuinfo | grep aes)
[[ -z "$CPU_AES" ]] && CPU_AES="\xE2\x9D\x8C Disabled" || CPU_AES="\xE2\x9C\x94 Enabled"
echo -e "AES-NI     : $CPU_AES"
CPU_VIRT=$(cat /proc/cpuinfo | grep 'vmx\|svm')
[[ -z "$CPU_VIRT" ]] && CPU_VIRT="\xE2\x9D\x8C Disabled" || CPU_VIRT="\xE2\x9C\x94 Enabled"
echo -e "VM-x/AMD-V : $CPU_VIRT"
TOTAL_RAM_RAW=$(free | awk 'NR==2 {print $2}')
TOTAL_RAM=$(format_size $TOTAL_RAM_RAW)
echo -e "RAM        : $TOTAL_RAM"
TOTAL_SWAP_RAW=$(free | grep Swap | awk '{ print $2 }')
TOTAL_SWAP=$(format_size $TOTAL_SWAP_RAW)
echo -e "Swap       : $TOTAL_SWAP"
TOTAL_DISK_RAW=$(df -t simfs -t ext2 -t ext3 -t ext4 -t btrfs -t xfs -t vfat -t ntfs -t swap --total 2>/dev/null | grep total | awk '{ print $2 }')
TOTAL_DISK=$(format_size $TOTAL_DISK_RAW)
echo -e "Disk       : $TOTAL_DISK"
DISTRO=$(grep 'PRETTY_NAME' /etc/os-release | cut -d '"' -f 2 )
echo -e "Distro     : $DISTRO"
KERNEL=$(uname -r)
echo -e "Kernel     : $KERNEL"
VIRT=$(systemd-detect-virt 2>/dev/null)
VIRT=${VIRT^^} || VIRT="UNKNOWN"
echo -e "VM Type    : $VIRT"

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

trap catch_abort INT

function catch_abort() {
	echo -e "\n** Aborting SBS. Cleaning up files...\n"
	rm -rf "$SBS_PATH"
	unset LC_ALL
	exit 0
}

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

function disk_test {
	if [[ "$ARCH" = "aarch64" || "$ARCH" = "arm" ]]; then
		FIO_SIZE=512M
	else
		FIO_SIZE=2G
	fi

	echo -en "Generating fio test file..."
	$FIO_CMD --name=setup --ioengine=libaio --rw=read --bs=64k --iodepth=64 --numjobs=2 --size=$FIO_SIZE --runtime=1 --gtod_reduce=1 --filename="$DISK_PATH/test.fio" --direct=1 --minimal &> /dev/null
	echo -en "\r\033[0K"

	BLOCK_SIZES=("$@")

	for BS in "${BLOCK_SIZES[@]}"; do
		echo -en "Running fio random mixed R+W disk test with $BS block size..."
		DISK_TEST=$(timeout 35 $FIO_CMD --name=rand_rw_$BS --ioengine=libaio --rw=randrw --rwmixread=50 --bs=$BS --iodepth=64 --numjobs=2 --size=$FIO_SIZE --runtime=30 --gtod_reduce=1 --direct=1 --filename="$DISK_PATH/test.fio" --group_reporting --minimal 2> /dev/null | grep rand_rw_$BS)
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

function dd_test {
	I=0
	DISK_WRITE_TEST_RES=()
	DISK_READ_TEST_RES=()
	DISK_WRITE_TEST_AVG=0
	DISK_READ_TEST_AVG=0

	while [ $I -lt 3 ]
	do
		DISK_WRITE_TEST=$(dd if=/dev/zero of="$DISK_PATH/$DATE.test" bs=64k count=16k oflag=direct |& grep copied | awk '{ print $(NF-1) " " $(NF)}')
		VAL=$(echo $DISK_WRITE_TEST | cut -d " " -f 1)
		[[ "$DISK_WRITE_TEST" == *"GB"* ]] && VAL=$(awk -v a="$VAL" 'BEGIN { print a * 1000 }')
		DISK_WRITE_TEST_RES+=( "$DISK_WRITE_TEST" )
		DISK_WRITE_TEST_AVG=$(awk -v a="$DISK_WRITE_TEST_AVG" -v b="$VAL" 'BEGIN { print a + b }')

		DISK_READ_TEST=$(dd if="$DISK_PATH/$DATE.test" of=/dev/null bs=8k |& grep copied | awk '{ print $(NF-1) " " $(NF)}')
		VAL=$(echo $DISK_READ_TEST | cut -d " " -f 1)
		[[ "$DISK_READ_TEST" == *"GB"* ]] && VAL=$(awk -v a="$VAL" 'BEGIN { print a * 1000 }')
		DISK_READ_TEST_RES+=( "$DISK_READ_TEST" )
		DISK_READ_TEST_AVG=$(awk -v a="$DISK_READ_TEST_AVG" -v b="$VAL" 'BEGIN { print a + b }')

		I=$(( $I + 1 ))
	done
	DISK_WRITE_TEST_AVG=$(awk -v a="$DISK_WRITE_TEST_AVG" 'BEGIN { print a / 3 }')
	DISK_READ_TEST_AVG=$(awk -v a="$DISK_READ_TEST_AVG" 'BEGIN { print a / 3 }')
}

AVAIL_SPACE=$(df -k . | awk 'NR==2{print $4}')
if [[ -z "$SKIP_FIO" && "$AVAIL_SPACE" -lt 2097152 && "$ARCH" != "aarch64" && "$ARCH" != "arm" ]]; then
	echo -e "\nLess than 2GB of space available. Skipping disk test..."
elif [[ -z "$SKIP_FIO" && "$AVAIL_SPACE" -lt 524288 && ("$ARCH" = "aarch64" || "$ARCH" = "arm") ]]; then
	echo -e "\nLess than 512MB of space available. Skipping disk test..."
elif [ -z "$SKIP_FIO" ]; then
	ZFSCHECK="/sys/module/zfs/parameters/spa_asize_inflation"
	if [[ -f "$ZFSCHECK" ]];then
		mul_spa=$((($(cat /sys/module/zfs/parameters/spa_asize_inflation)*2)))
		warning=0
		poss=()

		for pathls in $(df -Th | awk '{print $7}' | tail -n +2)
		do
			if [[ "${PWD##$pathls}" != "${PWD}" ]]; then
				poss+=("$pathls")
			fi
		done

		long=""
		m=-1
		for x in ${poss[@]}
		do
			if [ ${#x} -gt $m ];then
				m=${#x}
				long=$x
			fi
		done

		size_b=$(df -Th | grep -w $long | grep -i zfs | awk '{print $5}' | tail -c -2 | head -c 1)
		free_space=$(df -Th | grep -w $long | grep -i zfs | awk '{print $5}' | head -c -2)

		if [[ $size_b == 'T' ]]; then
			free_space=$((free_space * 1024))
			size_b='G'
		fi

		if [[ $(df -Th | grep -w $long) == *"zfs"* ]];then
			if [[ $size_b == 'G' ]]; then
				if ((free_space < mul_spa)); then
					warning=1
				fi
			else
				warning=1
			fi
		fi

		if [[ $warning -eq 1 ]];then
			echo -en "\nWarning! You are running SBS on a ZFS Filesystem and your disk space is too low for the fio test.\n"
		fi
	fi

	echo -en "\nPreparing system for disk tests..."

	DISK_PATH=$SBS_PATH/disk
	mkdir -p "$DISK_PATH"

	if [[ ! -z "$LOCAL_FIO" ]]; then
		FIO_CMD=fio
	else
		echo -en "\r\033[0K"
		echo -e "fio not found. Please install fio to run disk tests."
		SKIP_FIO="True"
	fi

	if [ -z "$SKIP_FIO" ]; then
		echo -en "\r\033[0K"

		declare -a DISK_RESULTS DISK_RESULTS_RAW
		BLOCK_SIZES=( "4k" "64k" "512k" "1m" )

		disk_test "${BLOCK_SIZES[@]}"
	fi

	if [[ ${#DISK_RESULTS[@]} -eq 0 ]]; then
		echo -e "fio disk speed tests failed. Running dd test as fallback..."

		dd_test

		if [ $(echo $DISK_WRITE_TEST_AVG | cut -d "." -f 1) -ge 1000 ]; then
			DISK_WRITE_TEST_AVG=$(awk -v a="$DISK_WRITE_TEST_AVG" 'BEGIN { print a / 1000 }')
			DISK_WRITE_TEST_UNIT="GB/s"
		else
			DISK_WRITE_TEST_UNIT="MB/s"
		fi
		if [ $(echo $DISK_READ_TEST_AVG | cut -d "." -f 1) -ge 1000 ]; then
			DISK_READ_TEST_AVG=$(awk -v a="$DISK_READ_TEST_AVG" 'BEGIN { print a / 1000 }')
			DISK_READ_TEST_UNIT="GB/s"
		else
			DISK_READ_TEST_UNIT="MB/s"
		fi

		echo -e
		echo -e "dd Sequential Disk Speed Tests:"
		echo -e "---------------------------------"
		printf "%-6s | %-6s %-4s | %-6s %-4s | %-6s %-4s | %-6s %-4s\n" "" "Test 1" "" "Test 2" ""  "Test 3" "" "Avg" ""
		printf "%-6s | %-6s %-4s | %-6s %-4s | %-6s %-4s | %-6s %-4s\n"
		printf "%-6s | %-11s | %-11s | %-11s | %-6.2f %-4s\n" "Write" "${DISK_WRITE_TEST_RES[0]}" "${DISK_WRITE_TEST_RES[1]}" "${DISK_WRITE_TEST_RES[2]}" "${DISK_WRITE_TEST_AVG}" "${DISK_WRITE_TEST_UNIT}"
		printf "%-6s | %-11s | %-11s | %-11s | %-6.2f %-4s\n" "Read" "${DISK_READ_TEST_RES[0]}" "${DISK_READ_TEST_RES[1]}" "${DISK_READ_TEST_RES[2]}" "${DISK_READ_TEST_AVG}" "${DISK_READ_TEST_UNIT}"
	else
		CURRENT_PARTITION=$(df -P . 2>/dev/null | tail -1 | cut -d' ' -f 1)
		DISK_RESULTS_NUM=$(expr ${#DISK_RESULTS[@]} / 6)
		DISK_COUNT=0

		echo -e "fio Disk Speed Tests (Mixed R/W 50/50) (Partition $CURRENT_PARTITION):"
		echo -e "---------------------------------"

		while [ $DISK_COUNT -lt $DISK_RESULTS_NUM ] ; do
			if [ $DISK_COUNT -gt 0 ]; then printf "%-10s | %-20s | %-20s\n"; fi
			printf "%-10s | %-11s %8s | %-11s %8s\n" "Block Size" "${BLOCK_SIZES[DISK_COUNT]}" "(IOPS)" "${BLOCK_SIZES[DISK_COUNT+1]}" "(IOPS)"
			printf "%-10s | %-11s %8s | %-11s %8s\n" "  ------" "---" "---- " "----" "---- "
			printf "%-10s | %-11s %8s | %-11s %8s\n" "Read" "${DISK_RESULTS[DISK_COUNT*6+1]}" "(${DISK_RESULTS[DISK_COUNT*6+4]})" "${DISK_RESULTS[(DISK_COUNT+1)*6+1]}" "(${DISK_RESULTS[(DISK_COUNT+1)*6+4]})"
			printf "%-10s | %-11s %8s | %-11s %8s\n" "Write" "${DISK_RESULTS[DISK_COUNT*6+2]}" "(${DISK_RESULTS[DISK_COUNT*6+5]})" "${DISK_RESULTS[(DISK_COUNT+1)*6+2]}" "(${DISK_RESULTS[(DISK_COUNT+1)*6+5]})"
			printf "%-10s | %-11s %8s | %-11s %8s\n" "Total" "${DISK_RESULTS[DISK_COUNT*6]}" "(${DISK_RESULTS[DISK_COUNT*6+3]})" "${DISK_RESULTS[(DISK_COUNT+1)*6]}" "(${DISK_RESULTS[(DISK_COUNT+1)*6+3]})"
			DISK_COUNT=$(expr $DISK_COUNT + 2)
		done
	fi
fi

function launch_sysbench_cpu {
	if [[ ! -z "$LOCAL_SYSBENCH" ]]; then
		CPU_CORES=$(lscpu | grep "^[[:blank:]]*CPU(s):" | sed 's/CPU(s): *//g')
		sysbench cpu --threads=$CPU_CORES run
	else
		echo -e "sysbench not found. Please install sysbench to run CPU tests."
	fi
}

function launch_sysbench_mem {
	if [[ ! -z "$LOCAL_SYSBENCH" ]]; then
		CPU_CORES=$(lscpu | grep "^[[:blank:]]*CPU(s):" | sed 's/CPU(s): *//g')
		sysbench memory --threads=$CPU_CORES run
	else
		echo -e "sysbench not found. Please install sysbench to run memory tests."
	fi
}

if [ -z "$SKIP_SYSBENCH_CPU" ]; then
	echo -e
	echo -e "CPU Benchmark Test:"
	echo -e "---------------------------------"
	launch_sysbench_cpu
fi

if [ -z "$SKIP_SYSBENCH_MEM" ]; then
	echo -e
	echo -e "Memory Benchmark Test:"
	echo -e "---------------------------------"
	launch_sysbench_mem
fi

echo -e
rm -rf "$SBS_PATH"

SBS_END_TIME=$(date +%s)

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

calculate_time_taken $SBS_END_TIME $SBS_START_TIME

unset LC_ALL
