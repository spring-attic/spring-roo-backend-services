#/bin/shell

usage() {
cat << EOF
usage: $0 options

OPTIONS:
    -d       Dry run (does not change public repository files)
    -v       Verbose
    -h       Show this message

DESCRIPTION:
    Synchronizes JARs from the spring-roo-repository.springsource.org and
    produces the repository.xml and repository.xml.zip. The produced files
    are subsequently published to the public repository for consumption.
    The following directories are all createdautomatically and can be removed
    at any time if desired without problems: ./mirror, ./lib and ./work.

REQUIRES:
    s3cmd (ls should list the SpringSource buckets)
    zip and other common *nix commands
EOF
}

log() {
    if [ "$VERBOSE" = "1" ]; then
        echo "$@"
    fi
}

l_error() {
    echo "### ERROR: $@"
}

VERBOSE='0'
DRY_RUN='0'
while getopts "vdh" OPTION
do
    case $OPTION in
        h)
            usage
            exit 1
            ;;
        d)
            DRY_RUN=1
            ;;
        v)
            VERBOSE=1
            ;;
        ?)
            usage
            exit
            ;;
    esac
done

type -P zip &>/dev/null || { l_error "zip not found. Aborting." >&2; exit 1; }

PRG="$0"

while [ -h "$PRG" ]; do
    ls=`ls -ld "$PRG"`
    link=`expr "$ls" : '.*-> \(.*\)$'`
    if expr "$link" : '/.*' > /dev/null; then
        PRG="$link"
    else
        PRG=`dirname "$PRG"`/"$link"
    fi
done
SCRIPT_HOME=`dirname "$PRG"`

# Absolute path
SCRIPT_HOME=`cd "$SCRIPT_HOME" ; pwd`
log "Location.......: $SCRIPT_HOME"

# Important: do _not_ add a trailing slash to the MIRROR_DIR (formatting is important in many operations that follow)
MIRROR_DIR="$SCRIPT_HOME/mirror"
log "Target Dir.....: $MIRROR_DIR"
MIRROR_DIR_LENGTH="${#MIRROR_DIR}"
MIRROR_DIR_CUT_LENGTH=`expr $MIRROR_DIR_LENGTH + 1`

# Do not add a trailing slash to WORK_DIR either
WORK_DIR="$SCRIPT_HOME/work"
log "Work Dir......: $MIRROR_DIR"

# Do not add a trailing slash to LIB_DIR either
LIB_DIR="$SCRIPT_HOME/lib"
log "Library Dir...: $LIB_DIR"
BINDEX_JAR="$LIB_DIR/bindex.jar"
log "Bindex JAR....: $BINDEX_JAR"

# Include Git-related info in the log for diagnostics of which version of the script is being used
GIT_HASH=`git log "--pretty=format:%H" -n1 $SCRIPT_HOME`
log "Git Hash.......: $GIT_HASH"

mkdir -p $MIRROR_DIR

# Lib dir is where we keep Bindex between runs; we download it on demand if it's missing
mkdir -p $LIB_DIR

# Work dir is where we keep files for just this run, and we want it clean each time
rm -rf $WORK_DIR
mkdir -p $WORK_DIR

# Start by getting Bindex if necessary
if [ ! -f $BINDEX_JAR ]; then
    log "Unable to find $BINDEX_JAR"
    WGET_OPTS="-q"
    if [ "$VERBOSE" = "1" ]; then
        WGET_OPTS="-v"
    fi
    wget $WGET_OPTS --output-document=$BINDEX_JAR http://www.osgi.org/download/bindex.jar
    if [[ ! "$?" = "0" ]]; then
        l_error "wget was unable to download http://www.osgi.org/download/bindex.jar" >&2; exit 1;
    fi
    log "Downloaded $BINDEX_JAR"
fi

# Setup S3 correctly
type -P s3cmd &>/dev/null || { l_error "s3cmd not found. Aborting." >&2; exit 1; }
S3CMD_OPTS=''
if [ "$DRY_RUN" = "1" ]; then
    S3CMD_OPTS="$S3CMD_OPTS --dry-run"
fi
if [ "$VERBOSE" = "1" ]; then
    S3CMD_OPTS="$S3CMD_OPTS -v"
fi

# Prune local files and directories which no longer exist remotely
log "Prune phase: getting list of all JARs from S3"
s3cmd $S3CMD_OPTS -r ls s3://spring-roo-repository.springsource.org/ | cut -c "30-"> $WORK_DIR/dist_all.txt
if [[ ! "$?" = "0" ]]; then
    l_error "s3cmd failed." >&2; exit 1;
fi
log "Prune phase: comparing with local files to detect local deletions required"
find $MIRROR_DIR -iname \* > $WORK_DIR/dist_local.txt
cat $WORK_DIR/dist_local.txt | cut -c "$MIRROR_DIR_CUT_LENGTH-" > $WORK_DIR/dist_local_cut.txt
for cut_filename in `cat $WORK_DIR/dist_local_cut.txt`; do
    REMOTE_FILENAME="s3://spring-roo-repository.springsource.org$cut_filename"
    LOCAL_FILENAME="$MIRROR_DIR""$cut_filename"
    grep -q "$REMOTE_FILENAME" $WORK_DIR/dist_all.txt
    if [[ "$?" = "1" ]]; then
        # We need to rm -rf as it might be a directory
        if [[ "$DRY_RUN" = "0" ]]; then
            log "$REMOTE_FILENAME not found; removing $LOCAL_FILENAME"
            rm -rf $LOCAL_FILENAME
        else
            log "$REMOTE_FILENAME not found; would remove $LOCAL_FILENAME (but -d specified for a dry run only)"
        fi
    fi
done
echo "Prune phase: completed"

# Get all JAR files
log "Sync phase: getting all JARs from S3"
s3cmd $S3CMD_OPTS get --skip-existing --recursive --exclude '*' --include '*.jar' s3://spring-roo-repository.springsource.org/ $MIRROR_DIR/
if [[ ! "$?" = "0" ]]; then
    l_error "s3cmd failed." >&2; exit 1;
fi
log "Sync phase: JARs obtained from S3"

# Find all JARs under the current directory
# Excluding snapshots, sources, annotations, bootstrap, mojos and ((1.0.0 or 1.1.0 versioned) or (wrapping JARs))
# This means it's legal to have a 1.0.0 versioned item in wrapping and it will be discovered, but not outside wrapping
find $MIRROR_DIR/ \( -name \*.jar ! -name \*.BUILD\*.jar ! -name \*-sources.jar ! -name \*annotations-\*.jar ! -name \*.mojo.addon\*.jar ! -name \*.bootstrap\*.jar \) -a \( \( ! -name \*-1.0.0\*.jar ! -name \*-1.1.0\*.jar \) -o \( -name *wrapping*.jar  \)  \) | sort > $WORK_DIR/all_files.txt

# Work out the unique directories present in all_files.txt
cat $WORK_DIR/all_files.txt | sed 's/[a-z|A-Z|0-9|.|-]*.jar//g' | uniq > $WORK_DIR/dirnames.txt

JARS=''
for dirname in `cat $WORK_DIR/dirnames.txt`; do
    LATEST_VERSION_IN_DIRECTORY=`grep "$dirname" $WORK_DIR/all_files.txt | tail -n1`
    JARS="$JARS $LATEST_VERSION_IN_DIRECTORY"
done

# Delete the local repository.xml, repository.xml.zip etc (we'll create fresh ones in a moment)
java -jar $BINDEX_JAR -d $MIRROR_DIR/ -r $WORK_DIR/repository.xml -t http://spring-roo-repository.springsource.org/%p/%f -q $JARS

# Convert the "http" into "httppgp" URLs in repository.xml
cat $WORK_DIR/repository.xml | sed 's/http:\/\/spring-roo-repository/httppgp:\/\/spring-roo-repository/g' > $WORK_DIR/repository.xml.new
rm $WORK_DIR/repository.xml
mv $WORK_DIR/repository.xml.new $WORK_DIR/repository.xml

# ZIP up repository.xml (this is the primary distribution vehicle)
ZIP_OPTS='-q'
if [ "$VERBOSE" = "1" ]; then
    ZIP_OPTS='-v'
fi
zip $ZIP_OPTS -j $WORK_DIR/repository.xml.zip $WORK_DIR/repository.xml
if [[ ! "$?" = "0" ]]; then
    l_error "zip failed." >&2; exit 1;
fi

# Some statistics for the log
SIZE_XML=$(stat -c%s "$WORK_DIR/repository.xml")
SIZE_ZIP=$(stat -c%s "$WORK_DIR/repository.xml.zip")
log "XML Size......: $SIZE_XML"
log "ZIP Size......: $SIZE_ZIP"

# Send the new repository files up to S3
log "Sync phase: uploading replacement repository.xml and repository.xml.zip"
s3cmd $S3CMD_OPTS put -P $WORK_DIR/repository.* s3://spring-roo-repository.springsource.org/roobot/
if [[ ! "$?" = "0" ]]; then
    l_error "s3cmd failed." >&2; exit 1;
fi

log "Completed successfully"

#java -jar bindex.jar
#               [-help] 
#               [-d rootdir ] 
#               [-r repository.xml (.zip ext is ok)] 
#               [-l file:license.html ] 
#               [-t http://w.com/servl?s=%s&v=%v %s=symbolic-name
#                       %v=version %p=relative path %f=name] 
#               [-q (quiet) ]
#               <jar file>*

