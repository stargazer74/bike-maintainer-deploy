#!/bin/bash
# Second database and user for the website (WordPress) next to the app's "maintenance" database. The user only has
# rights on "wordpress" – WordPress never gets the root password or access to the app data. Runs once, on the first
# start with an empty data directory (sourced by the MariaDB entrypoint, which provides docker_process_sql – so this file must NOT be executable).
docker_process_sql --database=mysql <<-EOSQL
	CREATE DATABASE IF NOT EXISTS \`wordpress\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
	CREATE USER IF NOT EXISTS 'wordpress'@'%' IDENTIFIED BY '${BM_WEBSITE_DB_PASSWORD}';
	GRANT ALL PRIVILEGES ON \`wordpress\`.* TO 'wordpress'@'%';
EOSQL
