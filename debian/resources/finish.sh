#!/bin/sh

#move to script directory so all relative paths work
cd "$(dirname "$0")"

#includes
. ./config.sh
. ./colors.sh

#database details
database_username=fusionpbx
if [ .$database_password = .'random' ]; then
	database_password=$(dd if=/dev/urandom bs=1 count=20 2>/dev/null | base64 | sed 's/[=\+//]//g')
fi

#allow the script to use the new password
export PGPASSWORD=$database_password

#update the database password
#sudo -u postgres psql --host=$database_host --port=$database_port --username=$database_username -c "ALTER USER fusionpbx WITH PASSWORD '$database_password';"
#sudo -u postgres psql --host=$database_host --port=$database_port --username=$database_username -c "ALTER USER freeswitch WITH PASSWORD '$database_password';"
sudo -u postgres psql -c "ALTER USER fusionpbx WITH PASSWORD '$database_password';"
sudo -u postgres psql -c "ALTER USER freeswitch WITH PASSWORD '$database_password';"

#install the database backup
cp backup/fusionpbx-backup /etc/cron.daily
cp backup/fusionpbx-maintenance /etc/cron.daily
chmod 755 /etc/cron.daily/fusionpbx-backup
chmod 755 /etc/cron.daily/fusionpbx-maintenance
sed -i "s/zzz/$database_password/g" /etc/cron.daily/fusionpbx-backup
sed -i "s/zzz/$database_password/g" /etc/cron.daily/fusionpbx-maintenance

#add the config.conf
mkdir -p /etc/fusionpbx
cp fusionpbx/config.conf /etc/fusionpbx
sed -i /etc/fusionpbx/config.conf -e s:"{database_host}:$database_host:"
sed -i /etc/fusionpbx/config.conf -e s:"{database_name}:$database_name:"
sed -i /etc/fusionpbx/config.conf -e s:"{database_username}:$database_username:"
sed -i /etc/fusionpbx/config.conf -e s:"{database_password}:$database_password:"

#add the database schema
cd /var/www/fusionpbx && php /var/www/fusionpbx/core/upgrade/upgrade_schema.php > /dev/null 2>&1

#get the server hostname
if [ .$domain_name = .'hostname' ]; then
	domain_name=$(hostname -f)
fi

#get the ip address
if [ .$domain_name = .'ip_address' ]; then
	domain_name=$(hostname -I | cut -d ' ' -f1)
fi

#get the domain_uuid
domain_uuid=$(/usr/bin/php /var/www/fusionpbx/resources/uuid.php);

#add the domain name
psql --host=$database_host --port=$database_port --username=$database_username -c "insert into v_domains (domain_uuid, domain_name, domain_enabled) values('$domain_uuid', '$domain_name', 'true');"

#app defaults
cd /var/www/fusionpbx && /usr/bin/php /var/www/fusionpbx/core/upgrade/upgrade_domains.php

#add the user
user_uuid=$(/usr/bin/php /var/www/fusionpbx/resources/uuid.php);
user_salt=$(/usr/bin/php /var/www/fusionpbx/resources/uuid.php);
user_name=$system_username
if [ .$system_password = .'random' ]; then
	user_password=$(dd if=/dev/urandom bs=1 count=20 2>/dev/null | base64 | sed 's/[=\+//]//g')
else
	user_password=$system_password
fi
password_hash=$(/usr/bin/php -r "echo md5('$user_salt$user_password');");
psql --host=$database_host --port=$database_port --username=$database_username -t -c "insert into v_users (user_uuid, domain_uuid, username, password, salt, user_enabled) values('$user_uuid', '$domain_uuid', '$user_name', '$password_hash', '$user_salt', 'true');"

#get the superadmin group_uuid
#echo "psql --host=$database_host --port=$database_port --username=$database_username -qtAX -c \"select group_uuid from v_groups where group_name = 'superadmin';\""
group_uuid=$(psql --host=$database_host --port=$database_port --username=$database_username -qtAX -c "select group_uuid from v_groups where group_name = 'superadmin';");

#add the user to the group
user_group_uuid=$(/usr/bin/php /var/www/fusionpbx/resources/uuid.php);
group_name=superadmin
#echo "insert into v_user_groups (user_group_uuid, domain_uuid, group_name, group_uuid, user_uuid) values('$user_group_uuid', '$domain_uuid', '$group_name', '$group_uuid', '$user_uuid');"
psql --host=$database_host --port=$database_port --username=$database_username -c "insert into v_user_groups (user_group_uuid, domain_uuid, group_name, group_uuid, user_uuid) values('$user_group_uuid', '$domain_uuid', '$group_name', '$group_uuid', '$user_uuid');"

#update xml_cdr url, user and password
xml_cdr_username=$(dd if=/dev/urandom bs=1 count=20 2>/dev/null | base64 | sed 's/[=\+//]//g')
xml_cdr_password=$(dd if=/dev/urandom bs=1 count=20 2>/dev/null | base64 | sed 's/[=\+//]//g')
sed -i /etc/freeswitch/autoload_configs/xml_cdr.conf.xml -e s:"{v_http_protocol}:http:"
sed -i /etc/freeswitch/autoload_configs/xml_cdr.conf.xml -e s:"{domain_name}:$database_host:"
sed -i /etc/freeswitch/autoload_configs/xml_cdr.conf.xml -e s:"{v_project_path}::"
sed -i /etc/freeswitch/autoload_configs/xml_cdr.conf.xml -e s:"{v_user}:$xml_cdr_username:"
sed -i /etc/freeswitch/autoload_configs/xml_cdr.conf.xml -e s:"{v_pass}:$xml_cdr_password:"

#app defaults
cd /var/www/fusionpbx && /usr/bin/php /var/www/fusionpbx/core/upgrade/upgrade.php

#restart freeswitch
/bin/systemctl daemon-reload
/bin/systemctl restart freeswitch

#make the /var/run directory and set the ownership
mkdir /var/run/fusionpbx
chown -R www-data:www-data /var/run/fusionpbx

#install the email_queue service
cp /var/www/fusionpbx/app/email_queue/resources/service/debian.service /etc/systemd/system/email_queue.service
systemctl enable email_queue
systemctl start email_queue
systemctl daemon-reload

#install the event_guard service
cp /var/www/fusionpbx/app/event_guard/resources/service/debian.service /etc/systemd/system/event_guard.service
/bin/systemctl enable event_guard
/bin/systemctl start event_guard
/bin/systemctl daemon-reload

#install the websockets service
cp /var/www/fusionpbx/core/websockets/resources/service/debian-websockets.service /etc/systemd/system/websockets.service
systemctl daemon-reload
systemctl enable --now websockets

#install the active_calls service
cp /var/www/fusionpbx/app/active_calls/resources/service/debian-active_calls.service /etc/systemd/system/active_calls.service
systemctl daemon-reload
systemctl enable --now active_calls

#add xml cdr import to crontab
apt install cron
(crontab -l; echo "* * * * * $(which php) /var/www/fusionpbx/app/xml_cdr/xml_cdr_import.php 300") | crontab

#welcome message
echo ""
echo ""
verbose "Installation Notes. "
echo ""
echo "   Please save this information and reboot this system to complete the install. "
echo ""
echo "   Use a web browser to login."
echo "      domain name: https://$domain_name"
echo "      username: $user_name"
echo "      password: $user_password"
echo ""
echo "   The domain name in the browser is used by default as part of the authentication."
echo "   If you need to login to a different domain then use username@domain."
echo "      username: $user_name@$domain_name";
echo ""
echo "   Official FusionPBX Training"
echo "      Fastest way to learn FusionPBX. For more information https://www.fusionpbx.com."
echo "      Available online and in person. Includes documentation and recording."
echo ""
echo "      Location:               Online"
echo "      Admin Training:          TBA"
echo "      Advanced Training:       TBA"
echo "      Continuing Education:   https://www.fusionpbx.com/training"
echo "      Timezone:               https://www.timeanddate.com/weather/usa/idaho"
echo ""
echo "   Additional information."
echo "      https://fusionpbx.com/members.php"
echo "      https://fusionpbx.com/training.php"
echo "      https://fusionpbx.com/support.php"
echo "      https://www.fusionpbx.com"
echo "      http://docs.fusionpbx.com"
echo ""

# pgpassword security and conflict avoidance
unset PGPASSWORD
