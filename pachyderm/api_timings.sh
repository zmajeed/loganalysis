#!/bin/bash

# api_timings.sh
# get timings for each api call from pachyderm debug dump logs
 
if ! type mlr >/dev/null 2>&1; then
  echo >&2 "mlr not found in PATH, please install latest mlr from https://github.com/johnkerl/miller/releases"
  exit 1
fi

function usage {
  echo "Usage: api_timings.sh [-h | --help]"
  echo "-z: timezone, default ${defaults[timezone]}"
  echo "-h | --help: help"
  echo "Examples:"
  exit 0
}

function errusage {
  usage >&2
  exit 1
}

declare -A defaults=(
  [timezone]=America/Chicago
)

while getopts -- "-:hz:" opt; do
  case $opt in
    -)
      longopt=${OPTARG%%=*}
      [[ $OPTARG == *=* ]] && longoptarg=${OPTARG#*=} || longoptarg=
      case $longopt in
        start_time) [[ -z $longoptarg ]] && errusage
          start_time=$longoptarg
          ;;
        end_time) [[ -z $longoptarg ]] && errusage
          end_time=$longoptarg
          ;;
        timezone) [[ -z $longoptarg ]] && errusage
          timezone=$longoptarg
          ;;
        help) usage
          ;;
        *) errusage
      esac
        ;;

    z) timezone=$OPTARG
      ;;
    h) usage
      ;;
    *) errusage
  esac
done
shift $((OPTIND-1))

logsdir=$1

[[ -z $logsdir ]] && errusage

echo "Getting logs from $logsdir"

pachd_logs=($logsdir/pachd/pods/*/pachd/logs-loki.txt)
envoy_logs=($logsdir/pachyderm-proxy/pods/*/envoy/logs-loki.txt)
pgbouncer_logs=($logsdir/pg-bouncer/pods/*/pg-bouncer/logs-loki.txt)
declare -A logfiles=(
  [pachd]=$pachd_logs
  [envoy]=$envoy_logs
  [pgbouncer]=$pgbouncer_logs
)

echo "Using pachd logs ${logfiles[pachd]}"
echo

echo "API timings from envoy proxy to pachd and back"
echo

grep '^{' ${logfiles[pachd]} |
mlr --json --no-jlistwrap having-fields --at-least time,message then filter -s start_time=$start_time -s end_time=$end_time '
  (@start_time == "" || $time >= @start_time) &&
  (@end_time == "" || $time <= @end_time) &&
  $message =~ "(request|response) for.*/(.*)"
' then put '

  begin {
    @pachd = {}
  }

  re = strmatchx($message, "(request|response) for.*/(.*)");

  msgtype = re["captures"][1];
  api = re["captures"][2];

  msgid = $["x-request-id"][1];
  @pachd[msgid][msgtype].time = $time;
  @pachd[msgid][msgtype].epochns = strpntime($time, "%FT%H:%M:%SZ");
  @pachd[msgid].api = api;
  @pachd[msgid].duration = $duration;

  filter false;

  end {
    print "pachd.request.time", "api", "pachd.time_taken_sec", "pachd.response.duration", "pachd.response.time";
    for(id in @pachd) {
      if(!haskey(@pachd[id], "request")) {
        @pachd[id].request.time = "unknown"
      }
      if(!haskey(@pachd[id], "response")) {
        @pachd[id].response.time = "unknown";
        @pachd[id].duration = "unknown"
      }
      var time_taken_sec = "unknown";
      if(@pachd[id].request.time != "unknown" && @pachd[id].response.time != "unknown") {
        time_taken_sec = (@pachd[id].response.epochns - @pachd[id].request.epochns)/10**9
      }
    print @pachd[id].request.time, @pachd[id].api, time_taken_sec, @pachd[id].duration, @pachd[id].response.time
    }
  }
'
