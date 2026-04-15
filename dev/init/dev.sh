#!/bin/bash

if [[ ${DEBUG} == false || ${DEBUG} == "false" ]]; then
	exit 0
fi

mkdir -p /logs
. /scripts/init/helpers.sh
export -f hr text_with_padding add_enable add_cflag add_ldflag add_extralib join_lines split_lines clean_whitespace apply_sed check_enabled log

hr # Print a horizontal line
echo "       _   _       __  __                      "
echo "      | \ | | ___ |  \/  | ___ _ __ ___ _   _  "
echo "      |  \| |/ _ \| |\/| |/ _ \ '__/ __| | | | "
echo "      | |\  | (_) | |  | |  __/ | | (__| |_| | "
echo "      |_| \_|\___/|_|  |_|\___|_|  \___|\__, | "
echo "        _____ _____ __  __ ____  _____ _|___/  "
echo "       |  ___|  ___|  \/  |  _ \| ____/ ___|   "
echo "       | |_  | |_  | |\/| | |_) |  _|| |  _    "
echo "       |  _| |  _| | |  | |  __/| |__| |_| |   "
echo "       |_|   |_|   |_|  |_|_|   |_____\____|   "
echo ""
hr # Print a horizontal line
echo "🐞 Running development in debug mode 🐞"
hr # Print a horizontal line

if [[ ${TARGET_OS} == "darwin" ]]; then
    darwin_extra_scripts=(/test/includes/darwin/*.sh)
    for script in "${darwin_extra_scripts[@]}"; do
        if [[ -f "${script}" ]]; then
            cp "${script}" /test/
        fi
    done
elif [[ ${TARGET_OS} == "windows" ]]; then
    windows_extra_scripts=(/test/includes/windows/*.sh)
    for script in "${windows_extra_scripts[@]}"; do
        if [[ -f "${script}" ]]; then
            cp "${script}" /test/
        fi
    done
else
    linux_extra_scripts=(/test/includes/linux/*.sh)
    for script in "${linux_extra_scripts[@]}"; do
        if [[ -f "${script}" ]]; then
            cp "${script}" /test/
        fi
    done
fi

files=(/test/*.sh)       # Expand matching .sh files into an array
total_count=${#files[@]} # Get the count of matching files
string_total_count=$(printf "%02d" $total_count)
current_count=0
success_count=0
failed_count=0
skipped_count=0
total_time=0

text_with_padding "🔍 Found ${total_count} test scripts to run" ""
hr # Print a horizontal line

text_with_padding "🚀 Starting dev scripts execution..." ""
hr # Print a horizontal line

#region build
for i in /test/*.sh; do
	# Ensure the glob expanded to actual files
	[[ -f "$i" ]] || continue
	chmod +x $i
	current_count=$((current_count + 1))
	string_current_count=$(printf "%02d" $current_count)
	name="${i#*-}"     # Remove the prefix
	name="${name%.sh}" # Remove the suffix
	name="${name^^}"   # Uppercase
	text_with_padding "🛠️ Building ${name}" "[${string_current_count}/${string_total_count}]" -5
	start_time=$(date +%s)
	$i >/dev/null 2>&1
	result=$?
	if [ ${result} -eq 255 ]; then # This is skipped
		text_with_padding "➖ ${name} was skipped" ""
		skipped_count=$((skipped_count + 1))
	elif [ ${result} -eq 0 ]; then # This is success
		if [[ ${DEBUG} == "true" ]]; then
			if [[ -f "/ffmpeg_build.log" ]]; then
				logtext=$(clean_whitespace "$(cat /ffmpeg_build.log)")
				if [[ -n "${logtext}" ]]; then
					printf "%s\n" "📃 Log: ${logtext}"
				fi
				echo "Log for ${name}" >>/full_ffmpeg_build.log
				echo "${logtext}" >>/full_ffmpeg_build.log
				echo "$(hr)" >>/full_ffmpeg_build.log
				echo "" >>/full_ffmpeg_build.log
				rm -f /ffmpeg_build.log
			fi
		fi
		end_time=$(($(date +%s) - ${start_time}))
		end_time_string=$(printf "%02d%s" $end_time "s")
		if [ $end_time -gt 60 ]; then
			min_end_time=$(($end_time / 60))
			end_time_string=$(printf "%02d%s" $min_end_time "m")
		fi
		text_with_padding "✅ ${name} was built successfully" "[ ${end_time_string} ]" -1
		success_count=$((success_count + 1))
	else # This is failure
		if [[ ${DEBUG} == "true" ]]; then
			logtext=$(clean_whitespace "$(cat /ffmpeg_build.log)")
			if [[ -n "${logtext}" ]]; then
				printf "%s\n" "📃 Log: ${logtext}"
			fi
			rm -f /ffmpeg_build.log
			exit 1
		fi
		end_time=$(($(date +%s) - ${start_time}))
		end_time_string=$(printf "%02d%s" $end_time "s")
		if [ $end_time -gt 60 ]; then
			min_end_time=$(($end_time / 60))
			end_time_string=$(printf "%02d%s" $min_end_time "m")
		fi
		text_with_padding "❌ ${name} build failed" "[ ${end_time_string} ]" -1
		failed_count=$((failed_count + 1))
	fi
	total_time=$((total_time + end_time))
done
hr # Print a horizontal line
#endregion

#region enabled components
local_enables=$(split_lines "/build/enable.txt")
local_enables_count=$(echo "${local_enables}" | wc -l)
if [[ ${local_enables} == "" ]]; then
	local_enables_count=0
fi
text_with_padding "📃 Enabled components:" "[ ${local_enables_count} ]" -2
hr # Print a horizontal line
if [[ ${local_enables} == "" ]]; then
	text_with_padding "   No components enabled" ""
else
	for enable in $local_enables; do
		text_with_padding "   ${enable}" ""
	done
fi
hr # Print a horizontal line
#endregion

#region extra libflags
local_libflags=$(split_lines "/build/extra_libflags.txt")
local_libflags_count=$(echo "${local_libflags}" | wc -l)
if [[ ${local_libflags} == "" ]]; then
    local_libflags_count=0
fi
text_with_padding "📃 Extra libraries:" "[ ${local_libflags_count} ]" -2
hr # Print a horizontal line
if [[ ${local_libflags} == "" ]]; then
    text_with_padding "   No extra libraries" ""
else
    for libflag in $local_libflags; do
        text_with_padding "   ${libflag}" ""
    done
fi
echo "$(join_lines "/build/extra_libflags.txt")" >/build/extra_libflags.txt
hr # Print a horizontal line
#endregion

#region exit
exit 0
#endregion
