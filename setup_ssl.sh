#!/bin/bash

# based on https://github.com/wmnnd/nginx-certbot/blob/master/init-letsencrypt.sh (see license in ./3rd-party-license/)

# read domains from .domains file
if [ ! -f ".domain" ]; then
    echo "error: The file .domain is missing. You must create this file containing the domain names."
    exit 1
fi
readarray -t domains < .domain

# read config variables
rsa_key_size=4096
data_path="./data/certbot"
email=""
staging=1
if [ ! -f ".certbot.conf" ]; then
    echo "error: The file .certbot.conf is missing."
    exit 1
fi
. .certbot.conf

# guard against accidental execution of this script if there are already existing certbot configurations
if [ -d "$data_path" ]; then
  read -p "Existing data found in $data_path. Procceding could result in a broken configuration. Do you want to continue? (y/N) " decision
  if [ "$decision" != "Y" ] && [ "$decision" != "y" ]; then
    exit
  fi
fi

# download configuration files for nginx
if [ ! -e "$data_path/conf/options-ssl-nginx.conf" ] || [ ! -e "$data_path/conf/ssl-dhparams.pem" ]; then
  echo "> downloading recommended TLS parameters for nginx ..."
  mkdir -p "$data_path/conf"
  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf > "$data_path/conf/options-ssl-nginx.conf"
  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot/certbot/ssl-dhparams.pem > "$data_path/conf/ssl-dhparams.pem"
  echo
fi

# create dummy certificate for the domains, so that nginx can start properly
echo "> creating dummy certificate for $domains ..."
path="/etc/letsencrypt/live/$domains"
mkdir -p "$data_path/conf/live/$domains"
docker compose run --rm --entrypoint "\
  openssl req -x509 -nodes -newkey rsa:$rsa_key_size -days 1\
    -keyout '$path/privkey.pem' \
    -out '$path/fullchain.pem' \
    -subj '/CN=localhost'" certbot
echo

# (re)start nginx to load the new config
echo "> starting nginx ..."
docker compose up --force-recreate -d nginx
echo

# delete the dummy certificate because its not needed anymore
echo "> deleting dummy certificate for $domains ..."
docker compose run --rm --entrypoint "\
  rm -Rf /etc/letsencrypt/live/$domains && \
  rm -Rf /etc/letsencrypt/archive/$domains && \
  rm -Rf /etc/letsencrypt/renewal/$domains.conf" certbot
echo

echo "> Requesting Let's Encrypt certificate for $domains ..."
# join $domains to -d args
domain_args=""
for domain in "${domains[@]}"; do
  domain_args="$domain_args -d $domain"
done

# select appropriate email arg
case "$email" in
  "") email_arg="--register-unsafely-without-email" ;;
  *) email_arg="--email $email" ;;
esac

# enable staging mode if needed
if [ $staging != "0" ]; then staging_arg="--staging"; fi

docker compose run --rm --entrypoint "\
  certbot certonly --webroot -w /var/www/certbot \
    $staging_arg \
    $email_arg \
    $domain_args \
    --rsa-key-size $rsa_key_size \
    --agree-tos \
    --force-renewal" certbot
echo

echo "> reload nginx configuration ..."
docker compose exec nginx nginx -s reload

echo "> done."
