#!/bin/bash

# InterWorx SiteWorx Account Migration Script
# This script assists in migrations of InterWorx SiteWorx accounts from one server to another
# Always run from the destination (target) server

set -euo pipefail

# Default values
SOURCE=""
PORT="22"
DOMAIN=""
METHOD=""
CLEANUP=true

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to display usage
usage() {
    echo "Usage: $0 --source=<source_server> --port=<ssh_port> --domain=<domain_name> --method=<structure-only|sync>"
    echo ""
    echo "Options:"
    echo "  --source    Source server hostname/IP (required)"
    echo "  --port      SSH port (default: 22)"
    echo "  --domain    Domain name to migrate (required)"
    echo "  --method    Migration method: structure-only or sync (required)"
    echo "  --no-cleanup Don't cleanup temporary files after migration"
    echo ""
    echo "Example:"
    echo "  $0 --source=c701.falconinternet.net --port=2221 --domain=rollinghillspercherons.com --method=structure-only"
    exit 1
}

# Function to print colored messages
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --source=*)
            SOURCE="${1#*=}"
            shift
            ;;
        --port=*)
            PORT="${1#*=}"
            shift
            ;;
        --domain=*)
            DOMAIN="${1#*=}"
            shift
            ;;
        --method=*)
            METHOD="${1#*=}"
            shift
            ;;
        --no-cleanup)
            CLEANUP=false
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required arguments
if [[ -z "$SOURCE" || -z "$DOMAIN" || -z "$METHOD" ]]; then
    print_error "Missing required arguments"
    usage
fi

# Validate method
if [[ "$METHOD" != "structure-only" && "$METHOD" != "sync" ]]; then
    print_error "Invalid method: $METHOD. Must be 'structure-only' or 'sync'"
    exit 1
fi

# Function to get primary IP of destination server
get_primary_ip() {
    local primary_ip
    primary_ip=$(ip route get 8.8.8.8 | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' | head -1)
    if [[ -z "$primary_ip" ]]; then
        print_error "Failed to determine primary IP address"
        exit 1
    fi
    echo "$primary_ip"
}

# Function to get Linux username from domain on source server
get_linux_username_source() {
    local domain=$1
    local username
    
    print_info "Determining Linux username for domain: $domain (from source)" >&2
    
    # Try to get username from source server
    username=$(ssh -p "$PORT" root@"$SOURCE" "~iworx/bin/listaccounts.pex | grep \"$domain\" | awk '{print \$1}'" 2>/dev/null || echo "")
    
    if [[ -z "$username" ]]; then
        # If that fails, try alternative method
        username=$(ssh -p "$PORT" root@"$SOURCE" "grep -l \"^$domain\" /home/*/var/*/siteworx/accounts/*/domain 2>/dev/null | head -1 | cut -d'/' -f3" || echo "")
    fi
    
    if [[ -z "$username" ]]; then
        print_error "Failed to determine Linux username for domain $domain on source server"
        exit 1
    fi
    
    echo "$username"
}

# Function to get Linux username from domain on destination server
get_linux_username_dest() {
    local domain=$1
    local username
    
    print_info "Determining Linux username for domain: $domain (from destination)" >&2
    
    # Try to get username from destination server
    username=$(~iworx/bin/listaccounts.pex | grep "$domain" | awk '{print $1}' 2>/dev/null || echo "")
    
    if [[ -z "$username" ]]; then
        # If that fails, try alternative method
        username=$(grep -l "^$domain" /home/*/var/*/siteworx/accounts/*/domain 2>/dev/null | head -1 | cut -d'/' -f3 || echo "")
    fi
    
    if [[ -z "$username" ]]; then
        print_error "Failed to determine Linux username for domain $domain on destination server"
        exit 1
    fi
    
    echo "$username"
}

# Function to get MySQL databases for a domain
get_mysql_databases() {
    local username=$1
    local databases
    
    print_info "Finding MySQL databases for user: $username" >&2
    
    # Get list of databases for the user
    databases=$(ssh -p "$PORT" root@"$SOURCE" "mysql -e \"SHOW DATABASES LIKE '${username}_%';\" -sN" 2>/dev/null || echo "")
    
    if [[ -z "$databases" ]]; then
        print_warning "No MySQL databases found for user $username" >&2
    fi
    
    echo "$databases"
}

# Function to migrate MySQL databases
migrate_mysql_databases() {
    local username=$1
    local databases=$2
    
    if [[ -z "$databases" ]]; then
        print_info "No databases to migrate"
        return 0
    fi
    
    print_info "Migrating MySQL databases..."
    
    while IFS= read -r db; do
        if [[ -n "$db" ]]; then
            print_info "Dumping database: $db"
            
            # Dump database from source
            ssh -p "$PORT" root@"$SOURCE" "mysqldump --single-transaction --routines --triggers --events \"$db\"" > "/tmp/${db}.sql"
            
            # Create database on destination if it doesn't exist
            mysql -e "CREATE DATABASE IF NOT EXISTS \`$db\`;" 2>/dev/null || true
            
            # Import database
            print_info "Importing database: $db"
            mysql "$db" < "/tmp/${db}.sql"
            
            # Cleanup
            rm -f "/tmp/${db}.sql"
            
            print_info "Database $db migrated successfully"
        fi
    done <<< "$databases"
    
    # Migrate MySQL users and grants
    print_info "Migrating MySQL users and grants for $username"
    ssh -p "$PORT" root@"$SOURCE" "mysql -e \"SELECT CONCAT('CREATE USER IF NOT EXISTS ', quote(user), '@', quote(host), ' IDENTIFIED BY PASSWORD ', quote(authentication_string), ';') FROM mysql.user WHERE user LIKE '${username}_%' OR user = '$username';\" -sN" | mysql 2>/dev/null || true
    ssh -p "$PORT" root@"$SOURCE" "mysql -e \"SHOW GRANTS FOR '${username}'@'localhost';\" -sN 2>/dev/null || echo ''" | grep -v "^GRANT USAGE" | mysql 2>/dev/null || true
}

# Function to perform structure-only migration
structure_only_migration() {
    local backup_file="${DOMAIN}.tgz"
    local primary_ip
    
    print_info "Starting structure-only migration for domain: $DOMAIN"
    
    # Get primary IP
    primary_ip=$(get_primary_ip)
    print_info "Using primary IP: $primary_ip"
    
    # Create backup on source server
    print_info "Creating structure-only backup on source server..."
    if ! ssh -p "$PORT" root@"$SOURCE" "~iworx/bin/backup.pex --structure-only --domains=$DOMAIN -f $DOMAIN -o /tmp/"; then
        print_error "Failed to create backup on source server"
        exit 1
    fi
    
    # Copy backup to destination server
    print_info "Copying backup file to destination server..."
    if ! scp -P "$PORT" "root@${SOURCE}:/tmp/${backup_file}" "/tmp/"; then
        print_error "Failed to copy backup file"
        ssh -p "$PORT" root@"$SOURCE" "rm -f /tmp/${backup_file}"
        exit 1
    fi
    
    # Remove backup from source server
    ssh -p "$PORT" root@"$SOURCE" "rm -f /tmp/${backup_file}"
    
    # Import the account
    print_info "Importing SiteWorx account..."
    if ! ~iworx/bin/import.pex --control-panel=siteworx --archive="/tmp/${backup_file}" --ipv4 "$primary_ip"; then
        print_error "Failed to import SiteWorx account"
        rm -f "/tmp/${backup_file}"
        exit 1
    fi
    
    # Cleanup
    if [[ "$CLEANUP" == true ]]; then
        print_info "Cleaning up temporary files..."
        rm -f "/tmp/${backup_file}"
    fi
    
    print_info "Structure-only migration completed successfully!"
}

# Function to perform sync migration
sync_migration() {
    print_info "Starting sync migration for domain: $DOMAIN"
    
    # Get username
    local username
    username=$(get_linux_username_source "$DOMAIN")
    print_info "Linux username: $username"
    
    # Check if user directory exists on destination
    if [[ ! -d "/home/$username" ]]; then
        print_error "User directory /home/$username does not exist on destination server"
        print_error "Please run structure-only migration first to create the account"
        exit 1
    fi
    
    # Rsync exclude patterns for logs and cache
    local excludes=(
        "--exclude=*/logs/*"
        "--exclude=*/log/*"
        "--exclude=*/cache/*"
        "--exclude=*/tmp/*"
        "--exclude=*/temp/*"
        "--exclude=*.log"
        "--exclude=*/error_log"
        "--exclude=*/access_log"
        "--exclude=*/session/*"
        "--exclude=*/sessions/*"
        "--exclude=*/.cache/*"
        "--exclude=*/wp-content/cache/*"
        "--exclude=*/wp-content/w3tc-config/*"
        "--exclude=*/wp-content/wflogs/*"
    )
    
    # Perform rsync
    print_info "Syncing files from source to destination..."
    print_info "Excluding logs and cache files"
    
    rsync -az "${excludes[@]}" -e "ssh -p $PORT" "root@${SOURCE}:/home/${username}/" "/home/${username}/"
    
    # Get and migrate MySQL databases
    local databases
    databases=$(get_mysql_databases "$username")
    migrate_mysql_databases "$username" "$databases"
    
    print_info "Sync migration completed successfully!"
}

# Main execution
print_info "InterWorx SiteWorx Migration Script"
print_info "Source: $SOURCE:$PORT"
print_info "Domain: $DOMAIN"
print_info "Method: $METHOD"

# Test SSH connection
print_info "Testing SSH connection to source server..."
if ! ssh -p "$PORT" -o ConnectTimeout=10 root@"$SOURCE" "echo 'SSH connection successful'" >/dev/null 2>&1; then
    print_error "Failed to connect to source server via SSH"
    print_error "Please ensure SSH keys are properly configured"
    exit 1
fi

# Execute migration based on method
case $METHOD in
    structure-only)
        structure_only_migration
        ;;
    sync)
        sync_migration
        ;;
esac

print_info "Migration completed!"