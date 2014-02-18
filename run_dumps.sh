#!/bin/sh
# ---------------------------------------------------------------
# JG (Not Guthrie) 2013/04/01  Joe Gibbs 
# Script name: run_dumps.sh.v1.9
#  v1.5 - added comments, moved user variables to the top
#       - added a few more if tests (gzip, dbname list, etc)
#  v1.6 - Added code to get list of all db names vrs a hardcoded list
#         moved log files to $DumpDir, added code to rm old log files
#         if mkdir for host/logs fails, exit program
#  v1.7 - Have separate dump dirs for each port.
#         Moved log file to /home/mysql/scripts/logs
#         add subroutine for sending email, cleaning up old log files 
#         and adding msg to the log file
#  v1.8   2013-12-1- Joe Gibbs
#         Added code to allow max days to be different per instance
#         Added code to gzip on the fly, after dump or not at all.
#  v1.9   2014-01-03- Joe Gibbs
#         Modified find command on post dump processing to use database nam prefix
#         This removes the directory from the find results and cleans up the ls -l results
#         Fixed name of DSPW variable
# Simple script to run mysqldumps
#  mainline loops through the DBs_3306 and DBs_3307 variables 
#  runs 2 mysql dumps (data/schema and just the schema) 
#  runs a gzip just on the data file if GZIP_it is enabled 
#  uses a find command to remove files in the specific dump directory older than xx days.
#  Send email if that is enabled, remove old log files 
#
# Planned changes
#  get DSIS/DSPW from a config file
#  Move db servers (port's) to a config file and redo the logic in mainline
#  Save job status (start/complete, dump stats) to a table in a report server
#  Add script help section
# ---------------------------------------------------------------
  DT=$(date "+%F_%H%M%S")
  DOW=$(date +%u)
# or `date "+%y%m%d_%H%M%S"`
# set email fields if desired. "Email_it" turns it on (1) or off (2)
  Email="joseph.gibbs@gcu.edu"
  Email_it=1
# ---------------------------------------------------------------
# 1 for more messages, 0 for less messages
  LongMsgs=0    
  EnvName="MySQL Backup for LC QA Archive DB server(s)"
#
# shhhh !!! we need a mysql login and password 
# DSID="mysqlbk"
  DSID="xxxxxxxxx"
  DSPW="mysql4joe"
# ---------------------------------------------------------------
# MaxHrs is used to remove old dump files based on hours 
#  before completion time of current execution 
#  1440 = 24 hrs (1 day), 
#  2880 = 48 hrs (2 days), 
#  4320 = 72 hrs (3 days)
  MaxDays1=1440
  MaxDays2=2880
  MaxDays3=4320
# MaxHrs=1440 
# 1 days older from now
# ---------------------------------------------------------------
# We use hostname as part of the dump path and in some of the messages 
# and $Host2 as the default -h options for the mysql connection cli tool
  Host1=`hostname`
  Host2=`hostname|awk -F. '{print $1}'`
  Host2="plcddbps2102"
# ---------------------------------------------------------------
# The following is an override for the standard -h$Host2 variable 
#  set it to $Host2 or $Host1 or 127.0.0.1 
#  or socket and then set the correct socket location
  HostNameToUse='127.0.0.1'  # override for mysql -h option set to $Host2 or $Host1 or 127.0.0.1
  HostNameToUse=$Host1  # override for mysql -h option set to $Host2 or $Host1 or 127.0.0.1
  Socket="/db/mysql/3306/configs/mysql.sock"
#
# set a few base directories up
# DumpDir is base directory for the dump files # DumpDir="/mysql_shared/backups/$Host2"
# DumpDir="/db/mysql/backups/$Host2"
  DumpDir="/db_share/mysql/backups/$Host2"
#
# LogDir="$DumpDir/logs"
  LogDir="/home/mysql/scripts/logs"
  if [ ! -d "$LogDir" ]; then
     mkdir -p $LogDir
     MK_RC=$?
     if [ "$MK_RC" != "0" ]; then
        echo "unable to create log directory. Script cancelled"
        exit $MK_RC
     fi
  fi
#
  run_dumps_log="$LogDir/run_dumps_$DT.log"
  echo -e "Running backups on $DT" >  $run_dumps_log # --------------------------------------------------------------------
# enable and set gzip binary location for data dumps, which run in background mode 
# set GZIP_it to 1 (on or true) to gzip the mysql dump files, set to 0 to disable
#   set GZIP_it to 0 to skip gzip'ing the mysql dump files 
#   set GZIP_it to 1 to gzip the mysql dump files after the dump completes
#   set GZIP_it to 2 to gzip while running the mysql dump command
  GZIP_it=2   
  GZIP="/bin/gzip"  
  if [ ! -e "$GZIP" ]; then
     GZIP_it=0
     sub_LogMsg "GZIP binary as $GZIP does not exist - disabling" 
  fi
# --------------------------------------------------------------------
# setting variables for the mysql dump command
  Triggers="--triggers --routines --single-transaction"
  max_allowed_packets="--max-allowed-packe=1024M"
#  the following 2 lines will need to change to reflect -h or socket changes per port
  MYSQLcmd="/usr/local/mysql/bin/mysql -u$DSID -p$DSPW  -h$HostNameToUse"
  MYSQLDUMP="/usr/local/mysql/bin/mysqldump -h$HostNameToUse "
  MYSQLDUMP2="$MYSQLDUMP -u$DSID -p$DSPW   "
#
  DBs_3306=""
  DBs_3307="lcs_jcr mysql"

# DBs_3306="dba lcs lcs_analytics lcs_openfire mysql"
# DBs_3306="dba mysql"
# DBs_3307="lcs_jcr mysql"

# ---------------------------------------------------------------
# subroutines
#
GetListOfDatabases() {
  sub_LogMsg "\tNo dbs listed in cfg info, getting list from db server"
  DBsAll=$($MYSQLcmd -P$Port -N -e"show databases")
  DBLIST_RC=$?
  if [ "$LongMsgs" = '1' ] || [ "$DBLIST_RC" -ne 0 ]; then
     sub_LogMsg "Get list of databases rc=$DBLIST_RC"
  fi
# a little bit of code to skip dbs you dont want to process. 
# could be improved with a single variable a do loop but not today
  DBsAll=$(echo  "$DBsAll" | sed "s/information_schema//g" )
  DBsAll=$(echo  "$DBsAll" | sed "s/performance_schema//g" ) return } 
  # ---------------------------------------------------------------
RunBackup() {
  MaxHrs=$1
  Port=$2
  DBs=$3
  if [ "$DBs" = "" ]; then
     sub_LogMsg "List of DBs for port $Port is empty. Creating one from show databases command "
     GetListOfDatabases
     DBs=$DBsAll
     sub_LogMsg "\tRunning backups of the following databases: $DBs" 
  fi
# figure out the host or socket connection variable

#
  sub_LogMsg "\nprocessing dumps for $Port $DBs" 
  for DB in $DBs
  do
    sub_LogMsg " " 
    sub_LogMsg " Running dump for $Host2 $Port $DB "
    DumpDir2="$DumpDir/$Port/$DB"
    mkdir -p $DumpDir2
# some RC checking on mkdir
    MK_RC=$?
    if [ "$MK_RC" != "0" ]; then
       sub_LogMsg "unable to create dump directory. skipping Dbs on port $Port"
       return  $MK_RC
    fi
# moving forward
    DumpPrefix="${DB}_${DOW}"
# unused --complete-insert --extended-insert
    sub_LogMsg "\t $MYSQLDUMP $Triggers ${DB} $DumpDir2/${DumpPrefix}_${DT}.dmp" 
#
# Start the mysqldump and then maybe compress afterwards #
    if [ "$GZIP_it" = '0' ]; then
       $MYSQLDUMP2 -P$Port $Triggers $max_allowed_packets ${DB} > $DumpDir2/${DumpPrefix}_${DT}_schema_data.dmp
       DUMP_RC1=$?
       $MYSQLDUMP2 -P$Port $Triggers  --no-data ${DB} > $DumpDir2/${DumpPrefix}_${DT}_schema.dmp
       DUMP_RC2=$?
# now test and run post dump compression
       if [ "$GZIP_it" = '1' ]; then
         sub_LogMsg "Running post dump gzip of the data dump file"
        ($GZIP $DumpDir2/${DumpPrefix}_${DT}_schema_data.dmp &)
       fi
       sub_LogMsg "\t completed dump for $Host2 $Port $DB RC=$DUMP_RC1 "
    fi
#
# Start the mysqldump and compress on the fly #
    if [ "$GZIP_it" = '2' ]; then
       sub_LogMsg "Running dump with in-flight gzip of the dump files" 
       $MYSQLDUMP2 -P$Port $Triggers $max_allowed_packets ${DB} | $GZIP > $DumpDir2/${DumpPrefix}_${DT}_schema_data.dmp.gz
       DUMP_RC1=$?
       $MYSQLDUMP2 -P$Port $Triggers  --no-data ${DB} | $GZIP > $DumpDir2/${DumpPrefix}_${DT}_schema.dmp.gz
       DUMP_RC2=$?
    fi
    sub_LogMsg "\t completed dump for $Host2 $Port $DB RC=$DUMP_RC1 " 
    (find $DumpDir2/${DB}* -mmin +$MaxHrs -exec rm {} \; >> $run_dumps_log )
    if  [ "$LongMsgs" = '1' ]; then
        sub_LogMsg "\t Current backups on disk after RM command is:" 
       (find $DumpDir2/${DB}* -mmin +0 -exec ls -lh {} \; >> $run_dumps_log )
    fi
  done
  return
}
# ---------------------------------------------------------------
sub_CleanUpLogFiles() {
#
 (find $LogDir -mmin +$MaxHrs -exec rm {} \; >> $run_dumps_log )
  DT=$(date "+%F_%H%M%S")
return
}
sub_SendEmail() {
  if [ "$Email_it" = '1' ]; then
    (/bin/mail -s "$EnvName Backups on $Host2 $DT" $Email  < $run_dumps_log)
  sub_LogMsg "Emailing job log"  
  fi
return
}
sub_LogMsg() {
  Msg=$@
  echo -e "$Msg" >>  $run_dumps_log
return
}
# ---------------------------------------------------------------
# mainline section
#
# ---------------------------------------------------------------
# MaxDays1=1440
# MaxDays2=2880
# MaxDays3=4320
#
# The following is an override for the standard -h$Host2 variable 
#  set it to $Host2 or $Host1 or 127.0.0.1 
#  or socket and then set the correct socket location
  HostNameToUse='127.0.0.1'  # override for mysql -h option set to $Host2 or $Host1 or 127.0.0.1 # Socket="/db/mysql/3306/configs/mysql.sock"
#
# DumpDir is base directory for the dump files 
# DumpDir="/db/mysql/3306/backups/$Host2"
  RunBackup $MaxDays2 3306 "$DBs_3306"

# DumpDir="/db/mysql/backups/$Host2"
  RunBackup $MaxDays1 3307 "$DBs_3307"
#
  sub_LogMsg "Completed backups on $DT" 
  sub_SendEmail
  sub_CleanUpLogFiles
exit
