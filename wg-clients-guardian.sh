#!/usr/bin/env bash
#
# Send a message to Telegram or Gotify Server when a client is connected or disconnected from wireguard tunnel
#
# This script is written by Alfio Salanitri <www.alfiosalanitri.it> and are licensed under MIT License.
# Credits: This script is inspired by https://github.com/pivpn/pivpn/blob/master/scripts/wireguard/clientSTAT.sh
#
# If dump is specified, then several lines are printed; the first contains in order separated by tab:
#    private-key, public-key, listen-port, fwmark.
# Subsequent lines are printed for each peer and contain in order separated by tab:
#    1           2              3         4            5                 6            7            8
#    public-key, preshared-key, endpoint, allowed-ips, latest-handshake, transfer-rx, transfer-tx, persistent-keepalive.
#

# check if wireguard exists
if ! command -v wg &> /dev/null; then
    printf "Sorry, but wireguard is required. Install it and try again.\n"
    exit 1;
fi

# check if the user passed in the config file and that the file exists
if [ ! "$1" ]; then
    printf "The config file is required.\n"
    exit 1
fi
if [ ! -f "$1" ]; then
    printf "This config file doesn't exist.\n"
    exit 1
fi

function unitify_bytes {
    bytes=$1
    if [ "$bytes" -gt "1073741824" ]; then
        echo $(( $bytes / 1073741824 )) GiB
    elif [ "$bytes" -gt "1048576" ]; then
        echo $(( $bytes / 1048576 )) MiB
    elif [ "$bytes" -gt "1024" ]; then
        echo $(( $bytes / 1024 )) KiB
    else
        echo $bytes B
    fi
}

function unitify_seconds {
    local SS=$1

    if [ "$SS" -ge "60" ]; then
        local MM=$(($SS / 60))
        local SS=$(($SS - 60 * $MM))

        if [ "$MM" -ge "60" ]; then
            local HH=$(($MM / 60))
            local MM=$(($MM - 60 * $HH))

            if [ "$HH" -ge "24" ]; then
                local DD=$(($HH / 24))
                local HH=$(($HH - 24 * $DD))
                local time_string="$DD days, $HH hours, $MM minutes and $SS seconds"
            else
                local time_string="$HH hours, $MM minutes and $SS seconds"
            fi
        else
            local time_string="$MM minutes and $SS seconds"
        fi

    else
        local time_string="$SS seconds"
    fi

    echo "$time_string"
}


# config constants
readonly CURRENT_PATH=$(pwd)
readonly CLIENTS_DIRECTORY="$CURRENT_PATH/clients"
readonly WG_PATH="/usr/local/etc/wireguard/clients/"
readonly NOW=$(date +%s)
readonly DT=$(date)

# after X minutes the clients will be considered disconnected
readonly TIMEOUT=$(awk -F'=' '/^timeout=/ { print $2}' $1)

readonly WIREGUARD_CLIENTS=$(wg show wg0 dump | tail -n +2) # remove first line from list
if [ "" == "$WIREGUARD_CLIENTS" ]; then
    printf "No wireguard clients.\n"
    exit 1
fi

readonly NOTIFICATION_CHANNEL=$(awk -F'=' '/^notification_channel=/ { print $2}' $1)

readonly EMAIL_TO=$(awk -F'=' '/^email_to=/ { print $2}' $1)

readonly GOTIFY_HOST=$(awk -F'=' '/^gotify_host=/ { print $2}' $1)
readonly GOTIFY_APP_TOKEN=$(awk -F'=' '/^gotify_app_token=/ { print $2}' $1)
readonly GOTIFY_TITLE=$(awk -F'=' '/^gotify_title=/ { print $2}' $1)

readonly TELEGRAM_CHAT_ID=$(awk -F'=' '/^chat=/ { print $2}' $1)
readonly TELEGRAM_TOKEN=$(awk -F'=' '/^token=/ { print $2}' $1)

while IFS= read -r LINE; do
    public_key=$(awk '{ print $1 }' <<< "$LINE")
    remote_ip=$(awk '{ print $3 }' <<< "$LINE" | awk -F':' '{print $1}')
    last_seen=$(awk '{ print $5 }' <<< "$LINE")
    transfer_rx=$(awk '{ print $6 }' <<< "$LINE")
    transfer_tx=$(awk '{ print $6 }' <<< "$LINE")
    client_name=$(grep -R "$public_key" $WG_PATH | awk -F"$WG_PATH|_public.key:" '{print $2}' | sed -e 's./..g')
    client_file="$CLIENTS_DIRECTORY/$client_name.txt"

    # create the client file if it does not exist.
    if [ ! -f "$client_file" ]; then
        echo "offline}" > $client_file
    fi  

    # setup notification variable
    send_notification="no"

    # last client status
    last_connection_status=$(cat $client_file)

    # elapsed seconds from last connection
    # last_seen_seconds=$(date -d @"$last_seen" '+%s')
    # last_seen_seconds=$(($NOW - $last_seen))
    last_seen_seconds=$last_seen
    
    # if the user is online
    if [ "$last_seen" -ne 0 ]; then
        # elapsed minutes from last connection
        last_seen_elapsed_minutes=$((10#$(($NOW - $last_seen_seconds)) / 60))
        # if the previous state was online and the elapsed minutes are greater than TIMEOUT, the user is offline
        if [ $last_seen_elapsed_minutes -gt $TIMEOUT ] && [ "online" == $last_connection_status ]; then
            echo "offline" > $client_file
            send_notification="disconnected"
        # if the previous state was offline and the elapsed minutes are lower than timout, the user is online
        elif [ $last_seen_elapsed_minutes -le $TIMEOUT ] && [ "offline" == $last_connection_status ]; then
            echo "online" > $client_file
            send_notification="connected"
        fi
    else
        # if the user is offline
        if [ "offline" != "$last_connection_status" ]; then
            echo "offline" > $client_file
            send_notification="disconnected"
        fi
    fi

    # send notification to telegram
    if [ "no" != "$send_notification" ]; then
        printf "The client %s is %s\n" $client_name $send_notification
        message="$client_name is $send_notification from ip address $remote_ip"
        if [ "telegram" == "$NOTIFICATION_CHANNEL" ] || [ "both" == "$NOTIFICATION_CHANNEL" ]; then
            curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" -F chat_id=$TELEGRAM_CHAT_ID -F text="🐉 Wireguard: \`$message\`" -F parse_mode="MarkdownV2" > /dev/null 2>&1
        fi
        if [ "gotify" == "$NOTIFICATION_CHANNEL" ] || [ "both" == "$NOTIFICATION_CHANNEL" ]; then
            curl -X POST "${GOTIFY_HOST}/message" -H "accept: application/json" -H "Content-Type: application/json" -H "Authorization: Bearer ${GOTIFY_APP_TOKEN}" -d '{"message": "'"$message"'", "priority": 5, "title": "'"$GOTIFY_TITLE"'"}' > /dev/null 2>&1
        fi
        if [ "email" == "$NOTIFICATION_CHANNEL" ]; then
            echo "$message" | mail -s "Wireguard $client_name is $send_notification" ${EMAIL_TO}
        fi
    else
        printf "The client %s is %s, no notification will be sent.\n" $client_name $(cat $client_file)
    fi

done <<< "$WIREGUARD_CLIENTS"

exit 0
