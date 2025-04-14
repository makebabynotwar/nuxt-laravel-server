#!/bin/bash

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
        sudo mysql_secure_installation
    else
        echo "Skipping MariaDB password setup."
    fi

    # Step 5: Prompt for the project folder
    project_folder=$(whiptail --title "Enter Project Folder" --inputbox "Please enter the path to your project folder (should contain 'frontend' and 'api' folders):" 8 50 "" 3>&1 1>&2 2>&3)

    if [ -z "$project_folder" ]; then
        echo "Project folder is required. Exiting..."
        exit 1
    fi

    # Check if the project folder exists
    if [ ! -d "$project_folder" ]; then
        echo "The specified project folder does not exist. Exiting..."
        exit 1
    fi

    # Set the Laravel app path
    laravel_app_path="$project_folder/api"

    # Step 6: Prompt for the domain name
    domain_name=$(whiptail --title "Enter Domain Name" --inputbox "Please enter your domain name (without www):" 8 50 "" 3>&1 1>&2 2>&3)

    if [ -z "$domain_name" ]; then
        echo "Domain name is required. Exiting..."
        exit 1
    fi

    echo "You selected the following environment: $environment"
    echo "You selected the following options: $choices"
    echo "Project folder: $project_folder"
    echo "Laravel app path: $laravel_app_path"
    echo "Domain name: $domain_name"

    # Step 7: Set environment variable for envsubst
    export domain_name
    export laravel_app_path

    # Step 8: Read and process templates
    laravel_template="./$environment/nginx/laravel.conf.template"
    nuxt_template="./$environment/nginx/nuxt.conf.template"

    if [ ! -f "$laravel_template" ] || [ ! -f "$nuxt_template" ]; then
        echo "One or both template files are missing. Please check: $laravel_template and $nuxt_template"
        exit 1
    fi

    laravel_config=$(envsubst '${domain_name},${laravel_app_path}' < "$laravel_template")
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

else
    echo "User canceled the selection."
fi
