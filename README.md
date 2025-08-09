# InterWorx Transfer Script

A bash script to assist in migrating InterWorx SiteWorx accounts from one server to another.

## Overview

This script facilitates the migration of InterWorx SiteWorx accounts between servers, including website files, account structure, and MySQL databases. It must always be run from the destination (target) server, which should have SSH key-based authentication configured to connect to the source server as root.

## Prerequisites

- **Destination server**: InterWorx installed and configured
- **SSH access**: Root SSH key-based authentication from destination to source server
- **InterWorx tools**: Both servers must have InterWorx installed with access to:
  - `~iworx/bin/backup.pex`
  - `~iworx/bin/import.pex`
  - `~iworx/bin/listaccounts.pex`
- **MySQL**: Root access to MySQL on both servers

## Installation

1. Clone this repository or download the script to your destination server:
```bash
git clone https://github.com/marcpope/interworx-transfer.git
cd interworx-transfer
chmod +x migrate.sh
```

2. Ensure SSH key authentication is set up:
```bash
ssh-copy-id -p [PORT] root@[SOURCE_SERVER]
```

## Usage

```bash
./migrate.sh --source=<source_server> --port=<ssh_port> --domain=<domain_name> --method=<migration_method>
```

### Parameters

- `--source`: Source server hostname or IP address (required)
- `--port`: SSH port for source server (default: 22)
- `--domain`: Domain name to migrate (required)
- `--method`: Migration method - either `structure-only` or `sync` (required)
- `--no-cleanup`: Keep temporary files after migration (optional)

### Examples

**Structure-only migration:**
```bash
./migrate.sh --source=c701.falconinternet.net --port=2221 --domain=example.com --method=structure-only
```

**Sync migration:**
```bash
./migrate.sh --source=c701.falconinternet.net --port=2221 --domain=example.com --method=sync
```

## Migration Methods

### Structure-Only Method

This method creates a new SiteWorx account on the destination server with the same configuration as the source:

1. Creates a structure-only backup using `backup.pex` on the source server
2. Transfers the backup file to the destination server
3. Imports the account using `import.pex` with the destination server's primary IP
4. Migrates all MySQL databases and users associated with the account
5. Cleans up temporary files

**Use this method when:**
- Setting up a new account before syncing files
- Testing migrations
- Migrating account structure without large amounts of data

### Sync Method

This method synchronizes files from an existing account:

1. Verifies the account already exists on the destination server
2. Uses rsync to copy all files from source to destination
3. Automatically excludes log and cache files
4. Fixes file ownership
5. Migrates/updates MySQL databases

**Use this method when:**
- Updating an existing migrated account
- Performing incremental migrations
- Minimizing downtime during migration

**Note:** Run structure-only first to create the account, then use sync for file transfer.

## Features

### Automatic Username Detection
The script automatically determines the Linux username associated with the domain by querying the InterWorx installation on the source server.

### MySQL Migration
- Automatically detects all databases associated with the account
- Exports databases with routines, triggers, and events
- Creates databases on destination if they don't exist
- Preserves MySQL users and permissions

### Excluded Files During Sync
The sync method automatically excludes:
- Log files (`*/logs/*`, `*/log/*`, `*.log`)
- Cache directories (`*/cache/*`, `*/tmp/*`, `*/temp/*`)
- Session files (`*/session/*`, `*/sessions/*`)
- WordPress cache (`*/wp-content/cache/*`, `*/wp-content/w3tc-config/*`)
- Various application caches and temporary files

### Error Handling
- Validates all required parameters
- Tests SSH connectivity before starting
- Provides colored output for easy status monitoring
- Cleans up temporary files on failure
- Clear error messages for troubleshooting

## Workflow Example

For a complete migration:

1. **First, create the account structure:**
   ```bash
   ./migrate.sh --source=old.server.com --port=22 --domain=example.com --method=structure-only
   ```

2. **Then sync the files:**
   ```bash
   ./migrate.sh --source=old.server.com --port=22 --domain=example.com --method=sync
   ```

3. **Update DNS** to point to the new server

4. **Run a final sync** to catch any changes:
   ```bash
   ./migrate.sh --source=old.server.com --port=22 --domain=example.com --method=sync
   ```

## Troubleshooting

### SSH Connection Failed
- Verify SSH key authentication is properly configured
- Check if the SSH port is correct
- Ensure root login is permitted on the source server

### Username Detection Failed
- Verify the domain exists on the source server
- Check InterWorx tools are accessible at `~iworx/bin/`

### MySQL Migration Issues
- Ensure root MySQL access is configured on both servers
- Check for sufficient disk space for database dumps
- Verify MySQL users can be created on the destination

### Import Failed
- Check available IPs on the destination server
- Verify sufficient disk space
- Ensure InterWorx license is valid

## Security Considerations

- The script requires root access on both servers
- SSH keys should be properly secured
- Consider removing SSH key access after migration
- Temporary backup files are stored in `/tmp` and cleaned up automatically

## Contributing

Feel free to submit issues and enhancement requests!

## License

This project is provided as-is for use with InterWorx hosting environments.