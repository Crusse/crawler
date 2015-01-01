#!/bin/bash

validOpts=':c:n:spf'

printUsage() {
  echo "Usage: $( basename "$0" ) [OPTIONS] addr port"
  echo "Options:"
  echo "  -c  Channels. Separate each channel with a space. (optional)"
  echo "  -n  Nickname. (optional)"
  echo "  -s  Use SSL. (optional)"
  echo "  -p  Use password. This is a flag -- you will be prompted for a "
  echo "      password. (optional)"
}

# Validate args
OPTIND=1
while getopts "$validOpts" opt; do
  if [[ "$opt" == '?' ]] ; then
    printUsage
    exit 1
  fi
done

useSsl=""
password=""
usePassword=""
nick="Crawler"
channels=""

OPTIND=1
while getopts "$validOpts" opt; do
  case "$opt" in
    s) useSsl=1;;
    p) usePassword=1
       echo -n "Password: "
       read -sr password;;
    c) channels="$OPTARG";;
    n) nick="$OPTARG";;
    :) echo "Option -$OPTARG requires an argument"
       exit 1;;
  esac
done

shift $(( OPTIND - 1 ))
server="$1"
port="$2"

if [[ ! "$server" ]] ; then
  echo "No addr given." 1>&2
  exit 1
elif [[ ! "$port" ]] ; then
  echo "No port given." 1>&2
  exit 1
fi

getMd5() {
  if [[ $OSTYPE == darwin* ]] ; then
    md5 -q -s "$1" | tr -d '\r\n'
  else
    echo "$1" | md5sum | sed -r 's/ .*$//' | tr -d '\r\n'
  fi
}

configPath="/tmp/crawlerdlog$( getMd5 "$server"'|'"$nick"'|'"$channels" )"
touch "$configPath"

if [[ "$usePassword" && "$password" ]] ; then
  echo "PASS $password" > $configPath
fi
echo "NICK $nick" >> $configPath
echo "USER $nick +i * :$nick" >> $configPath
for channel in $channels; do
  echo "JOIN #$channel" >> $configPath
done

trap "rm -f $configPath;exit 0" INT TERM EXIT

handleServerMsg() {
  case "$1" in
    PING*) echo "PONG${1#PING}" >> $configPath;;
    *QUIT*) ;;
    *PART*) ;;
    *JOIN*) ;;
    *NICK*) ;;
    *PRIVMSG*) handlePrivMsg "$1";;
    *) echo "${1}";;
  esac
}

handlePrivMsg() {

  read src dest cmd arg <<< $( echo "${1}" | \
    sed -nr 's/^:([^!]+).*PRIVMSG ([^ ]*) :(.*)$/\1 \2 \3/p' | \
    sed -nr 's/\r//gp' )

  if [[ "$src" && "$cmd" =~ ^![[:alnum:]] ]] ; then

    if [[ "$dest" =~ ^# ]] ; then local sendTo="$dest"
    else local sendTo="$src"; fi

    local crawlOut=""
    case $cmd in
      !crawl)
        local crawlOut=$( ./crawler.sh "$arg" 2>&1 )
        ;;
    esac
    
    while read -r line ; do
      echo "PRIVMSG $sendTo :$line" >> "$configPath"
    done <<< "$crawlOut"
  fi
}

connInited=""
cleanUpAfterConnInit() {
  # truncate the command input file, so that it doesn't include plain pwds etc.
  > "$configPath"
  connInited=1
}

if [[ $useSsl || $useFlowdock ]] ; then
  echo "Connecting to $server:$port with openssl s_client"
  tail -F "$configPath" | openssl s_client -connect "$server:$port" | while read -r msg ; do
    if [[ ! "$connInited" ]] ; then cleanUpAfterConnInit; fi
    handleServerMsg "$msg"
  done
else
  echo "Connecting to $server:$port with netcat"
  tail -F "$configPath" | nc "$server" "$port" | while read -r msg ; do
    if [[ ! "$connInited" ]] ; then cleanUpAfterConnInit; fi
    handleServerMsg "$msg"
  done
fi

exit 0

