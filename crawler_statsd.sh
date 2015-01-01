#/bin/bash

validOpts=':i:r:'

printUsage() {
  echo "Usage: $( basename "$0" ) [OPTIONS] <input file>"
  echo "  -i  Crawl interval, in minutes. How often to fetch each site."
  echo "  -r  Reporting interval, in number of crawls. Setting this to 1 sends"
  echo "      a report each time the websites are crawled."
}

if [[ $# < 1 ]] ; then
  printUsage
  exit 1
fi

OPTIND=1
while getopts "$validOpts" opt ; do
  if [[ "$opt" == '?' ]] ; then
    printUsage
    exit 1
  fi
done

crawlInterval=$(( 60 * 60 ))
reportInterval=24

OPTIND=1
while getopts "$validOpts" opt ; do
  case "$opt" in
    i) crawlInterval=$OPTARG;;
    r) reportingInterval=$OPTARG;;
    :) echo "Option -$OPTARG requires an argument"
       exit 1;;
  esac
done

shift $(( OPTIND - 1 ))

if [[ $crawlInterval < 1 ]] ; then echo "Crawl interval (-i) must be larger than 0"; exit 1; fi
if [[ $reportInterval < 1 ]] ; then echo "Reporting interval (-r) must be larger than 0"; exit 1; fi

urlsFile="$1"
if [[ ! -f "$urlsFile" ]] ; then
  echo "The file \"$urlsFile\" does not exist"
  exit 1
fi

getMd5() {
  if [[ $OSTYPE == darwin* ]] ; then
    md5 -q -s "$1" | tr -d '\r\n'
  else
    echo "$1" | md5sum | sed -r 's/ .*$//' | tr -d '\r\n'
  fi
}

tmpDir="$( mktemp -d )"
if [[ $? != 0 ]]; then
  echo "Could not create temp dir"
  exit 2
fi

trap "rm -rf "$tmpDir";exit 0;" EXIT INT TERM
fileIndex=1

while true ; do

  while read -r url ; do
    ./crawler.sh "$url" > "${tmpDir}/url_$( getMd5 "$url" )_$fileIndex"
  done < "$urlsFile"
  
  # Send report
  if [[ $fileIndex == $reportInterval ]] ; then
    while read -r url ; do
      for i in $( seq 1 $reportInterval ) ; do
        filename="${tmpDir}/url$( getMd5 "$url" )_$i"
      done
    done < "$urlsFile"
    lastReportTime=$now
  fi
  
  sleep $crawlInterval
  fileIndex=$(( fileIndex + 1 ))
  if [[ $fileIndex > $reportInterval ]] ; then
    rm -f "$tmpDir"/url_*
    fileIndex=1
  fi
done

exit 0

