#!/bin/bash

# Function to validate domain name using regex
validate_domain() {
    local domain=$1
    local regex="^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$"
    if [[ $domain =~ $regex ]]; then
        return 0
    else
        return 1
    fi
}

# Function to validate numeric input
validate_numeric() {
    local input=$1
    if [[ $input =~ ^[0-9]+$ ]]; then
        return 0
    else
        return 1
    fi
}

# --- Configuration ---
SCRIPT_BASE_DIR=$(dirname "$0")
SCRIPT_BASE_DIR=$(realpath "$SCRIPT_BASE_DIR")
# Get the user who invoked sudo, default to current user if not sudo
CURRENT_USER=${SUDO_USER:-$USER}


# Step 1: Choose an Environment
environment=$(whiptail --title "Choose an Environment" --nocancel --menu "Select an environment:" 15 50 3 \
"1" "local" \
"2" "development" \
"3" "production" \
3>&1 1>&2 2>&3)
exitstatus=$?
if [ $exitstatus != 0 ]; then echo "User cancelled. Exiting."; exit 1; fi
case $environment in
    1) environment="local" ;;
    2) environment="development" ;;
    3) environment="production" ;;
esac


# Step 2: Select Options
choices=$(whiptail --title "Select Options" --checklist "Choose options (Nginx & MariaDB mandatory):" 20 60 10 \
"nginx" "Nginx Web Server" ON \
"mariadb" "MariaDB Server" ON \
"minio" "Minio Storage" OFF \
"php-fpm" "PHP-FPM (Load Balancer)" OFF \
"redis" "Redis with Supervisor" OFF \
3>&1 1>&2 2>&3)
exitstatus=$?
if [ $exitstatus != 0 ]; then echo "User canceled. Exiting."; exit 1; fi
if [[ "$choices" != *"nginx"* || "$choices" != *"mariadb"* ]]; then
    whiptail --title "Error" --msgbox "Nginx and MariaDB must be selected. Exiting..." 8 60
    exit 1
fi


# Step 3: Install Base Packages
echo "Updating system and installing base packages..."
packages=("curl" "wget" "nginx" "net-tools" "whiptail" "gettext" "mariadb-server" "php" "php-fpm" "php-mysql" "php-cli" "php-curl" "php-xml" "php-mbstring" "unzip" "ca-certificates" "gnupg")
missing_packages=()
for package in "${packages[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "ok installed"; then
        missing_packages+=("$package")
    fi
done

if [ ${#missing_packages[@]} -gt 0 ]; then
    echo "Installing missing base packages: ${missing_packages[*]}"
    sudo apt update
    sudo apt install -y "${missing_packages[@]}"
else
    echo "All required base packages are already installed."
fi

sudo systemctl start nginx
sudo systemctl enable nginx

# Hold Apache
echo "Checking Apache hold status..."
if ! sudo apt-mark showhold | grep -q '^apache2'; then
    sudo apt-mark hold apache2 apache2-bin apache2-utils libapache2-mod-php*
    echo "Placed hold on Apache packages."
else
    echo "Apache packages already on hold."
fi

# --- Install Node.js Globally ---
NODE_MAJOR=20
if ! command -v node &> /dev/null || ! node -v | grep -q "^v${NODE_MAJOR}\."; then
    echo "Node.js v${NODE_MAJOR} not found or incorrect version. Installing/Updating..."
    if [ ! -f "/etc/apt/sources.list.d/nodesource.list" ]; then
        echo "Adding NodeSource repository..."
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
        echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" | sudo tee /etc/apt/sources.list.d/nodesource.list
    fi
    sudo apt update
    sudo apt install nodejs -y
else
    echo "Node.js v$(node -v) already installed."
fi
echo "Node version: $(node -v)"
echo "npm version: $(npm -v)"


# Install Composer Globally
if ! command -v composer &> /dev/null; then
    echo "Installing Composer globally..."
    EXPECTED_CHECKSUM="$(php -r 'copy("https://composer.github.io/installer.sig", "php://stdout");')"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"
    if [ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]; then >&2 echo 'ERROR: Invalid composer installer checksum'; rm composer-setup.php; exit 1; fi
    sudo php composer-setup.php --quiet --install-dir=/usr/local/bin --filename=composer
    RESULT=$?
    rm composer-setup.php
    if [ $RESULT -ne 0 ]; then >&2 echo 'ERROR: Composer installation failed'; exit $RESULT; fi
    echo "Composer installed successfully to /usr/local/bin/composer"
else
    echo "Composer already installed at $(command -v composer)."
fi


# Step 4: MariaDB Secure Installation Prompt
if (whiptail --title "MariaDB Secure Installation" --yesno "Run 'mysql_secure_installation'?" 10 60); then
    echo "Running MariaDB secure installation..."
    sudo mysql_secure_installation
else
    echo "Skipping MariaDB secure installation."
fi


# Step 5: Project Folder Prompt
while true; do
    project_folder=$(whiptail --title "Enter Project Folder" --inputbox "Absolute path (contains 'frontend'/'api'):" 10 70 "" 3>&1 1>&2 2>&3)
    exitstatus=$?
    if [ $exitstatus != 0 ]; then echo "User cancelled. Exiting."; exit 1; fi
    if [ -z "$project_folder" ]; then whiptail --title "Error" --msgbox "Path cannot be empty." 8 50
    elif [[ ! "$project_folder" == /* ]]; then whiptail --title "Error" --msgbox "Please enter an absolute path." 8 60
    elif [ ! -d "$project_folder" ]; then whiptail --title "Error" --msgbox "Folder does not exist: $project_folder" 8 60
    elif [ ! -d "$project_folder/api" ] || [ ! -d "$project_folder/frontend" ]; then whiptail --title "Error" --msgbox "Must contain 'api' and 'frontend' subdirs." 10 60
    else break; fi
done
laravel_app_path="$project_folder/api"

# Step 6: Domain Name Prompt
while true; do
    domain_name=$(whiptail --title "Enter Domain Name" --inputbox "e.g., example.com:" 8 60 "" 3>&1 1>&2 2>&3)
     exitstatus=$?
    if [ $exitstatus != 0 ]; then echo "User cancelled. Exiting."; exit 1; fi
    if [ -z "$domain_name" ]; then whiptail --title "Error" --msgbox "Domain name required." 8 50
    elif ! validate_domain "$domain_name"; then whiptail --title "Error" --msgbox "Invalid domain format." 10 70
    else break; fi
done

echo "----------------------------------------"
echo "Selected Environment: $environment"
echo "Selected Options: $choices"
echo "Project Folder: $project_folder"
echo "Laravel App Path: $laravel_app_path"
echo "Domain Name: $domain_name"
echo "----------------------------------------"

# Step 6.1: Set Project Ownership and Group Membership
# Determine Web User (needed for ownership)
WEB_USER=$(grep -E '^\s*user\s+' /etc/nginx/nginx.conf | awk '{print $2}' | sed 's/;//' | head -n 1)
if [ -z "$WEB_USER" ]; then WEB_USER=$(grep -E '^\s*user\s*=' "/etc/php/$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')/fpm/pool.d/www.conf" | awk -F= '{print $2}' | xargs | head -n 1); fi
if [ -z "$WEB_USER" ]; then WEB_USER="www-data"; fi
echo "Setting project ownership to $WEB_USER:$WEB_USER..."
sudo chown -R $WEB_USER:$WEB_USER "$project_folder"
if [ $? -ne 0 ]; then echo "⚠️ Warning: Failed to change ownership of $project_folder."; fi

echo "Adding current user '$CURRENT_USER' to group '$WEB_USER'..."
if ! groups "$CURRENT_USER" | grep -q "\b$WEB_USER\b"; then
    sudo usermod -aG "$WEB_USER" "$CURRENT_USER"
    if [ $? -eq 0 ]; then
        echo "✅ User '$CURRENT_USER' added to group '$WEB_USER'."
        echo "   INFO: You may need to log out and log back in for group changes to take full effect."
    else
        echo "⚠️ Warning: Failed to add user '$CURRENT_USER' to group '$WEB_USER'."
    fi
else
    echo "User '$CURRENT_USER' is already a member of group '$WEB_USER'."
fi


# Step 7: Set PHP version variable
php_version=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
if [ -z "$php_version" ]; then echo "❌ Could not determine PHP version."; exit 1; fi
echo "Detected PHP version: $php_version"


# Step 8: Process Nginx and PHP-FPM Templates
# --- PHP-FPM Load Balancer Setup ---
if [[ "$choices" == *"php-fpm"* ]]; then
    echo "Configuring PHP-FPM Load Balancer..."
    php_pool_dir="/etc/php/$php_version/fpm/pool.d"
    if [ ! -d "$php_pool_dir" ]; then echo "❌ PHP-FPM pool dir not found: $php_pool_dir"; exit 1; fi
    if [ ! -f "$php_pool_dir/www2.conf" ]; then sudo cp "$php_pool_dir/www.conf" "$php_pool_dir/www2.conf"; echo "Created www2.conf"; fi
    www_template="$SCRIPT_BASE_DIR/$environment/php-fpm/www.conf.template"
    www2_template="$SCRIPT_BASE_DIR/$environment/php-fpm/www2.conf.template"
    if [ ! -f "$www_template" ] || [ ! -f "$www2_template" ]; then echo "❌ PHP-FPM template(s) missing."; exit 1; fi
    safe_php_version=$(printf '%s\n' "$php_version" | sed 's/[#]/\\&/g')
    www_config=$(sed -e "s#\${php_version}#${safe_php_version}#g" < "$www_template")
    www2_config=$(sed -e "s#\${php_version}#${safe_php_version}#g" < "$www2_template")
    echo "$www_config" | sudo tee "$php_pool_dir/www.conf" > /dev/null
    echo "$www2_config" | sudo tee "$php_pool_dir/www2.conf" > /dev/null
    echo "Applied PHP-FPM pool configurations."
    sudo systemctl restart "php${php_version}-fpm"
    echo "Restarted php${php_version}-fpm service."

    upstream_config_path="/etc/nginx/conf.d/upstream-php-fpm.conf"
    php_run_dir="/run/php"
    socket1="$php_run_dir/php${php_version}-fpm-www.sock"
    socket2="$php_run_dir/php${php_version}-fpm-www2.sock"
    echo "Waiting briefly for PHP-FPM sockets..."
    sleep 3
    if [ ! -S "$socket1" ] || [ ! -S "$socket2" ]; then echo "⚠️ Warning: PHP-FPM socket(s) not found."; fi
    upstream_config="upstream pool_php_fpm { least_conn; server unix:$socket1; server unix:$socket2; }"
    echo "$upstream_config" | sudo tee "$upstream_config_path" > /dev/null
    echo "Created/Updated Nginx upstream config: $upstream_config_path"

    laravel_nginx_template="$SCRIPT_BASE_DIR/$environment/nginx/laravel-with-balancer.conf.template"
else
    laravel_nginx_template="$SCRIPT_BASE_DIR/$environment/nginx/laravel.conf.template"
fi

# --- Laravel and Nuxt Nginx Config ---
echo "Configuring Nginx for Laravel and Nuxt..."
nuxt_nginx_template="$SCRIPT_BASE_DIR/$environment/nginx/nuxt.conf.template"

if [ ! -f "$laravel_nginx_template" ] || [ ! -f "$nuxt_nginx_template" ]; then
    echo "❌ Nginx template(s) missing."
    exit 1
fi

safe_laravel_app_path=$(printf '%s\n' "$laravel_app_path" | sed 's/[#]/\\&/g')
safe_domain_name=$(printf '%s\n' "$domain_name" | sed 's/[#]/\\&/g')
safe_php_version=$(printf '%s\n' "$php_version" | sed 's/[#]/\\&/g')

laravel_config=$(sed \
    -e "s#\${laravel_app_path}#${safe_laravel_app_path}#g" \
    -e "s#\${domain_name}#${safe_domain_name}#g" \
    -e "s#\${php_version}#${safe_php_version}#g" \
    < "$laravel_nginx_template")

nuxt_config=$(sed \
    -e "s#\${domain_name}#${safe_domain_name}#g" \
    < "$nuxt_nginx_template")

case $environment in
    local) laravel_config_filename="local-api.$domain_name.conf"; nuxt_config_filename="local.$domain_name.conf";;
    development) laravel_config_filename="dev-api.$domain_name.conf"; nuxt_config_filename="dev.$domain_name.conf";;
    production) laravel_config_filename="www-api.$domain_name.conf"; nuxt_config_filename="www.$domain_name.conf";;
esac

laravel_config_path="/etc/nginx/sites-available/$laravel_config_filename"
nuxt_config_path="/etc/nginx/sites-available/$nuxt_config_filename"
echo "$laravel_config" | sudo tee "$laravel_config_path" > /dev/null; echo "Created: $laravel_config_path"
echo "$nuxt_config" | sudo tee "$nuxt_config_path" > /dev/null; echo "Created: $nuxt_config_path"
laravel_symlink_path="/etc/nginx/sites-enabled/$laravel_config_filename"
nuxt_symlink_path="/etc/nginx/sites-enabled/$nuxt_config_filename"
if [ ! -L "$laravel_symlink_path" ]; then sudo ln -s "$laravel_config_path" "$laravel_symlink_path"; echo "Enabled site: $laravel_config_filename"; else echo "Site already enabled: $laravel_config_filename"; fi
if [ ! -L "$nuxt_symlink_path" ]; then sudo ln -s "$nuxt_config_path" "$nuxt_symlink_path"; echo "Enabled site: $nuxt_config_filename"; else echo "Site already enabled: $nuxt_config_filename"; fi


# Step 14: MinIO Setup
minio_nginx_configured=false
if [[ "$choices" == *"minio"* ]]; then
    echo "Configuring MinIO..."
    minio_needs_install=false
    if ! command -v minio &> /dev/null || ! systemctl list-unit-files --type=service | grep -q '^minio.service'; then
        minio_needs_install=true
    fi

    configure_minio=false
    MINIO_DATA_BASE_DIR="/data/minio"
    MINIO_DATA_DIR="${MINIO_DATA_BASE_DIR}/data"

    if $minio_needs_install; then
        configure_minio=true
        echo "Installing MinIO server..."
        MINIO_LATEST_URL=$(curl -s https://dl.min.io/server/minio/release/linux-amd64/minio.sha256sum | grep 'minio$' | head -n 1 | awk '{print $2}')
        if [ -z "$MINIO_LATEST_URL" ]; then echo "Error: Could not fetch latest Minio URL."; exit 1; fi
        echo "Downloading Minio: ${MINIO_LATEST_URL}"
        wget "https://dl.min.io/server/minio/release/linux-amd64/${MINIO_LATEST_URL}" -O minio_download
        sudo chmod +x minio_download; sudo mv minio_download /usr/local/bin/minio
        sudo mkdir -p "$MINIO_DATA_BASE_DIR"
    else
        sudo mkdir -p "$MINIO_DATA_BASE_DIR"
        if systemctl is-active --quiet minio; then
            if (whiptail --title "MinIO Reconfiguration" --yesno "MinIO running. Reconfigure user/pass/size?" 10 60); then configure_minio=true; else echo "Skipping MinIO service reconfiguration."; fi
        else
             echo "MinIO service exists but is not running. Configuring."
             configure_minio=true
        fi
    fi

    if $configure_minio; then
        # Prompt for MinIO user/password
        while true; do minio_user=$(whiptail --title "MinIO Root User" --inputbox "Enter Root Username:" 8 60 "minioadmin" 3>&1 1>&2 2>&3); exitstatus=$?; if [ $exitstatus != 0 ]; then exit 1; fi; if [ -z "$minio_user" ]; then whiptail --msgbox "User required." 8 50; else break; fi; done
        while true; do minio_password=$(whiptail --title "MinIO Root Pass" --passwordbox "Enter Root Password (min 8):" 8 60 "" 3>&1 1>&2 2>&3); exitstatus=$?; if [ $exitstatus != 0 ]; then exit 1; fi; minio_password_confirm=$(whiptail --title "Confirm Password" --passwordbox "Confirm:" 8 60 "" 3>&1 1>&2 2>&3); exitstatus=$?; if [ $exitstatus != 0 ]; then exit 1; fi; if [ -z "$minio_password" ]; then whiptail --msgbox "Pass required." 8 50; elif [ ${#minio_password} -lt 8 ]; then whiptail --msgbox "Pass too short." 8 60; elif [ "$minio_password" != "$minio_password_confirm" ]; then whiptail --msgbox "Passwords mismatch." 8 50; else break; fi; done

        # *** ADDED: Prompt for MinIO storage size ***
        while true; do
            minio_gb_capacity=$(whiptail --title "MinIO Storage Capacity (Informational)" --inputbox "Enter INFORMATIONAL storage capacity for MinIO (in GB, e.g., 100):" 10 60 "100" 3>&1 1>&2 2>&3)
            exitstatus=$?
            if [ $exitstatus != 0 ]; then exit 1; fi # Exit if cancelled
            if [ -z "$minio_gb_capacity" ]; then # Allow empty input
                 minio_gb_capacity="0" # Default to 0 if empty, template needs `${minio_gb_capacity}G`
                 break
            elif validate_numeric "$minio_gb_capacity"; then
                 break
             else
                 whiptail --title "Error" --msgbox "Invalid input. Please enter a number (or leave empty)." 8 60
             fi
        done

        minio_service_template="$SCRIPT_BASE_DIR/$environment/minio/minio.service.template"
        if [ ! -f "$minio_service_template" ]; then echo "❌ MinIO service template missing: $minio_service_template"; exit 1; fi

        MINIO_SYSTEM_USER="minio-user"
        if ! id "$MINIO_SYSTEM_USER" &>/dev/null; then sudo useradd -r -s /sbin/nologin "$MINIO_SYSTEM_USER"; echo "Created system user '$MINIO_SYSTEM_USER'."; fi
        sudo chown -R $MINIO_SYSTEM_USER:$MINIO_SYSTEM_USER "$MINIO_DATA_BASE_DIR"
        echo "Ensured MinIO data directory base $MINIO_DATA_BASE_DIR exists and ownership set for $MINIO_SYSTEM_USER."

        safe_minio_user=$(printf '%s\n' "$minio_user" | sed 's/[#]/\\&/g')
        safe_minio_password=$(printf '%s\n' "$minio_password" | sed 's/[#]/\\&/g')
        safe_domain_name=$(printf '%s\n' "$domain_name" | sed 's/[#]/\\&/g')
        safe_minio_gb_capacity=$(printf '%s\n' "$minio_gb_capacity" | sed 's/[#]/\\&/g') # Prepare size variable

        # Use sed to substitute placeholders in the template
        minio_service_config=$(sed \
            -e "s#\${minio_user}#${safe_minio_user}#g" \
            -e "s#\${minio_password}#${safe_minio_password}#g" \
            -e "s#\${domain_name}#${safe_domain_name}#g" \
            -e "s#\${minio_gb_capacity}#${safe_minio_gb_capacity}#g" \
            < "$minio_service_template")

        echo "$minio_service_config" | sudo tee /etc/systemd/system/minio.service > /dev/null
        echo "Created/Updated MinIO systemd service file."

        sudo systemctl daemon-reload
        sudo systemctl enable minio
        sudo systemctl restart minio

        echo "Waiting for MinIO service..."
        sleep 5
        if systemctl is-active --quiet minio; then echo "✅ MinIO service configured and started."; else echo "❌ MinIO service failed. Check: journalctl -u minio.service"; fi
    fi # end configure_minio block

    # --- MinIO Nginx Config ---
    echo "Configuring Nginx for MinIO..."
    minio_api_template="$SCRIPT_BASE_DIR/$environment/nginx/minio-api.conf.template"
    minio_console_template="$SCRIPT_BASE_DIR/$environment/nginx/minio-console.conf.template"
    if [ ! -f "$minio_api_template" ] || [ ! -f "$minio_console_template" ]; then echo "❌ MinIO Nginx template(s) missing."; exit 1; fi

    safe_domain_name=$(printf '%s\n' "$domain_name" | sed 's/[#]/\\&/g')
    minio_api_config=$(sed -e "s#\${domain_name}#${safe_domain_name}#g" < "$minio_api_template")
    minio_console_config=$(sed -e "s#\${domain_name}#${safe_domain_name}#g" < "$minio_console_template")

    minio_api_config_filename="storage-api.$domain_name.conf"
    minio_console_config_filename="storage.$domain_name.conf"
    minio_api_config_path="/etc/nginx/sites-available/$minio_api_config_filename"
    minio_console_config_path="/etc/nginx/sites-available/$minio_console_config_filename"
    echo "$minio_api_config" | sudo tee "$minio_api_config_path" > /dev/null; echo "Created: $minio_api_config_path"
    echo "$minio_console_config" | sudo tee "$minio_console_config_path" > /dev/null; echo "Created: $minio_console_config_path"
    minio_api_symlink_path="/etc/nginx/sites-enabled/$minio_api_config_filename"
    minio_console_symlink_path="/etc/nginx/sites-enabled/$minio_console_config_filename"
    if [ ! -L "$minio_api_symlink_path" ]; then sudo ln -s "$minio_api_config_path" "$minio_api_symlink_path"; echo "Enabled site: $minio_api_config_filename"; else echo "Site already enabled: $minio_api_config_filename"; fi
    if [ ! -L "$minio_console_symlink_path" ]; then sudo ln -s "$minio_console_config_path" "$minio_console_symlink_path"; echo "Enabled site: $minio_console_config_filename"; else echo "Site already enabled: $minio_console_config_filename"; fi

    minio_nginx_configured=true

fi # End Minio selection block


# Step 15: Redis and Supervisor setup
if [[ "$choices" == *"redis"* ]]; then
    echo "Configuring Redis and Supervisor..."
    php_fpm_needs_restart=false

    redis_pkgs=()
    if ! command -v redis-server &> /dev/null && ! dpkg-query -W -f='${Status}' "redis-server" 2>/dev/null | grep -q "ok installed"; then redis_pkgs+=("redis-server"); fi
    if ! php -m | grep -qi redis && ! dpkg-query -W -f='${Status}' "php-redis" 2>/dev/null | grep -q "ok installed"; then redis_pkgs+=("php-redis"); php_fpm_needs_restart=true; fi
    if ! command -v supervisorctl &> /dev/null && ! dpkg-query -W -f='${Status}' "supervisor" 2>/dev/null | grep -q "ok installed"; then redis_pkgs+=("supervisor"); fi

    if [ ${#redis_pkgs[@]} -gt 0 ]; then echo "Installing Redis/Supervisor packages: ${redis_pkgs[*]}"; sudo apt update; sudo apt install -y "${redis_pkgs[@]}"; else echo "Redis/Supervisor packages appear installed."; fi

    # Permissions for Laravel Storage/Bootstrap (using determined WEB_USER)
    log_dir="$laravel_app_path/storage/logs"; framework_dir="$laravel_app_path/storage/framework"; cache_dir="$laravel_app_path/storage/framework/cache"; sessions_dir="$laravel_app_path/storage/framework/sessions"; views_dir="$laravel_app_path/storage/framework/views"; app_dir="$laravel_app_path/storage/app"
    echo "Using web server user: $WEB_USER" # WEB_USER determined earlier
    sudo mkdir -p "$log_dir" "$cache_dir" "$sessions_dir" "$views_dir" "$app_dir" "$laravel_app_path/bootstrap/cache"
    sudo chown -R $WEB_USER:$WEB_USER "$laravel_app_path/storage" "$laravel_app_path/bootstrap/cache"
    sudo chmod -R 775 "$laravel_app_path/storage" "$laravel_app_path/bootstrap/cache"
    echo "Ensured storage & bootstrap/cache dirs/permissions for Laravel."

    # Process Supervisor template
    redis_supervisor_template="$SCRIPT_BASE_DIR/$environment/redis-supervisor/redis-supervisor.conf.template"
    if [ ! -f "$redis_supervisor_template" ]; then echo "❌ Redis Supervisor template missing: $redis_supervisor_template"; exit 1; fi
    safe_laravel_app_path=$(printf '%s\n' "$laravel_app_path" | sed 's/[#]/\\&/g')
    safe_environment=$(printf '%s\n' "$environment" | sed 's/[#]/\\&/g')
    redis_supervisor_config=$(sed \
        -e "s#\${laravel_app_path}#${safe_laravel_app_path}#g" \
        -e "s#\${environment}#${safe_environment}#g" \
         < "$redis_supervisor_template")
    redis_supervisor_config_path="/etc/supervisor/conf.d/laravel-worker-$environment.conf"
    echo "$redis_supervisor_config" | sudo tee "$redis_supervisor_config_path" > /dev/null
    echo "Created/Updated Supervisor config: $redis_supervisor_config_path"
    echo "--- Supervisor Config Content ($redis_supervisor_config_path) ---"
    cat "$redis_supervisor_config_path" # Display content for debugging
    echo "--------------------------------------------------------------"
    echo "INFO: Check the above config for correct paths, commands, and user directives."
    echo "      Common errors: incorrect 'command=', 'directory=', 'user=', log file paths, or permissions."
    echo "      Consider adding 'user=$WEB_USER' if the worker needs to run as the web user."


    echo "Ensuring Supervisor service is running..."
    sudo systemctl restart supervisor # Restart to ensure it picks up potentially fixed main config
    echo "Waiting for Supervisor service..."
    sleep 4 # Give supervisord time to start and potentially fail again

    # Check status BEFORE trying to use supervisorctl
    if ! sudo systemctl is-active --quiet supervisor; then
        echo "❌ Supervisor service failed to start or is restarting. Check logs:"
        echo "   sudo journalctl -u supervisor.service -n 50 --no-pager"
        echo "   sudo cat /var/log/supervisor/supervisord.log"
        echo "   Review the generated config file: $redis_supervisor_config_path"
        # Exit or continue? Let's continue but warn heavily.
         echo "⚠️ Skipping supervisorctl commands as service is not stable."
    else
        echo "✅ Supervisor service is active. Reloading configuration..."
        # Reload Supervisor configuration
        if ! sudo supervisorctl reread; then
            echo "⚠️ Warning: supervisorctl reread failed. There might be an issue with the config file syntax ($redis_supervisor_config_path)."
            echo "   Check Supervisor logs: sudo cat /var/log/supervisor/supervisord.log"
        fi
        if ! sudo supervisorctl update; then
            echo "⚠️ Warning: supervisorctl update failed. Supervisor might not have loaded the new config."
            echo "   Check Supervisor logs: sudo cat /var/log/supervisor/supervisord.log"
        else
             echo "✅ Supervisor configuration updated."
             # Restart workers defined in the config
            WORKER_PROGRAM_NAME="laravel-worker-${environment}" # Assumes pattern from filename
            echo "Attempting to restart Supervisor programs matching '$WORKER_PROGRAM_NAME:*'..."
            # Use update first to ensure programs are known, then restart
            sudo supervisorctl update # Ensures supervisor knows about the new config
            sudo supervisorctl restart "${WORKER_PROGRAM_NAME}:*"
            echo "   Check worker status with: sudo supervisorctl status"
        fi
    fi

    echo "Restarting Redis service..."
    sudo systemctl restart redis-server
    echo "✅ Redis service restarted."

    if [ "$php_fpm_needs_restart" = true ]; then echo "Restarting PHP-FPM for PHP-Redis extension..."; sudo systemctl restart "php${php_version}-fpm"; fi
else
     echo "Skipping Redis and Supervisor setup."
fi


# Step 16: Update /etc/hosts for local env
if [ "$environment" == "local" ]; then
    echo "Updating /etc/hosts for local environment..."
    local_domains=("local.$domain_name" "local-api.$domain_name")
    if [[ "$choices" == *"minio"* ]]; then local_domains+=("local-storage.$domain_name" "local-storage-api.$domain_name"); fi
    HOSTS_FILE="/etc/hosts"; TEMP_HOSTS=$(mktemp)
    exclude_pattern=$(printf '|\\b%s\\b' "${local_domains[@]}"); exclude_pattern=${exclude_pattern#|}; grep -vP "^\s*127\.0\.0\.1\s+.*(${exclude_pattern})" "$HOSTS_FILE" > "$TEMP_HOSTS"
    printf "127.0.0.1 %s\n" "${local_domains[@]}" >> "$TEMP_HOSTS"; echo "" >> "$TEMP_HOSTS"
    if ! cmp -s "$HOSTS_FILE" "$TEMP_HOSTS"; then echo "Updating /etc/hosts..."; cat "$TEMP_HOSTS" | sudo tee "$HOSTS_FILE" > /dev/null; echo "✅ Updated /etc/hosts."; else echo "No changes needed to /etc/hosts."; fi
    rm "$TEMP_HOSTS"
fi

# Step 17: Final Nginx Configuration Test
echo "Testing final Nginx configuration..."
if ! sudo nginx -t; then
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!!! ❌ Nginx configuration test FAILED.                                   !!!"
    echo "!!! Please review the error messages above carefully.                     !!!"
    echo "!!! Check Nginx files: /etc/nginx/sites-enabled/, /etc/nginx/conf.d/      !!!"
    echo "!!! Ensure backend services (PHP-FPM, Minio proxy target, etc.) are running.!!!"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    exit 1
fi
echo "✅ Nginx configuration syntax is OK."

# Step 18: Reload Nginx
echo "Reloading Nginx..."
sudo systemctl reload nginx
if [ $? -ne 0 ]; then echo "❌ Failed to reload Nginx."; exit 1; fi
echo "✅ Nginx reloaded successfully."


echo "----------------------------------------"
echo "🚀 Setup Complete!"
echo "Environment '$environment' configured for domain '$domain_name'."
echo "Project Root: $project_folder"
minio_display_user="${minio_user:-minioadmin}" # Show default if var somehow unset
if [ "$environment" == "local" ]; then
    echo ""; echo "Access URLs (local):"; echo "  Frontend: http://local.$domain_name"; echo "  API Base: http://local-api.$domain_name"
     if [[ "$choices" == *"minio"* ]]; then echo "  Minio Console: http://local-storage.$domain_name"; echo "  Minio API: http://local-storage-api.$domain_name"; fi
fi
# Add note about supervisor status check
if [[ "$choices" == *"redis"* ]]; then
    echo ""
    echo "Supervisor Status:"
    echo "  Check worker status: sudo supervisorctl status"
    echo "  Check main log: sudo cat /var/log/supervisor/supervisord.log"
    echo "  Check worker logs defined in: /etc/supervisor/conf.d/laravel-worker-$environment.conf"
fi
echo "----------------------------------------"

exit 0