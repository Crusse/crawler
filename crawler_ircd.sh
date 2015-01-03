#!/bin/bash

PRIVMSG_MAX_LINES=5
validOpts=':c:n:spe:u:f'

printUsage() {
  echo "Usage: $( basename "$0" ) [OPTIONS] addr port"
  echo "Options:"
  echo "  -c  Channels. Separate each channel with a space."
  echo "  -n  Nickname."
  echo "  -s  Use SSL."
  echo "  -p  Use password. This is a flag -- you will be prompted for a "
  echo "      password."
  echo "  -e  Output to this email address."
  echo "  -u  The file to use for storing stats collector URLs. The file will"
  echo "      be created if it does not exist."
  echo "  -f  Flowdock mode."
}

if [[ $# = 0 ]] ; then
  printUsage
  exit 1
fi

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
email=""
flowdock=""

OPTIND=1
while getopts "$validOpts" opt; do
  case "$opt" in
    s) useSsl=1;;
    p) usePassword=1
       echo -n "Password: "
       read -sr password;;
    c) channels="$OPTARG";;
    n) nick="$OPTARG";;
    e) email="$OPTARG";;
    u) urlsPath="$OPTARG";;
    f) flowdock=1;;
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

if [[ "$urlsPath" ]] ; then
  if [[ ! -e "$( dirname "$urlsPath" )" ]] ; then
    mkdir "$( dirname "$urlsPath" )"
  fi
  if [[ ! -e "$urlsPath" ]] ; then
    touch "$urlsPath"
  fi
  if [[ ! -w "$urlsPath" ]] ; then
    echo "$urlsPath is not writable"
    exit 1
  fi
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
    PING*) echo "PONG${1#PING}" >> $configPath
      echo "${1}";;
    PONG*) echo "PONG $( date "+%D %T" )";;
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
    
    local ircOut=""

    case $cmd in
      !crawl)
        if [[ ! "$arg" ]] ; then return 1; fi
        ircOut=$( ./crawler.sh "$arg" )
        if [[ $? != 0 ]] ; then return 1; fi
        ;;
      !addurl)
        if [[ ! "$urlsPath" || ! "$arg" ]] ; then return 1; fi
        if [[ ! $( grep -F "$arg" "$urlsPath" ) ]] ; then
          echo "$arg" >> "$urlsPath"
          ircOut="Added $arg to crawler stats collector"
        else
          ircOut="$arg already exists in the crawler stats collector"
        fi
        ;;
      !removeurl)
        if [[ ! "$urlsPath" || ! "$arg" ]] ; then return 1; fi
        if [[ $( grep -F "$arg" "$urlsPath" ) ]] ; then
          sed -ir '\|^'"$arg"'$|d' "$urlsPath"
          ircOut="Removed $arg from the crawler stats collector"
        else
          ircOut="$arg was not found in the crawler stats collector"
        fi
        ;;
      !listurls)
        if [[ ! "$urlsPath" ]] ; then return 1; fi
        ircOut=$( cat "$urlsPath" )
    esac
    
    if (( $( wc -l <<< "$ircOut" ) > PRIVMSG_MAX_LINES )) && [[ "$email" ]] ; then
      echo -e "$ircOut" | mail -s "Crawler results $arg" "$email"
      echo "PRIVMSG $sendTo :Result has more than $PRIVMSG_MAX_LINES lines; sent an email to $email" >> "$configPath"
    else
      while read -r line ; do
        echo "PRIVMSG $sendTo :$line" >> "$configPath"
      done <<< "$ircOut"
    fi
  fi
}

connInited=""
cleanUpAfterConnInit() {
  # truncate the command input file, so that it doesn't include plain pwds etc.
  > "$configPath"
  if [[ $flowdock ]] ; then
    # Flowdock doesn't seem to PING us periodically, so we try to keep the
    # connection up by PINGing the server.
    ( while true ; do
        sleep 60
        if [[ ! -e "$configPath" ]] ; then
          exit 0
        fi
        echo "PING irc.flowdock.com" >> "$configPath"
      done ) &
    # Kill the pinging child process when this IRC daemon exits
    pingPid=$!
    trap "echo \"Killing ping process\"; kill $pingPid" EXIT HUP TERM INT
  fi
  connInited=1
}

if [[ $useSsl ]] ; then
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

