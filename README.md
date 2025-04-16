# Laravel & Nuxt.js Server Setup Script (Work In Progress)

## 👋 Introduction

Welcome! This script helps you quickly set up a server environment designed specifically for hosting web applications built with **Laravel** as the backend API and **Nuxt.js** as the frontend.

Think of it as an automated checklist that installs and configures the essential software like Nginx (web server), MariaDB (database), PHP, Node.js, and Composer. It saves you time by handling the basic setup, letting you focus on your code.

**What it does:**

*   Installs required server software (Nginx, MariaDB, PHP, Node.js, Composer).
*   Asks you questions (using simple dialog boxes) about your setup (like domain name, project location).
*   Optionally installs and configures extras like Minio (for file storage), Redis & Supervisor (for background tasks in Laravel), and PHP load balancing.
*   Sets up basic Nginx configurations tailored for serving Laravel and Nuxt.js separately.
*   Handles necessary file permissions for your Laravel application.
*   Helps set up your local `/etc/hosts` file for easy development access (if you choose the `local` environment).

**Who is this for?**

*   Developers setting up new servers (local, development, or staging/production) for Laravel/Nuxt.js projects.
*   Anyone looking to automate the initial, often repetitive, server configuration steps.

**✨ Key Features:**

*   Interactive & Guided Setup
*   Environment-Specific Configurations (local, dev, prod)
*   Installs Core Stack + Optional Components
*   Basic Laravel/Nuxt Nginx Setup
*   Permission Handling for Laravel
*   Local Development Helper (`/etc/hosts`)

**⚠️ Important Warning:** This script is **still under development**. While it aims to be helpful, it might have bugs or incomplete features. Please use it with caution, especially on production servers. Always review the configurations it generates and test thoroughly!

---

## 🚀 Getting Started: Step-by-Step

Follow these steps to use the setup script:

### Step 1: Prerequisites (Things you need first)

1.  **Linux Server:** You need a server running a Debian-based Linux system (like Debian or Ubuntu).
2.  **Sudo Access:** You must be able to run commands as an administrator using `sudo`.
3.  **Basic Tools:** Make sure `curl`, `wget`, and `gpg` are installed. The script tries to install other needed tools like `whiptail` if they're missing.
4.  **Internet:** An internet connection is needed to download software.
5.  **Project Code Ready:** Have your Laravel project code and Nuxt.js project code ready (or at least know where you will put them). The script expects them to be in `api` and `frontend` subdirectories within a main project folder.
6.  **Template Files:** This is **CRUCIAL**. The script **needs** special configuration template files to work. These templates tell the script *how* to set up Nginx, PHP, Minio, etc. for each environment. You must have these template files ready *before* running the script.

### Step 2: Prepare the Script and Templates

1.  **Download/Copy:** Get the `setup.sh` script file.
2.  **Get Templates:** Get the required template directories (`local/`, `development/`, `production/`). These directories must contain the necessary `.template` files (like `nginx/laravel.conf.template`, `nginx/nuxt.conf.template`, etc.).
3.  **Place Together:** Put the `setup.sh` script and the template directories (`local/`, `development/`, `production/`) all in the **same** folder on your server.

    *Your folder should look something like this:*
    ```
    your-setup-folder/
    ├── setup.sh                <-- The script
    ├── local/                  <-- Templates for local environment
    │   ├── nginx/
    │   ├── php-fpm/
    │   ├── minio/
    │   └── redis-supervisor/
    ├── development/            <-- Templates for development environment
    │   └── ... (similar structure)
    └── production/             <-- Templates for production environment
        └── ... (similar structure)
    ```
    *(Make sure the `.template` files inside these folders are correct for your needs!)*

### Step 3: Run the Script

1.  **Open Terminal:** Connect to your server via SSH or open a terminal window.
2.  **Navigate:** Go into the folder where you placed the script and templates:
    ```bash
    cd /path/to/your-setup-folder/
    ```
3.  **Make Executable:** Give the script permission to run:
    ```bash
    chmod +x setup.sh
    ```
4.  **Execute with Sudo:** Run the script using `sudo`:
    ```bash
    sudo ./setup.sh
    ```

### Step 4: Answer the Questions

The script will now ask you some questions using dialog boxes. Use the arrow keys, spacebar (to select options in checklists), and Enter key to navigate.

1.  **Choose Environment:** Select `local` (for your computer), `development`, or `production`.
2.  **Select Options:** Choose any extra features you want (Minio, PHP Load Balancer, Redis/Supervisor). Nginx and MariaDB are required and automatically selected.
3.  **MariaDB Secure Installation:** It's highly recommended to choose `Yes` to secure your database installation (set root password, remove test databases, etc.).
4.  **Project Folder Path:** Enter the **full, absolute path** where your main project lives (or will live). Example: `/var/www/my-awesome-app`. **Remember:** This folder *must* contain subfolders named `api` (for Laravel) and `frontend` (for Nuxt).
5.  **Domain Name:** Enter your main domain name (e.g., `my-domain.com`). The script will automatically create subdomains based on this (like `local.my-domain.com`, `dev-api.my-domain.com`).
6.  **(If Minio selected)** **Minio User/Password:** Choose a secure username and password for the Minio admin account.
7.  **(If Minio selected)** **Minio Storage Capacity:** Enter a number for the storage size in GB (e.g., `100`). This is mostly for informational purposes in the config template.

### Step 5: Wait and Watch

*   The script will now run commands to install software, copy configuration files (using your templates), set permissions, and restart services.
*   Watch the output in your terminal for any **ERROR** or **WARNING** messages.

### Step 6: Completion!

*   If everything goes well, you'll see a "🚀 Setup Complete!" message with useful information like the URLs to access your application (based on the environment and domain you entered).

---

## ✅ After the Script: Next Steps (Manual Work)

The script sets up the *server environment*, but you still need to deploy your code and do final configurations:

1.  **Deploy Code:**
    *   Upload your Laravel project files into the `api` subdirectory you specified (e.g., `/var/www/my-awesome-app/api/`).
    *   Upload your Nuxt.js project files into the `frontend` subdirectory (e.g., `/var/www/my-awesome-app/frontend/`).
2.  **Configure Laravel (`api` directory):**
    *   `cd` into your Laravel `api` directory.
    *   Create your `.env` file (usually `cp .env.example .env`).
    *   Edit the `.env` file: Set `APP_URL`, database connection details (DB name, user, password you'll create next), Redis details, Minio details (if used), etc.
    *   Run `composer install --optimize-autoloader --no-dev` (adjust flags based on environment).
    *   Run `php artisan key:generate`.
    *   Run `php artisan storage:link`.
    *   *After creating the database (Step 4 below):* Run `php artisan migrate` to create your database tables.
    *   For production: Run `php artisan config:cache`, `php artisan route:cache`, `php artisan view:cache`.
3.  **Configure Nuxt.js (`frontend` directory):**
    *   `cd` into your Nuxt `frontend` directory.
    *   Edit your `nuxt.config.js` (or `.ts`) if needed, especially for API endpoints or proxy settings to talk to your Laravel backend.
    *   Run `npm install` (or `yarn install`).
    *   Run `npm run build` (or `yarn build`) to create the production-ready files. (Make sure your Nginx template correctly serves the output from the build directory, often `.output/public/`).
4.  **Database Setup:**
    *   Log in to MariaDB: `sudo mysql -u root -p` (use the password you set during `mysql_secure_installation` if you ran it).
    *   Create a database for your Laravel app: `CREATE DATABASE your_laravel_db;`
    *   Create a database user: `CREATE USER 'your_laravel_user'@'localhost' IDENTIFIED BY 'your_secure_password';`
    *   Grant privileges to the user: `GRANT ALL PRIVILEGES ON your_laravel_db.* TO 'your_laravel_user'@'localhost';`
    *   `FLUSH PRIVILEGES;`
    *   `EXIT;`
    *   (Make sure these details match what you put in Laravel's `.env` file).
5.  **SSL Certificates (for Dev/Prod):**
    *   The script sets up basic HTTP (port 80). For HTTPS (port 443), you need to get SSL certificates (e.g., using Certbot/Let's Encrypt) and update the Nginx configuration files created by the script.
6.  **Firewall:**
    *   Configure your server's firewall (like `ufw`) to allow traffic on ports 80 (HTTP) and 443 (HTTPS):
        ```bash
        sudo ufw allow 'Nginx Full' # Or 'Nginx HTTP' and 'Nginx HTTPS' separately
        sudo ufw enable
        ```

---

## 💡 Important Notes & Tips

*   **Log Out/In:** After the script runs, **log out** of your SSH session and **log back in**. This ensures your user gets the new group permissions correctly (it adds you to the web server's group like `www-data`).
*   **Templates are Key:** The quality of your setup depends heavily on the `.template` files you provide. Double-check them!
*   **Not Perfect:** This script isn't foolproof. If something goes wrong, check the terminal output carefully for errors.
*   **Running Again:** Running the script multiple times on the same server might overwrite configurations unexpectedly. Be careful.
*   **Check Services:** After setup, check if key services are running:
    *   Nginx: `sudo systemctl status nginx`
    *   MariaDB: `sudo systemctl status mariadb`
    *   PHP-FPM: `sudo systemctl status php<VERSION>-fpm` (e.g., `php8.2-fpm`)
    *   Minio (if installed): `sudo systemctl status minio`
    *   Redis (if installed): `sudo systemctl status redis-server`
    *   Supervisor (if installed): `sudo systemctl status supervisor`
    *   Supervisor Workers (if installed): `sudo supervisorctl status`

---

## ❓ Troubleshooting Common Issues

*   **Website Not Loading (Nginx Errors):** Run `sudo nginx -t`. If it shows errors, check the file/line number mentioned. Also check Nginx logs: `sudo tail /var/log/nginx/error.log`. Make sure PHP-FPM (and Minio/Nuxt SSR if used) are running. Check the `root` path in the Nginx config file.
*   **Laravel Errors (500 Internal Server Error):** Check Laravel logs: `/path/to/your/project/api/storage/logs/laravel.log`. Often caused by incorrect `.env` settings or file permissions in `storage/` and `bootstrap/cache/`. Make sure the web server user (`www-data`) can write to these folders.
*   **Permission Denied:** Often related to file ownership or permissions. Ensure the web server user owns the necessary files/folders (especially `storage` and `bootstrap/cache` in Laravel) and that your user is in the correct group (log out/in!).
*   **Supervisor Workers Not Running:** Check Supervisor status (`sudo supervisorctl status`). Check the main Supervisor log (`/var/log/supervisor/supervisord.log`) and the specific worker logs defined in `/etc/supervisor/conf.d/laravel-worker-*.conf`. Ensure the `command`, `directory`, and `user` in the worker config file are correct.

Good luck with your setup!