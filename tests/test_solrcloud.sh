#!/usr/bin/env bash
#  vim:ts=4:sts=4:sw=4:et
#
#  Author: Hari Sekhon
#  Date: 2016-01-22 21:13:49 +0000 (Fri, 22 Jan 2016)
#
#  https://github.com/harisekhon/nagios-plugins
#
#  License: see accompanying Hari Sekhon LICENSE file
#
#  If you're using my code you're welcome to connect with me on LinkedIn and optionally send me feedback
#
#  https://www.linkedin.com/in/harisekhon
#

set -euo pipefail
[ -n "${DEBUG:-}" ] && set -x
srcdir2="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

cd "$srcdir2/.."

. ./tests/utils.sh

srcdir="$srcdir2"

echo "
# ============================================================================ #
#                               S o l r C l o u d
# ============================================================================ #
"

export SOLR_VERSIONS="${@:-${SOLR_VERSIONS:-latest 4.10 5.5 6.0 6.1}}"

SOLR_HOST="${DOCKER_HOST:-${SOLR_HOST:-${HOST:-localhost}}}"
SOLR_HOST="${SOLR_HOST##*/}"
export SOLR_HOST="${SOLR_HOST%%:*}"
export SOLR_PORT=8983
export SOLR_ZOOKEEPER_PORT="9983"
export SOLR_PORTS="$SOLR_PORT 8984 $SOLR_ZOOKEEPER_PORT"
export ZOOKEEPER_HOST="$SOLR_HOST"

export SOLR_HOME="/solr"
export MNTDIR="/pl"

startupwait 30

check_docker_available

docker_exec(){
    docker-compose exec "$DOCKER_SERVICE" $MNTDIR/$@
}

test_solrcloud(){
    local version="$1"
    # SolrCloud 4.x needs some different args / locations
    if [ ${version:0:1} = 4 ]; then
        four=true
        export SOLR_COLLECTION="collection1"
    else
        four=""
        export SOLR_COLLECTION="gettingstarted"
    fi
    echo "Setting up SolrCloud $version docker test container"
    #DOCKER_OPTS="-v $srcdir/..:$MNTDIR"
    #launch_container "$DOCKER_IMAGE:$version" "$DOCKER_CONTAINER" $SOLR_PORTS
    VERSION="$version" docker-compose up -d
    solr_port="`docker-compose port "$DOCKER_SERVICE" "$SOLR_PORT" | sed 's/.*://'`"
    local SOLR_PORT="$solr_port"
    solr_zookeeper_port="`docker-compose port "$DOCKER_SERVICE" "$SOLR_ZOOKEEPER_PORT" | sed 's/.*://'`"
    local SOLR_ZOOKEEPER_PORT="$solr_port"
    #solr_ports=`{ for x in $SOLR_PORTS; do docker-compose port "$DOCKER_SERVICE" "$x"; done; } | sed 's/.*://'`
    #local SOLR_PORTS="$solr_ports"
    when_ports_available "$startupwait" "$SOLR_HOST" "$SOLR_PORT" "$SOLR_ZOOKEEPER_PORT"
    local DOCKER_CONTAINER="$(docker-compose ps | sed -n '3s/ .*//p')"
    echo "container is $DOCKER_CONTAINER"
    if [ -n "${NOTESTS:-}" ]; then
        exit 0
    fi
    if [ "$version" = "latest" ]; then
        local version=".*"
    fi
    hr
    ./check_solr_version.py -e "$version"
    hr
    #echo "sleeping for 20 secs to allow SolrCloud shard state to settle"
    #sleep 20
    echo "will try cluster status up to $startupwait times to give cluster and collection chance to initialize properly"
    for x in `seq $startupwait`; do
        $perl -T ./check_solrcloud_cluster_status.pl -v && break
        sleep 1
    done
    $perl -T ./check_solrcloud_cluster_status.pl -v
    hr
    docker_exec check_solrcloud_cluster_status_zookeeper.pl -H localhost -P 9983 -b / -v
    hr
    # FIXME: doesn't pick up collection from env
    if [ -n "$four" ]; then
        docker_exec check_solrcloud_config_zookeeper.pl -H localhost -P 9983 -b / -C "$SOLR_COLLECTION" -d "/solr/node1/solr/$SOLR_COLLECTION/conf" -v
    else
        # TODO: review why there is no solrcloud example config - this was the closest one I found via:
        # find /solr/ -name solrconfig.xml | while read filename; dirname=$(dirname $filename); do echo $dirname; /pl/check_solrcloud_config_zookeeper.pl -H localhost -P 9983 -b / -C gettingstarted -d $dirname -v; echo; done
        set +o pipefail
        docker_exec check_solrcloud_config_zookeeper.pl -H localhost -P 9983 -b / -C "$SOLR_COLLECTION" -d "$SOLR_HOME/server/solr/configsets/data_driven_schema_configs/conf" -v | grep -F '1 file only found in ZooKeeper but not local directory (configoverlay.json)'
        set -o pipefail
    fi
    hr
    # FIXME: why is only 1 node up instead of 2
    $perl -T ./check_solrcloud_live_nodes.pl -w 1 -c 1 -t 60 -v
    hr
    docker_exec check_solrcloud_live_nodes_zookeeper.pl -H localhost -P 9983 -b / -w 1 -c 1 -v
    hr
    # docker is running slow
    $perl -T ./check_solrcloud_overseer.pl -t 60 -v
    hr
    docker_exec check_solrcloud_overseer_zookeeper.pl -H localhost -P 9983 -b / -v
    hr
    # returns blank now
    #container_ip="$(docker inspect --format '{{ .NetworkSettings.IPAddress }}' "$DOCKER_CONTAINER")"
    container_ip="$(docker-compose exec "$DOCKER_SERVICE" ip addr | awk '/inet .* e/{print $2}' | sed 's/\/.*//')"
    echo "container IP is $container_ip"
    docker_exec check_solrcloud_server_znode.pl -H localhost -P 9983 -z "/live_nodes/$container_ip:8983_solr" -v
    hr
    # FIXME: second node does not come/stay up
    # docker_exec check_solrcloud_server_znode.pl -H localhost -P 9983 -z /live_nodes/$(docker inspect --format '{{ .NetworkSettings.IPAddress }}' "$DOCKER_CONTAINER"):8984_solr -v
    hr
    if [ -n "$four" ]; then
        docker_exec check_zookeeper_config.pl -H localhost -P 9983 -C "$SOLR_HOME/node1/solr/zoo.cfg" --no-warn-extra -v
    else
        docker_exec check_zookeeper_config.pl -H localhost -P 9983 -C "$SOLR_HOME/example/cloud/node1/solr/zoo.cfg" --no-warn-extra -v
    fi
    hr
    #delete_container
    docker-compose down
    hr
    echo
}

for version in $(ci_sample $SOLR_VERSIONS); do
    test_solrcloud $version
done
