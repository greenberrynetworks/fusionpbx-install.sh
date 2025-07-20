#!/bin/sh

#move to script directory so all relative paths work
cd "$(dirname "$0")"

#includes
. ./config.sh
. ./colors.sh

#send a message
verbose "Installing FusionPBX"

#install dependencies
pkg install --yes git ossp-uuid

#set the version
if [ .$system_branch = .'master' ]; then
	verbose "Using master"
	branch=""
else
	verbose "Using version $system_branch"
	branch="-b $system_branch"
fi

#add the cache directory
mkdir -p /var/cache/fusionpbx
chown -R www:www /var/cache/fusionpbx

#get the source code
git clone $branch https://github.com/greenberrynetworks/fusionpbx.git /usr/local/www/fusionpbx
chown -R www:www /usr/local/www/fusionpbx
