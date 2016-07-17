#!/bin/bash
# Script to start the job server
# Extra arguments will be spark-submit options, for example
#  ./server_start.sh --jars cassandra-spark-connector.jar
#
# Environment vars (note settings.sh overrides):
#   JOBSERVER_MEMORY - defaults to 1G, the amount of memory (eg 512m, 2G) to give to job server
#   JOBSERVER_CONFIG - alternate configuration file to use
#   JOBSERVER_FG    - launches job server in foreground; defaults to forking in background
set -e

get_abs_script_path() {
  pushd . >/dev/null
  cd "$(dirname "$0")"
  appdir=$(pwd)
  popd  >/dev/null
}

get_abs_script_path

. $appdir/setenv.sh

GC_OPTS="-XX:+UseConcMarkSweepGC
         -verbose:gc -XX:+PrintGCTimeStamps -Xloggc:$appdir/gc.out
         -XX:+CMSClassUnloadingEnabled "

# To truly enable JMX in AWS and other containerized environments, also need to set
# -Djava.rmi.server.hostname equal to the hostname in that environment.  This is specific
# depending on AWS vs GCE etc.
JAVA_OPTS="-XX:MaxDirectMemorySize=$MAX_DIRECT_MEMORY \
           -XX:+HeapDumpOnOutOfMemoryError -Djava.net.preferIPv4Stack=true \
           -Dcom.sun.management.jmxremote.port=$JMX_PORT \
           -Dcom.sun.management.jmxremote.rmi.port=$JMX_PORT \
           -Dcom.sun.management.jmxremote.authenticate=false \
           -Dcom.sun.management.jmxremote.ssl=false"

MAIN="spark.jobserver.JobServer"

PIDFILE=$appdir/spark-jobserver.pid
if [ -f "$PIDFILE" ] && kill -0 $(cat "$PIDFILE"); then
   echo 'Job server is already running'
   exit 1
fi

# David Gosalvez 20160715
# Dependency management strategy for Signals
# signals-spark-command-assembly-0.1.jar contains our commands (SparkApps)
# the jar is fattened with aws and databricks dependencies
# spark-job-server.jar is needed because NewSparkJobs defined in signals-spark-command depend on
# job-server types such as JobData and JobOutput
# We use local:// because we know that the above jars are available in all executor nodes.  Doing so
# is more efficient than relying on the driver to distribute the dependencies
# The aws dependency is also provided via --packages.  Without it the driver program fails.
# I think this is because there are more sub-dependencies that were not package properly into our fat jar.

cmd='$SPARK_HOME/bin/spark-submit --class $MAIN --driver-memory $JOBSERVER_MEMORY
  --deploy-mode client
  --conf "spark.executor.extraJavaOptions=$LOGGING_OPTS"
  --driver-java-options "$GC_OPTS $JAVA_OPTS $LOGGING_OPTS $CONFIG_OVERRIDES"
  --jars local://$SPARK_JOBSERVER_HOME/spark-job-server.jar,local://$SPARK_HOME/jars/signals-spark-command-assembly-0.1.jar
  --packages org.apache.hadoop:hadoop-aws:2.6.3
  $@ $appdir/spark-job-server.jar $conffile'
if [ -z "$JOBSERVER_FG" ]; then
  eval $cmd > $LOG_DIR/server_start.log 2>&1 < /dev/null &
  echo $! > $PIDFILE
else
  eval $cmd
fi
