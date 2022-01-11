#!/usr/bin/env /bin/bash
#
# Grepinator v0.0.23
#
# Grepinator is a series of bash scripts utilising the power of grep and regex.
#
# See Readme.md for usage and instructions.

######################################################
VERSION="0.0.23"
source ./grepinator.globals
####################################################

banner () {
echo '

   ______                _             __
  / ____/_______  ____  (_)___  ____ _/ /_____  _____
 / / __/ ___/ _ \/ __ \/ / __ \/ __ `/ __/ __ \/ ___/
/ /_/ / /  /  __/ /_/ / / / / / /_/ / /_/ /_/ / /
\____/_/   \___/ .___/_/_/ /_/\__,_/\__/\____/_/
              /_/
'
}

prereqs () {

IPTABLES=`whereis iptables | awk '{print $2}'`
IPSET=`whereis ipset | awk '{print $2}'`
CURL=`whereis curl | awk '{print $2}'`
SQLITE=`whereis sqlite3 | awk '{print $2}'`
GEOIPLOOKUP=`whereis geoiplookup | awk '{print $2}'`

	if [ "$EUID" -ne 0 ]
		then echo "Please run as root"
		exit 1;
	fi

        if [ ! -f "$IPSET" ]; then
                echo " [!] ipset not found. Please install ipset..";
                exit 1;
	fi

        if [ ! -f "$IPTABLES" ]; then
                echo " [!] iptables not found. Please install iptables..";
                exit 1;
	fi

        if [ ! -f "$CURL" ]; then
                echo " [!] curl not found. Please install curl..";
                exit 1;
	fi

        if [ ! -f "$GEOIPLOOKUP" ]; then
                echo " [!] geoiplookup not found. Please install geoip-bin..";
                exit 1;
	fi

        if [ ! -f "$SQLITE" ]; then
                echo " [!] sqlite3 not found. Please install sqlite3..";
                exit 1;
	fi

	if [ ! -d "$DB_PATH" ]; then
		mkdir $DB_PATH
	fi

	if [ ! -f "$DB_PATH/$DB_NAME.db" ]; then
		sqlite3 $DB_PATH/$DB_NAME.db "CREATE TABLE IF NOT EXISTS GREPINATOR ( ID INTEGER PRIMARY KEY, Date DATETIME, IP VARCHAR(16), Filter VARCHAR(25), Location VARCHAR(25), Status VARCHAR(25) );"
	fi
}

ipset_setup () {

	if ! ipset list -n | grep -Eq "^$IPSET_GREPINATOR$"; then
		if ! ipset create "$IPSET_GREPINATOR" hash:ip family inet hashsize 2048 maxelem ${MAXELEM:-65536}; then
			echo >&2 "Error: while creating the initial ipset"
			exit 1
		fi
	fi

	if ! ipset list -n | grep -Eq "^$IPSET_BLACKLIST_NAME$"; then
		if ! ipset create "$IPSET_BLACKLIST_NAME" hash:net family inet hashsize 16384 maxelem ${MAXELEM:-65536} timeout 0; then
			echo >&2 "Error: while creating the initial ipset"
			exit 1
		fi
	fi


	if ! iptables -nvL INPUT | grep -q "match-set $IPSET_GREPINATOR"; then
  		if ! iptables -I INPUT 1 -m set --match-set "$IPSET_GREPINATOR" src -j DROP; then
			echo >&2 "Error: while adding the --match-set ipset rule to iptables"
    			exit 1
		fi
	fi

	if ! iptables -nvL INPUT | grep -q "match-set $IPSET_BLACKLIST_NAME"; then
  		if ! iptables -I INPUT 2 -m set --match-set "$IPSET_BLACKLIST_NAME" src -j DROP; then
			echo >&2 "Error: while adding the --match-set ipset rule to iptables"
    			exit 1
		fi
	fi
}

sqlite_log () {

RESULT=`sqlite3 /var/log/grepinator/grepinator.db "select count(*) from GREPINATOR where IP='$IP';"`

	if [ $RESULT -eq 0 ]
	then
		FILTER_NAME=`echo $FILTER | sed 's/.filter$//'`
		GEOIP=`geoiplookup $IP | sed 's/.*: //'`
		ENTRIES=$((ENTRIES+1))
			sqlite3 $DB_PATH/$DB_NAME.db "INSERT INTO GREPINATOR (Date, IP, Filter, Location, Status) VALUES (datetime('now', 'localtime'), '$IP', '$FILTER_NAME', '$GEOIP', 'Threat');"
	fi
}

filter () {

	echo "Grepinating filters..."
	ENTRIES=0
		for FILTER in $(ls -1 $FILTERDIR)
			do
				for IP in $($FILTERDIR/$FILTER 2>/dev/null); do echo -ne "Checking $IP"\\r; sqlite_log; sleep 0.1; done
			done

	echo  "Number of new attacks found using filters: $ENTRIES"
}

grepinator () {

UPDATE=$(sqlite3 $DB_PATH/$DB_NAME.db "select count(*) from GREPINATOR where Status='Threat';")

	if [ "$UPDATE" -eq 0 ]; then
		echo "No IP's to add to ipset. I'll be back.."
	else
	echo "Grepinating IP's..."
	ENTRIES=0
		for IP in $(sqlite3 $DB_PATH/$DB_NAME.db "select IP from GREPINATOR where Status='Threat';")
			do
				echo -ne "Blocking $IP"\\r; ipset add $IPSET_GREPINATOR $IP 2>/dev/null;
				ENTRIES=$((ENTRIES+1))
				sqlite3 $DB_PATH/$DB_NAME.db "UPDATE GREPINATOR SET Status='Blocked' WHERE IP='$IP';"
				sleep 0.1;
			done

		echo "Added $ENTRIES IP's to Grepinators firewall"
	fi
}

blacklist_ips () {
IP_BLACKLIST_TMP=$(mktemp)
	for i in "${BLACKLISTS[@]}"
		do
  			IP_TMP=$(mktemp)
			(( HTTP_RC=$(curl -L -A "grepinator" --connect-timeout 10 --max-time 10 -o "$IP_TMP" -s -w "%{http_code}" "$i") ))
			if (( HTTP_RC == 200 || HTTP_RC == 302 )); then
				grep -Po '^(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?' "$IP_TMP" | sed -r 's/^0*([0-9]+)\.0*([0-9]+)\.0*([0-9]+)\.0*([0-9]+)$/\1.\2.\3.\4/' >> "$IP_BLACKLIST_TMP"

  			elif (( HTTP_RC == 503 )); then
				echo -e "\\nUnavailable (${HTTP_RC}): $i"
			else
				echo >&2 -e "\\nWarning: curl returned HTTP response code $HTTP_RC for URL $i"
			fi
		rm -f "$IP_TMP" "IP_BLACKLIST_TMP"
	done

	ENTRIES=$(cat $IP_BLACKLIST_TMP | wc -l)
	echo;echo "Number of IP's found in Blacklists: $ENTRIES"
	ipset create "$IPSET_TMP_BLACKLIST_NAME" -exist hash:net family inet hashsize 16384 maxelem ${MAXELEM:-65536} timeout 0

	for IP in $(cat $IP_BLACKLIST_TMP)
		do
			echo -ne "Blocking IP $IP     "\\r
			ipset add $IPSET_TMP_BLACKLIST_NAME $IP timeout ${TIMEOUT:-10800} 2>/dev/null
		done
	ipset swap $IPSET_TMP_BLACKLIST_NAME $IPSET_BLACKLIST_NAME
	ipset destroy $IPSET_TMP_BLACKLIST_NAME
	echo "Added $ENTRIES IP's to Grepinators BL firewall"
	rm $IP_BLACKLIST_TMP
}

daemon() {
	while true; do
	filter
	grepinator
	sleep 5;
	done
}

reset() {
	sqlite3 $DB_PATH/$DB_NAME.db "DELETE FROM GREPINATOR;"
	echo "Database $DB_NAME has been cleared"
	ipset flush $IPSET_GREPINATOR
	ipset flush $IPSET_BLACKLIST_NAME
	echo "Blocklists cleared"
	exit 0;
}

db_display_mode () {

SQLITE_VER=$(sqlite3 -version | awk '{print $1}' | tr -d '.,')

        if [ $SQLITE_VER -ge "3330" ]; then
                DISPLAY="box"
        else
                DISPLAY="column"
        fi
}

status() {
	db_display_mode
	sqlite3 -header -$DISPLAY $DB_PATH/$DB_NAME.db "select * from GREPINATOR order by id desc limit 10;"
	echo
	iptables -nvL INPUT | grep -e 'grepinator src$' | awk '{print "Grepinator Packets Dropped: " $1}'
	iptables -nvL INPUT | grep -e 'grepinatorBL src$' | awk '{print "Grepinator Blacklists Packets Dropped: " $1}'
	exit 0;
}

usage() {
        echo "Usage : $0 <all|filters|blacklists|log|status|reset>"
	cat <<_EOF

	all          - Run all filters and blacklists and BLOCK
	daemon       - Run Grepinator in daemon mode (no output)
	filters      - Run filters and BLOCK
	blacklists   - Update and block blacklisted IP's only. Should only be ran once a day.
	log          - Run filters and LOG only. (No blocking occurs)
	status       - Show status of whats been blocked
	reset        - Clear the database of logged IP's
	top          - Show table of blocked ip's in realtime
_EOF

}

# Check command args
if [ $# -lt 1 ]
then
	banner
	usage
	exit 0
fi

case "$1" in

all)
	banner
	prereqs
	ipset_setup
	filter
	grepinator
	blacklist_ips
    ;;
watcher)
	daemon
    ;;
daemon)

#	export PATH=/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/sbin:/usr/local/bin
#	umask 022
	nohup setsid $0 watcher 2>/var/log/grepinator.err >/var/log/grepinator.log &
    ;;
filters)
	banner
	prereqs
	ipset_setup
	filter
	grepinator
    ;;
blacklists)
	banner
	prereqs
	ipset_setup
	blacklist_ips
    ;;
log)
	banner
	prereqs
	ipset_setup
	filter
   ;;
status)
	banner
	prereqs
	status
   ;;
reset)
	banner
	prereqs
	reset
   ;;
top)
	banner
	prereqs
	watch $0 status
   ;;
*)
	banner
	usage
   ;;
esac

