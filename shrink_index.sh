#!/bin/bash
#####################################################
# Author:        Jon svendsen, 2023
# License:       Free as in beer
# Requirements:  jq installed on host running script
#####################################################
which jq >/dev/null
if [[ $? -ne 0 ]]; then
	printf "\n\t \033[31;1m#########################################################################"
	printf "\n\t Ooops, jq seems to be missing, please install before execute this script"
	printf "\n\t #########################################################################\033[0m"
	echo
	echo
	exit
fi

usage() {
	cat <<EOF

  ### Shrink/Reindex Elasticsearch indexes ###
  :: https://www.elastic.co/guide/en/elasticsearch/reference/current/docs-reindex.html

    $0 -i <index_pattern> [-n <new_index>] [-l <loop_pattern>] [-h <elastic_host>] [-y]

    -i  Index pattern to match; ex) my_index_2020-
      - Default: "" 
      - Required: True

    -l  Iteration pattern in index name; ex) "01 02"
        - Default: "01 02 03 ... 12" 
        - Required: False
        - ex using seq) $0 -i my_index- -l "\$(seq -f "%02g" 1 7)"

    -n  New index name; disables -l flag; ex) my_new_index_2020
        - Default: ""
        - Required: False

    -h  Elasticsearch host; ex) https://elastic.got.company.net:9200
        - Default: http://127.0.0.1:9200
        - Required: False
        - ex using auth) https://user:pwd@elastic.got.company.net:9200

    -y  Disables interactive mode

    [NOTE] if neither -n or -l is defined, script defaults to -l with default values

    EXAMPLES
    --------------------------------------------------------------------------------
    $ $0 -i my_index_2020- -l "01 02 03"
       
       Iterates over defined list and makes a reindex request each iteration

       Source               Destination                                            
       -----------------    -----------------------                                
       my_index_2020-01*    my_index_2020-01-shrunk      (-shrunk is always added) 
       my_index_2020-02*    my_index_2020-02-shrunk                                
       my_index_2020-03*    my_index_2020-03-shrunk

    $ $0 -i my_index_2020- -n my_new_index_2020

       Source               Destination                                            
       -----------------    -----------------------                                
       my_index_2020-*      my_new_index_2020


    Script is preferably run by nohup to make sure you get the job done even if you 
    lose your ssh session...

    $ nohup $0 -i j0nix_2023 -l "01 02 03 04" -y > reindex.log &

  /j0nix

EOF
}

while getopts "i:h:l:n:y" opt; do
	case $opt in
	i)
		index_pattern=$OPTARG
		;;
	l)
		iteration_pattern=$OPTARG
		;;
	n)
		new_index=$OPTARG
		;;
	h)
		elastic_host=$OPTARG
		;;
	y)
		proceed="yes"
		;;
	\?)
		echo "Invalid option: -$OPTARG"
		usage
		exit 1
		;;
	esac
done

# Description: 
#   Verify required input
input_verify() {

	if [[ -z $index_pattern ]]; then
		usage
		exit
	fi
}

# Description:
#   Set default for unset script arguments
set_defaults() {

	if [[ -z $iteration_pattern ]]; then
		iteration_pattern=$(seq -f "%02g" 1 12)
	fi

	if [[ -z $elastic_host ]]; then
		elastic_host="http://127.0.0.1:9200"
	fi

}
# Description:
#   Halts to request input (bypassed when -y flag is set)
do_proceed() {

	if [[ -z $proceed ]]; then
		while true; do
			read -p "Do you wish to proceed? " yn
			case $yn in
			[Yy]*) break ;;
			[Nn]*)
				echo "Abort, Abort !!"
				exit
				;;
			*) echo "Please answer yes or no." ;;
			esac
		done
	fi
}

# Params: poll_elastic_task [task_id]
# Description:
#   curl elasticsearch tasks enpoint to fetch status of a task.
#   Polls every 30s until task is completed, then breaks to 
#   proceed script execution
poll_elastic_task() {

	while true; do

		status=$(curl -k -s -XGET "$elastic_host/_tasks/$1?pretty=true")

		completed=$(echo $status | jq -r .completed)

		printf "\n  [ $1 @ $(date '+%T') ] Completed: $completed "

		if [[ $completed == 'true' ]]; then
			failures=$(echo $status | jq -r .response.failures)
			if [[ ${#failures} -gt 2 ]]; then
				description=$(echo $status | jq -r .task.description)
				printf "\n  \033[31;1m!!FAILURE!!\033[0m\n  $description\n  $failures\n"
				exit 1
			fi
			break
		else
      # c-style fors are a bash feature
			for ((i = 0; i < 6; ++i)); do
				for ((j = 0; j < 5; ++j)); do
					printf .
					sleep 1
				done
				printf '\b\b\b\b\b     \b\b\b\b\b'
			done
		fi
	done
}

# Params: start_reindex [source_index] [destination_index]
# Description:
#   Makes the reindex request to elasticsearch _reindex endpoint to be
#   executed in the background. Stores task id for use in
#   'poll_elastic_task()' function.
start_reindex() {

	printf "\n\n\033[31;1m[ START ]\033[0m[ $(date '+%Y%m%d-%T') ][ $1 -> $2]\n"

	if [[ -z $new_index ]]; then
		# Loop snoozer
		sleep 1
	fi

	task_id=$(curl -k -s -XPOST -H 'Content-Type: application/json' "$elastic_host/_reindex?wait_for_completion=false&pretty=true" -d "
  {
    \"source\": {
      \"index\": \"$1\"
    },
    \"dest\": {
      \"index\": \"$2\"
    },
    \"script\": {
      \"source\": \"ctx._id=null\",
      \"lang\": \"painless\"
    }
  }
  " | jq -r .task)

	printf "[ Elastic task id: $task_id ]\n"

}

# Description:
#   Workflow when -n is not set or -l <interation_pattern> is input arguments
#   Loops over defined iteration_pattern and makes reindex requests
loop_index_mode() {

	printf "\n\033[0;1m[ Executing reindex request ]\033[0m\n"
	for x in ${iteration_pattern[@]}; do
		printf "\n\t- $index_pattern$x* \033[0;1m->\033[0m $index_pattern$x-shrunk"
	done
	echo
	echo
	do_proceed
	for x in ${iteration_pattern[@]}; do
		start_reindex "$index_pattern$x*" "$index_pattern$x-shrunk"
		poll_elastic_task "$task_id"
	done
}

# Description:
#   Workflow when -n is an input argument
#   Makes a reindex request for defined patterns
new_index_mode() {

	printf "\n\033[0;1m[ Executing reindex request ]\033[0m\n"
	printf "\n\t- $index_pattern* \033[0;1m->\033[0m $new_index"
	echo
	echo
	do_proceed
	start_reindex "$index_pattern*" "$new_index"
	poll_elastic_task "$task_id"
}

# Description
#   Script workflow

input_verify
set_defaults
if [[ -n $new_index ]]; then
	new_index_mode
else
	loop_index_mode
fi
printf "\n\nWell ... Thats all folks!\n"
echo "/j0nixRulez 🖕"
echo
