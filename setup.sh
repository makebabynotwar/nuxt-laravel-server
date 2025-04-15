#!/bin/bash

# Function to validate domain name using regex
validate_domain() {
    local domain=$1
    local regex="^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$"
    if [[ $domain =~ $regex ]]; then
        return 0
    else
        return 1
    fi
}

# Step 1: Choose an Environment
environment=$(whiptail --title "Choose an Environment" --nocancel --menu "Select an environment:" 15 50 3 \
"1" "local" \
"2" "development" \
"3" "production" \
3>&1 1>&2 2>&3)

# Check the environment selection
case $environment in
    1) environment="local" ;;
    2) environment="development" ;;
    3) environment="production" ;;
esac

# Step 2: Ensure Nginx and MariaDB are selected (mandatory)
choices=$(whiptail --title "Select Options" --checklist "Choose one or more options (Nginx and MariaDB are mandatory):" 20 50 10 \
"nginx" "Nginx Web Server" ON \
"mariadb" "MariaDB Server" ON \
"minio" "Minio Storage" OFF \
"php-fpm" "PHP-FPM (Load Balancer)" OFF \
"redis" "Redis with Supervisor" OFF \
3>&1 1>&2 2>&3)

exitstatus=$?

if [ $exitstatus = 0 ]; then
    if [[ "$choices" != *"nginx"* || "$choices" != *"mariadb"* ]]; then
        echo "Nginx and MariaDB must be selected. Exiting..."
        exit 1
    fi

    # Step 3: Update system and install necessary packages
    echo "Updating system and installing required packages..."

    # Check and install packages if not already installed
    packages=("curl" "wget" "nginx" "net-tools" "whiptail" "gettext" "mariadb-server" "php" "php-fpm" "php-mysql" "php-cli" "php-curl" "php-xml" "php-mbstring" "unzip")
    for package in "${packages[@]}"; do
        if ! dpkg -l | grep -q "$package"; then
            sudo apt install -y "$package"
        fi
    done

    sudo systemctl start nginx
    sudo systemctl enable nginx

    sudo apt-mark hold apache2 apache2-bin apache2-utils libapache2-mod-php8.2

    # Install nvm and Node.js LTS
    if ! command -v nvm &> /dev/null; then
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.1/install.sh | bash
        export NVM_DIR="$HOME/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
        nvm install --lts
    fi

    # Install Composer
    if ! command -v composer &> /dev/null; then
        curl -sS https://getcomposer.org/installer | php
        sudo mv composer.phar /usr/local/bin/composer
    fi

    # Step 4: Prompt for MariaDB password setup
    if (whiptail --title "MariaDB Password Setup" --yesno "Do you want to set up a password for MariaDB?" 8 50); then
        # Add your MariaDB password setup logic here
        echo "Setting up MariaDB password..."
    else
        echo "Skipping MariaDB password setup."
    fi

    # Step 5: Prompt for the project folder
    while true; do
        project_folder=$(whiptail --title "Enter Project Folder" --inputbox "Please enter the path to your project folder (should contain 'frontend' and 'api' folders):" 8 50 "" 3>&1 1>&2 2>&3)

        if [ -z "$project_folder" ]; then
            whiptail --title "Error" --msgbox "Project folder is required. Please enter a valid path." 8 50
        elif [ ! -d "$project_folder" ]; then
            whiptail --title "Error" --msgbox "The specified project folder does not exist. Please enter a valid path." 8 50
        else
            break
        fi
    done

    # Set the Laravel app path
    laravel_app_path="$project_folder/api"

    # Step 6: Prompt for the domain name
    while true; do
        domain_name=$(whiptail --title "Enter Domain Name" --inputbox "Please enter your domain name (without www):" 8 50 "" 3>&1 1>&2 2>&3)

        if [ -z "$domain_name" ]; then
            whiptail --title "Error" --msgbox "Domain name is required. Please enter a valid domain name." 8 50
        elif ! validate_domain "$domain_name"; then
            whiptail --title "Error" --msgbox "Invalid domain name format. Please enter a valid domain name." 8 50
        else
            break
        fi
    done

    echo "You selected the following environment: $environment"
    echo "You selected the following options: $choices"
    echo "Project folder: $project_folder"
    echo "Laravel app path: $laravel_app_path"
    echo "Domain name: $domain_name"

    # Step 7: Set environment variable for envsubst
    export domain_name
    export laravel_app_path

    # Step 8: Read and process templates
    if [[ "$choices" == *"php-fpm"* ]]; then
        # Set up PHP-FPM load balancer
        php_version=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
        sudo cp /etc/php/$php_version/fpm/pool.d/www.conf /etc/php/$php_version/fpm/pool.d/www2.conf

        # Process PHP-FPM pool configurations
        www_template="./local/php-fpm/www.conf.template"
        www2_template="./local/php-fpm/www2.conf.template"

        if [ ! -f "$www_template" ] || [ ! -f "$www2_template" ]; then
            echo "One or both PHP-FPM template files are missing. Please check: $www_template and $www2_template"
            exit 1
        fi

        www_config=$(envsubst '${php_version}' < "$www_template")
        www2_config=$(envsubst '${php_version}' < "$www2_template")

        echo "$www_config" | sudo tee /etc/php/$php_version/fpm/pool.d/www.conf > /dev/null
        echo "$www2_config" | sudo tee /etc/php/$php_version/fpm/pool.d/www2.conf > /dev/null

        sudo systemctl restart php$php_version-fpm

        # Create the upstream configuration file for the load balancer if it doesn't exist
        upstream_config_path="/etc/nginx/conf.d/upstream.conf"
        if [ ! -f "$upstream_config_path" ]; then
            upstream_config="upstream pool_php_fpm {
                least_conn;
                server unix:/run/php/php${php_version}-fpm-www.sock;
                server unix:/run/php/php${php_version}-fpm-www2.sock;
            }"
            echo "$upstream_config" | sudo tee "$upstream_config_path" > /dev/null
        else
            echo "Upstream configuration file already exists. Skipping creation."
        fi

        # Use laravel-with-balancer.conf.template for Nginx configuration
        laravel_template="./$environment/nginx/laravel-with-balancer.conf.template"
    else
        # Use laravel.conf.template for Nginx configuration
        laravel_template="./$environment/nginx/laravel.conf.template"
    fi

    nuxt_template="./$environment/nginx/nuxt.conf.template"

    if [ ! -f "$laravel_template" ] || [ ! -f "$nuxt_template" ]; then
        echo "One or both template files are missing. Please check: $laravel_template and $nuxt_template"
        exit 1
    fi

    laravel_config=$(envsubst '${domain_name},${laravel_app_path},${php_version}' < "$laravel_template")
    nuxt_config=$(envsubst '${domain_name}' < "$nuxt_template")

    # Step 9: Determine config filenames
    case $environment in
        local)
            laravel_config_filename="local-api.$domain_name"
            nuxt_config_filename="local.$domain_name"
            ;;
        development)
            laravel_config_filename="dev-api.$domain_name"
            nuxt_config_filename="dev.$domain_name"
            ;;
        production)
            laravel_config_filename="www-api.$domain_name"
            nuxt_config_filename="www.$domain_name"
            ;;
    esac

    # Step 10: Save configs
    laravel_config_path="/etc/nginx/sites-available/$laravel_config_filename"
    nuxt_config_path="/etc/nginx/sites-available/$nuxt_config_filename"
    echo "$laravel_config" | sudo tee "$laravel_config_path" > /dev/null
    echo "$nuxt_config" | sudo tee "$nuxt_config_path" > /dev/null

    # Step 11: Create symlinks if they don’t exist
    if [ ! -L "/etc/nginx/sites-enabled/$laravel_config_filename" ]; then
        sudo ln -s "$laravel_config_path" "/etc/nginx/sites-enabled/$laravel_config_filename"
    fi
    if [ ! -L "/etc/nginx/sites-enabled/$nuxt_config_filename" ]; then
        sudo ln -s "$nuxt_config_path" "/etc/nginx/sites-enabled/$nuxt_config_filename"
    fi

    # Step 12: Test Nginx config
    if ! sudo nginx -t; then
        echo "❌ Nginx configuration test failed. Please fix the errors above."
        exit 1
    fi

    # Step 13: Reload Nginx
    sudo systemctl reload nginx

    echo "✅ Nginx configuration for $domain_name has been set up and activated."

    # Step 14: Add domains to /etc/hosts if environment is local
    if [ "$environment" == "local" ]; then
        local_domains=("local.$domain_name" "local-api.$domain_name")
        for domain in "${local_domains[@]}"; do
            if ! grep -q "$domain" /etc/hosts; then
                echo "127.0.0.1 $domain" | sudo tee -a /etc/hosts > /dev/null
                echo "Domain $domain added to /etc/hosts for local testing."
            else
                echo "Domain $domain already exists in /etc/hosts. Skipping addition."
            fi
        done
    fi

else
    echo "User canceled the selection. Exiting..."
    exit 1
fi
