#!/bin/bash

if [[ $# == 0 ]] ; then
  echo "Usage: $( basename "$0" ) url1 url2 ..."
  exit 1
fi

tmpDir="$( mktemp -d )"

if [[ $? != 0 ]]; then
  echo "Could not create temp dir"
  exit 2
fi

trap "rm -rf "$tmpDir";exit 0" EXIT INT TERM

stripTags() {
  echo "$1" | sed -r 's/<[^>]+?>//g'
}

printKeyValElems() {
  
  local file=$1
  local tagName=$2
  local keyAttr=$3
  local q="['\"]"
  
  local keyRegex='(name|property|rel)='
  local grepKeyRegex=$keyRegex$q$keyAttr$q
  local sedKeyRegex=$keyRegex$q"([^\"']*?)"$q
  local valRegex='(content|href|src)='$q"([^\"']*)"$q
  
  grep -Pzo '<'$tagName'\s[^<>]*('$grepKeyRegex'[^<>]*'$valRegex'|'$valRegex'[^<>]*'$grepKeyRegex')[^<>]*>' "$file" | \
    tr '\r\n' ' ' | \
    sed -r 's/<'$tagName'\s[^<>]*('$sedKeyRegex'[^<>]*'$valRegex'|'$valRegex'[^<>]*'$sedKeyRegex')[^<>]*>/[meta \3\9] \5\7\n/g' | \
    # trim spaces
    sed -r 's/^[[:space:]]+|[[:space:]]+$//g'
}

getMd5() {
  if [[ $OSTYPE == darwin* ]] ; then
    md5 -q -s "$1" | tr -d '\r\n'
  else
    echo "$1" | md5sum | sed -r 's/ .*$//' | tr -d '\r\n'
  fi
}

getServerData() {

  local domain=$( echo "$1" | sed -r 's/^https?:\/\///' | sed -r 's/\/.+$//' )
  local ip=$( dig +short "$domain" | head -n 1 )
  if [[ ! $ip ]]; then
    echo "Could not get ip for $domain" 1>&2
    exit 1
  fi
  local serverData=$( wget -T7 -qO - "http://ip-api.com/line/${ip}?fields=status,country,city,isp,query" )
  if [[ "$( head -n1 <<< "$serverData" )" != 'success' ]]; then
    echo "ip geolocation for $1 failed with status '$status'"
    exit 2
  fi

  echo "[ip] $( sed -n '5p' <<< "$serverData" )"
  echo "[country] $( sed -n '2p' <<< "$serverData" )"
  echo "[city] $( sed -n '3p' <<< "$serverData" )"
  echo "[isp] $( sed -n '4p' <<< "$serverData" )"
}

for url in "$@" ; do
  
  urlMd5="$( getMd5 "$url")"
  tmpFile="${tmpDir}/${urlMd5}.html"
  startTime=$( date +%s )

  wgetResult="$( wget --header='Accept: text/html' \
    --user-agent='Mozilla/5.0 (Macintosh; Intel Mac OS X 10.8; rv:21.0) Gecko/20100101 Firefox/21.0' \
    -qS -O "$tmpFile" "$url" 2>&1 )"
  
  if [[ $? != 0 ]]; then
    echo "Error: could not download $url" 1>&2
    # Clean up
    rm -f "$tmpFile"
    continue
  fi

  dlSpeed=$(( $( date +%s ) - startTime ))

  echo "========== $url =========="
  echo "Download size: $(( $( wc -c < "$tmpFile" ) / 1000 )) KB"
  echo "Download speed: $dlSpeed sec"
  echo '[title]' $( stripTags "$( grep -Pzo '<title[^>]*>([^<>]*)</title>' "$tmpFile" )" )
  printKeyValElems "$tmpFile" meta '(description|keywords)'
  printKeyValElems "$tmpFile" meta 'og:[^"'"'"']*'
  printKeyValElems "$tmpFile" link '(canonical|next|alternate)'
  
  q="['\"]"
  linkElemCount=$( grep -Pzo '<link\s[^>]*rel='"$q"'stylesheet'"$q" "$tmpFile" | grep -Pc '<link' )
  scriptElemCount=$( grep -Pzo '<script\s[^>]*src=' "$tmpFile" | grep -Pc '<script' )
  echo "CSS <link>s: $linkElemCount"
  echo "<script>s with src: $scriptElemCount"
  
  echo "$wgetResult" | \
    sed -r 's/^[[:space:]]+|[[:space:]]+$//g' | \
    grep -Pi '^(cache-control|wp-super-cache|server:|content-type|expires)'
  getServerData "$url"
  echo

  # Clean up
  rm -f "$tmpFile"
done

exit 0


