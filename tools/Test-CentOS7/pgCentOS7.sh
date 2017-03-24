#!/bin/bash


# Copyright © 2017 Hendrik Siewert <hendrik.siewert@credativ.de>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

# config
PG_VERSION=9.5
PGVERSION=95
PG_CTL=/usr/pgsql-$PG_VERSION/bin/pg_ctl
TESTDIR=/var/lib/pgglaskugel-test
PGDATA=$TESTDIR/$PG_VERSION/data
ARCHIVEDIR=$TESTDIR/backup/pgglaskugel
MINIO=/var/lib/minio
DBUSER=postgres
DBUSER_DO="sudo -u $DBUSER"

cleanup()
{
  echo "Clean everything..."
  $DBUSER_DO $PG_CTL stop -D $PGDATA -s -m fast
  pkill minio > /dev/null 2>&1
  if [ -d $TESTDIR ]
    then
      rm -rf $TESTDIR
  fi
  if [ -d $MINIO ]
    then
      rm -rf $MINIO
  fi
  if [ -d /root/.minio ]
    then
      rm -rf /root/.minio
  fi
  if [ -f /usr/bin/pgglaskugel ]
    then
      rm /usr/bin/pgglaskugel
  fi
  if [ -f /usr/bin/minio ]
    then
      rm /usr/bin/minio
  fi
}

getPostgressetup()
{
  cat > /usr/pgsql-$PG_VERSION/bin/postgresql$PGVERSION-setup << EOL 
#!/bin/bash
PGVERSION=9.5.6
PGMAJORVERSION=`echo "\$PGVERSION" | sed 's/^\([0-9]*\.[0-9]*\).*$/\1/'`
PGENGINE=/usr/pgsql-9.5/bin
PREVMAJORVERSION=9.4
PREVPGENGINE=/usr/pgsql-\$PREVMAJORVERSION/bin

# The second parameter is the new database version, i.e. \$PGMAJORVERSION in this case.
SERVICE_NAME="\$2"
if [ x"\$SERVICE_NAME" = x ]
then
    SERVICE_NAME=postgresql-\$PGMAJORVERSION
fi
OLD_SERVICE_NAME="\$3"
if [ x"\$OLD_SERVICE_NAME" = x ]
then
    OLD_SERVICE_NAME=postgresql-\$PREVMAJORVERSION
fi
case "$1" in
    --version)
        echo "postgresql-setup \$PGVERSION"
        exit 0
        ;;
esac
PGDATA=$PGDATA
PGLOG=$TESTDIR/$PG_VERSION/initdb.log

if [ -z "\$PGDATA" ]
  then
    echo "ERROR setting PGDATA"
fi
export PGDATA

SU=su

script_result=0
perform_initdb(){
    if [ ! -e "\$PGDATA" ]; then
        mkdir -p "\$PGDATA" || return 1
        chown $DBUSER:$DBUSER "\$PGDATA"
        chmod go-rwx "\$PGDATA"
    fi
    # Clean up SELinux tagging for PGDATA
    [ -x /sbin/restorecon ] && /sbin/restorecon "\$PGDATA"

    # Create the initdb log file if needed
    if [ ! -e "\$PGLOG" -a ! -h "\$PGLOG" ]; then
        touch "\$PGLOG" || return 1
        chown $DBUSER:$DBUSER "\$PGLOG"
        chmod go-rwx "\$PGLOG"
        [ -x /sbin/restorecon ] && /sbin/restorecon "\$PGLOG"
    fi

    # Initialize the database
    initdbcmd="\$PGENGINE/initdb --pgdata='\$PGDATA' --auth='ident'"
    initdbcmd+=" \$PGSETUP_INITDB_OPTIONS"

    \$SU -l $DBUSER -c "\$initdbcmd" >> "\$PGLOG" 2>&1 < /dev/null

    # Create directory for postmaster log files
    mkdir "\$PGDATA/pg_log"
    chown $DBUSER:$DBUSER "\$PGDATA/pg_log"
    chmod go-rwx "\$PGDATA/pg_log"
    [ -x /sbin/restorecon ] && /sbin/restorecon "\$PGDATA/pg_log"

    if [ -f "\$PGDATA/PG_VERSION" ]; then
        return 0
    fi
    return 1
}
initdb(){
    if [ -f "\$PGDATA/PG_VERSION" ]; then
        echo $"Data directory is not empty!"
        echo
        script_result=1
    else
        echo -n $"Initializing database ... "
        if perform_initdb; then
            echo $"OK"
        else
            echo $"failed, see \$PGLOG"
            script_result=1
        fi
        echo
    fi
}

case "\$1" in
    initdb)
        initdb
        ;;
    *)
        echo >&2 "ERROR while setting up postgresql"
        exit 2
esac

exit \$script_result
EOL
}

returnfunc(){
  if [ $# -eq 2 ]
    then
      if [ $1 -eq 1 ]
        then
          echo "ERROR in function: $2"
          echo " Exiting..."
          exit 1
      fi
  fi
}

# check distro and version
checkdistroversion()
{
  var=$(cat /etc/os-release | grep ID | head -1 | cut -d"=" -f2 | grep centos)
  var2=$(cat /etc/os-release | grep VERSION_ID | cut -d"\"" -f2)
  if [[ ! -z "$var" ]]
    then
      if [[ ! $var2 =~ ^7.* ]]
        then
          echo "Nicht Version 7 von CentOS"
          exit 1
      fi
    else
      echo "Kein CentOS 7 installiert"
      exit 1
  fi
  echo "Seems like a CentOS7 version..."
}

installpackages()
{
  echo "Installing needed tools..."
  yum -y -q install sudo lsof wget rng-tools
  yum -y -q install https://download.postgresql.org/pub/repos/yum/9.5/redhat/rhel-7-x86_64/pgdg-centos95-9.5-3.noarch.rpm
  yum -y -q install postgresql95 postgresql95-server
  yum -y -q install https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
  yum -y -q install zstd
}


minioinstall()
{
  echo "Getting Minio..."
  wget https://dl.minio.io/server/minio/release/linux-amd64/minio > /dev/null
  chmod 755 minio
  mv ./minio /usr/bin
}

miniostart()
{
  echo "Starting Minio Server..."
  minio server --address 127.0.0.1:9000 -C "/root/.minio" $MINIO &
  while [ -z "$(lsof -i :9000)" ]
    do
      echo "Wait for Minio to listen..."
      sleep 2
    done
  chown $DBUSER:$DBUSER $MINIO 
  chmod -R 700 $MINIO
}

miniogetkeys()
{
  echo "Looking for Minio keys..."
  if [ ! -f /root/.minio/config.json ]
    then
      echo "config.json missing in /root/.minio... :/"
      exit 1
  fi
  accesskey=$(cat /root/.minio/config.json | grep accessKey | cut -d":" -f2 | cut -d"\"" -f2)
  secretkey=$(cat /root/.minio/config.json | grep secretKey | cut -d":" -f2 | cut -d"\"" -f2)
  echo "ACCESS KEY:$accesskey"
  echo "SECRET KEY:$secretkey"
}

miniocheck()
{
  if [ ! -f /usr/bin/minio ] && [ ! -d /var/lib/minio ]
    then
      minioinstall
      miniostart
      miniogetkeys
    elif [ ! -z "$(lsof -i :9000)" ]
      then
        miniogetkeys
    else
      echo "Installing/Starting Minio went wrong!"
      exit 1
  fi
}

testingnoenc()
{
  echo "TESTING IF FILES ARE READABLE..."
  if [ -z "$(zstdcat $enctest)" ]
    then
      echo "Can't read basebackup..."
      exit 1
    elif [ -z "$(zstdcat $walenctest)" ]
      then
        echo "Can't read wal files..."
        exit 1
    else
      echo "Successfully read archived files!"
  fi
}

encrypttest()
{
  if [ "$1" == "file" ]
    then
      enctest=$ARCHIVEDIR/basebackup/$(ls $ARCHIVEDIR/basebackup)
      walenctest=$ARCHIVEDIR/wal/$(ls $ARCHIVEDIR/wal | head -1)
    elif [ "$1" == "s3" ]
      then
        enctest=$MINIO/basebackup/$(ls $MINIO/basebackup)
        walenctest=$MINIO/wal/$(ls $MINIO/wal | head -1)
    else
      echo "ERROR: Encryption test parameters failed"
      exit 1
  fi
  if [ -z "$enctest" ] || [ -z "$walenctest" ]
    then
      echo "Can't find archived files..."
      exit 1
  fi
  if [ ! -z "$2" ]
    then
      if [ "$2" == "noenc" ]
        then
          testingnoenc
        elif [ "$2" == "enc" ]
          then
            testingenc
        else
          echo "WRONG PARAMETERS in function: encrypttest"
          exit 1
      fi
    else
      echo "SECOND PARAMETER ISN'T GIVEN in function: encrypttest"
      exit 1
  fi    
}

testingenc()
{
  echo "TESTING IF FILES ARE ENCRYPTED..."
  if [ $(zstd -d $enctest > /dev/null 2>&1) ]
    then
      echo "BASEBACKUP DID NOT GET ENCRYPTED!!!"
      exit 1
    elif [ $(zstd -d $walenctest > /dev/null 2>&1) ]
      then
        echo "WAL FILES DID NOT GET ENCRYPTED"
        exit 1
    else
      echo "Successfully encrypted!"
  fi
}

cleandirs()
{
  if [ -d $PGDATA ]
    then
      if [ ! -z "$(ls $PGDATA)" ]
        then
          $DBUSER_DO $PG_CTL  stop -D $PGDATA -s -m fast
          rm -rf $PGDATA/*   
          echo "Cleaning data dir..."
      fi
  fi
  if [ -d $ARCHIVEDIR/basebackup/ ]
    then
      if [ ! -z "$(ls $ARCHIVEDIR/basebackup/)" ]
        then
          rm -rf $ARCHIVEDIR/basebackup/*
          rm -rf $ARCHIVEDIR/wal/*
          echo "Cleaning pgGlaskugel basebackup..."
      fi
  fi
  if [ -d $MINIO ]
    then
      if [ ! -z "$(ls $MINIO)" ]
        then
          rm -rf $MINIO/*
          echo "Cleaning Minio folders..."
      fi
  fi
}

pathglaskugel()
{
  if [ -f "$1" ]
    then
      cp $1 /usr/bin
      retval=$?
  elif [ -d "$1" ]
    then
      cp $1/pgglaskugel /usr/bin
      retval=$?
    else
      echo "Path is wrong"
      exit 1
  fi
  if [ $retval -eq 0 ]
    then
      echo "pgGlaskugel successfully moved to /usr/bin/"
    else
      echo "Error: Moving pgGlaskugel to /usr/bin/ failed..."
      exit 1
  fi
}

gpgcheck()
{
  if [ -z "$($DBUSER_DO gpg -k | grep pub | sed 1d | cut -d"/" -f 2 | cut -d" " -f1)" ]
    then
      createKeyPair
    else
      echo "Found gpg keys from $DBUSER ..."
      echo "Let's use them to encrypt/decrypt!"
  fi
}

createKeyPair()
{
  rngd -r /dev/urandom
cat > $TESTDIR/foo << EOL
%echo Generating a default key
Key-Type: default
Subkey-Type: default
Name-Real: Hen Tester
Name-Comment: Test
Name-Email: hen@foo.bar
%no-protection
Expire-Date: 0
%commit
%echo done
EOL
  chown $DBUSER $TESTDIR/foo
  $DBUSER_DO gpg --batch --gen-key $TESTDIR/foo
}

Init ()
{
  echo "Configuring new cluster..."
  $DBUSER_DO $PG_CTL start -D $PGDATA -w -t 300 > /dev/null  2>&1
  returnfunc $? "Init"
  echo "Editing pg_hba.conf..."
cat > $PGDATA/pg_hba.conf << EOL
host    all             all             127.0.0.1/32            md5
local   all             $DBUSER                                ident
local   replication     $DBUSER                                ident
host    replication     $DBUSER        127.0.0.1/32            md5
EOL
  chown -R $DBUSER $TESTDIR
  echo "Set $DBUSER password to $DBUSER..."
  $DBUSER_DO psql -c "alter user $DBUSER with password '$DBUSER';"
  echo "Reloading the pg_hba.conf..."
  $DBUSER_DO psql -c "select pg_reload_conf();"
}

prepareconfigfolder()
{
  mkdir -p $PGDATA
  chown -R $DBUSER:$DBUSER $TESTDIR
  chmod -R 700 $TESTDIR
  if [ ! -d $TESTDIR/.pgglaskugel ]
    then
      mkdir $TESTDIR/.pgglaskugel
  fi
}

pickconfig()
{
  if [ "$1" == "s3" ]
    then
      if [ "$2" == "enc" ]
        then
          s3config
      elif [ "$2" == "noenc" ]
        then
          s3confignoenc
        else
          echo "Error in function: pickconfig. Wrong parameters..."
          exit 1
      fi
  elif [ "$1" == "file" ]
    then
      if [ "$2" == "enc" ]
        then
          fileconfig
      elif [ "$2" == "noenc" ]
        then
          fileconfignoenc
        else
          echo "Error in function: pickconfig. Wrong parameters..."
          exit 1
      fi
    else
      echo "Error in function: pickconfig. Wrong parameters..."
      exit 1
  fi   
}

s3config()
{
cat > $TESTDIR/.pgglaskugel/config.yml << EOL
---
encrypt: true
debug: true
recipient: hen@foo.bar
archive_to: s3
backup_to: s3
s3_access_key: $accesskey
s3_secret_key: $secretkey
s3_ssl: false
pgdata: $PGDATA
archivedir: $ARCHIVEDIR
s3_bucket_backup: basebackup
s3_bucket_wal: wal
EOL
}

s3confignoenc()
{
cat > $TESTDIR/.pgglaskugel/config.yml << EOL
---
encrypt: false
debug: true
archive_to: s3
backup_to: s3
s3_access_key: $accesskey
s3_secret_key: $secretkey
s3_ssl: false
pgdata: $PGDATA
archivedir: $ARCHIVEDIR
s3_bucket_backup: basebackup
s3_bucket_wal: wal
EOL
}

fileconfig()
{
cat > $TESTDIR/.pgglaskugel/config.yml << EOL
---
encrypt: true
debug: true
recipient: hen@foo.bar
pgdata: $PGDATA
archivedir: $ARCHIVEDIR
EOL
}

fileconfignoenc()
{
cat > $TESTDIR/.pgglaskugel/config.yml << EOL
---
encrypt: false 
debug: true
pgdata: $PGDATA
archivedir: $ARCHIVEDIR
EOL
}

pgglaskugelsetup()
{
  ##################################Fix##################################
  mkdir -p $TESTDIR/backup/pgglaskugel/basebackup
  chown -R $DBUSER $TESTDIR/backup
  #######################################################################
  
  echo "Starting pgGlaskugel setup..."
  $DBUSER_DO pgglaskugel setup --config $TESTDIR/.pgglaskugel/config.yml
  $DBUSER_DO $PG_CTL stop -D $PGDATA -s -m fast
  returnfunc $? "pgglaskugelsetup"
  $DBUSER_DO $PG_CTL start -D $PGDATA -s -w -t 300
  returnfunc $? "pgglaskugelsetup"
}

pgglaskugelbasebackup()
{
  #test data
  $DBUSER_DO psql -c "create table test0 (num int, Primary Key(num));"
  returnfunc $? "pgglaskugelbasebackup"
  $DBUSER_DO psql -c "create table test1 (num int, Primary Key(num));"
  returnfunc $? "pgglaskugelbasebackup"
  echo "Creating basebackup"
  $DBUSER_DO pgglaskugel basebackup --config $TESTDIR/.pgglaskugel/config.yml
  returnfunc $? "pgglaskugelbasebackup"
  #another one
  $DBUSER_DO psql -c "create table test2 (num int, Primary Key(num));"
  returnfunc $? "pgglaskugelbasebackup"
  #switch_xlog
  $DBUSER_DO psql -c "SELECT pg_switch_xlog();"
  #save tables in var
  Test1=$($DBUSER_DO psql -c "\dt")
}

pgglaskugelrestore()
{
  echo "restoring backup..."
  if [ "$1" == "file" ]
    then
      backupfilezst=$(ls $ARCHIVEDIR/basebackup)
    elif [ "$1" == "s3" ]
      then
        backupfilezst=$(ls $MINIO/basebackup)
    else
      echo "ERROR: No Backupdirectory specified"
      exit 1
  fi
  if [[ -z "$backupfilezst" ]]
    then
      echo "No backup file found!"
      exit 1
    else
      echo "backup file $backupfilezst found"
  fi
  backupfilezst=$(basename $backupfilezst .zst)
  $DBUSER_DO pgglaskugel restore $backupfilezst $PGDATA --config $TESTDIR/.pgglaskugel/config.yml
}

testingtables()
{
  ## Compare postgres tables. save \dt in variables and compare
  Test2=$($DBUSER_DO psql -c "\dt")
  echo "TESTING NOW..."
  echo "Tables in the first cluster:"
  echo "$Test1"
  echo "Tables in the second cluster:"
  echo "$Test2"
  if [ "$Test1" == "$Test2" ] && [[ $Test1 =~ .*test0.*test1.*test2.* ]] && [[ $Test2 =~ .*test0.*test1.*test2.* ]] 
    then
      echo "THIS TEST WAS SUCCESSFUL!"
    else
      echo "Database tables don't match! :("
      exit 1
  fi
}

dropoldcluster()
{
  echo "Dropping old cluster..."
  $DBUSER_DO $PG_CTL stop -D $PGDATA -s -m fast
  returnfunc $? "dropoldcluster"
  rm -rf $PGDATA/*
}

preparetest()
{
  cleandirs
  /usr/pgsql-$PG_VERSION/bin/postgresql95-setup initdb
  returnfunc $? "preparetest"
  Init
}

runtest()
{
  cd $TESTDIR #no permission denied
  if [ -z "$1" ] || [ -z "$2" ]
    then
      echo "ERROR in function: runtest (Wrong parameters)..."
      exit 1
  fi
  preparetest
  if [ "$1" == "s3" ]
    then
      ARCHIVEDIR=$MINIO
      miniocheck
    else
      ARCHIVEDIR=$TESTDIR/backup/pgglaskugel
  fi
  if [ "$2" == "enc" ]
    then
      gpgcheck
  fi
  pickconfig $1 $2
  pgglaskugelsetup
  pgglaskugelbasebackup
  encrypttest $1 $2
  dropoldcluster
  pgglaskugelrestore $1
  Init
  encrypttest $1 $2
  testingtables
}

trap cleanup 0 2 3 15
#######################################################################
###############################START###################################
#######################################################################
start=$(date +%s)
# Check arguments
if [ ! -f /usr/bin/pgglaskugel ]
  then
    if [ ! -f ./pgglaskugel ]
      then
        if [ $# -ne 1 ]
          then
            echo "Usage: $0 <Path to pgGlaskugel>"
            exit 1
          else
            pathglaskugel $1
        fi
      else
        pathglaskugel .
    fi
fi

echo "Check if CentOS7..."
checkdistroversion
installpackages
getPostgressetup
prepareconfigfolder
echo "#RUNNING S3 TEST WITH ENCRYPTION#"
runtest s3 enc
echo "#RUNNING S3 TEST WITHOUT ENCRYPTION#"
runtest s3 noenc
echo "#RUNNING FILE TEST WITH ENCRYPTION#"
runtest file enc
echo "#RUNNING FILE TEST WITHOUT ENCRYPTION#"
runtest file noenc
echo "#ALL TESTS WERE SUCCESSFUL#"
end=$(date +%s)
echo "Runtime: $((end-start))s"
exit 0
