# Rocker - Remote Docker Development Manager

Interactive CLI tool for managing remote Docker development environments with automatic SSH tunneling and port forwarding.

## Features

- **Docker Context Management** - Switch between local and remote Docker contexts seamlessly
- **Smart SSH Tunneling** - Automatic port discovery from compose files with conflict resolution
- **NPM Command Browser** - Execute npm scripts on local or remote projects interactively
- **Container Viewer** - Browse and manage Docker containers across contexts
- **Headless Mode** - Control remote machine sleep/wake settings (macOS)
- **Syncthing Integration** - Develop locally while syncing with remote machines

## Prerequisites

### Local Machine
- Bash 4.0+
- Docker Desktop (Mac) or Docker Engine (Linux)
- `jq` - JSON processor
- SSH client with key-based authentication

### Remote Machines (Mac)
- macOS with Homebrew
- Colima or Docker Desktop
- SSH server enabled

### Remote Machines (Linux)
- Docker Engine
- SSH server enabled

## Installation

### 1. Clone Repository
```bash
cd ~/Development
git clone <repository-url> rocker
cd rocker
chmod +x rocker
```

### 2. Install Dependencies

**macOS:**
```bash
brew install jq
```

**Linux:**
```bash
# Ubuntu/Debian
sudo apt-get install jq

# Fedora/RHEL
sudo dnf install jq
```

### 3. Configure Rocker

Copy the example config and edit:
```bash
cp rocker-config.example.json rocker-config.json
```

Example `rocker-config.json`:

```json
{
  "contexts": [
    {
      "name": "local",
      "type": "local",
      "description": "Local development (this machine)",
      "docker_engine": "docker-desktop",
      "docker_context": "desktop-linux"
    },
    {
      "name": "remote_zermatt",
      "type": "remote",
      "host": "zermatt.local",
      "user": "",
      "description": "Remote Mac (zermatt)",
      "docker_engine": "colima",
      "docker_context_pattern": "colima-{project}"
    }
  ],
  "default_context": "local",
  "paths": {
    "local_root_dir": "~/Development",
    "local_namespace": "Barkley"
  },
  "headless": {
    "normal_sleep": 10,
    "normal_display_sleep": 10,
    "normal_disk_sleep": 10
  }
}
```

### 4. Setup SSH Keys

**Generate SSH key (if needed):**
```bash
ssh-keygen -t ed25519 -C "your_email@example.com"
```

**Copy to remote machine:**
```bash
ssh-copy-id user@remote-host.local
```

**Test connection:**
```bash
ssh user@remote-host.local
```

## Remote Machine Setup

### macOS Remote Setup

**1. Install Homebrew:**
```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

**2. Install Colima and Docker:**
```bash
brew install colima docker docker-compose
```

**3. Start Colima:**
```bash
# Start default instance
colima start

# Or start project-specific instance
colima start tapestry-mono --cpu 4 --memory 8
```

**4. Create Docker Context:**
```bash
# Create context for your project
docker context create colima-tapestry-mono \
  --docker "host=unix://$HOME/.colima/tapestry-mono/docker.sock"

docker context use colima-tapestry-mono
```

**5. Enable Remote Login:**
```bash
# System Settings → General → Sharing → Remote Login (On)
# Or via command line:
sudo systemsetup -setremotelogin on
```

### Linux Remote Setup

**1. Install Docker:**
```bash
# Ubuntu/Debian
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker $USER

# Log out and back in for group changes to take effect
```

**2. Enable SSH:**
```bash
# Ubuntu/Debian
sudo apt-get install openssh-server
sudo systemctl enable ssh
sudo systemctl start ssh
```

**3. Create Docker Context (optional):**
```bash
# For project-specific contexts
docker context create myproject --description "My Project Context"
docker context use myproject
```

## Docker Context Setup for Remote Access

### On Local Machine

Create SSH-based Docker contexts pointing to remote machines:

```bash
# Create context for remote Mac running Colima
docker context create zermatt \
  --docker "host=ssh://user@zermatt.local"

# Create context for specific remote project
docker context create colima-tapestry-mono \
  --docker "host=ssh://user@zermatt.local" \
  --description "Tapestry Mono on Zermatt"

# List contexts
docker context ls

# Switch context
docker context use colima-tapestry-mono
```

## Usage

### Start Rocker
```bash
cd ~/Development/rocker
./rocker
```

### Main Menu

```
1) Select project for remote development
2) Select Docker context
3) Manage SSH tunnels
4) Browse/run NPM scripts
5) View Docker containers
6) Headless mode management
```

### Typical Workflow

**1. Switch Docker Context:**
- Select option 2: "Select Docker context"
- Choose remote context (e.g., "zermatt")
- Select remote Docker context (e.g., "colima-tapestry-mono")
- Project detected automatically (tapestry-mono)

**2. Setup SSH Tunnel:**
- Select option 3: "Manage SSH tunnels"
- Choose "Start tunnel" (option 1)
- Select remote host number
- System detects active context and project
- Choose compose files for port mapping (individual or all)
- Tunnel starts with discovered ports

**3. Run NPM Commands:**
- Select option 4: "Browse/run NPM scripts"
- Commands execute in currently active context
- Browse and run scripts interactively

## Port Mapping

Rocker automatically discovers ports from your compose files and creates SSH tunnels with conflict resolution:

- Scans `compose.yml`, `compose.yaml`, `docker-compose.yml`, `docker-compose.yaml`
- Maps remote ports to available local ports
- Handles port conflicts automatically
- Privileged ports (<1024) mapped to unprivileged range (e.g., 80 → 8080)

**Example:**
```yaml
# Remote compose file has:
services:
  backend:
    ports:
      - "3000:3000"
  frontend:
    ports:
      - "5173:5173"

# Rocker creates tunnel:
# Local 3001 → Remote 3000
# Local 5174 → Remote 5173
```

## Project Structure

```
rocker/
├── rocker                 # Main executable
├── rocker-config.json     # Configuration (git-ignored)
├── rocker-config.example.json
└── src/
    ├── colors.sh         # Color definitions
    ├── init.sh           # Initialization
    ├── config.sh         # Configuration management
    ├── utils.sh          # Utility functions
    ├── project.sh        # Project discovery & port mapping
    ├── tunnel.sh         # SSH tunnel management
    ├── docker.sh         # Docker context management
    ├── containers.sh     # Container viewing
    ├── npm.sh            # NPM command browser
    ├── headless.sh       # Headless mode (macOS)
    └── menu.sh           # Main menu
```

## Troubleshooting

### SSH Connection Issues
```bash
# Test SSH connection
ssh -v user@remote-host.local

# Check SSH key permissions
chmod 600 ~/.ssh/id_ed25519
chmod 644 ~/.ssh/id_ed25519.pub
```

### Docker Context Issues
```bash
# List all contexts
docker context ls

# Inspect context
docker context inspect context-name

# Remove and recreate context
docker context rm context-name
docker context create context-name --docker "host=ssh://user@host"
```

### Tunnel Issues
```bash
# Check active SSH tunnels
ps aux | grep "ssh.*-N"

# Kill stuck tunnels
pkill -f "ssh.*-N.*hostname"

# Test SSH tunnel manually
ssh -L 3001:localhost:3000 -N user@remote-host.local
```

### Colima Issues (macOS Remote)
```bash
# Check Colima status
colima status

# Restart Colima
colima stop
colima start

# List Colima instances
colima list

# Check Docker socket
ls -la ~/.colima/default/docker.sock
```

### Port Discovery Issues
```bash
# Verify compose files exist
find ~/Development/Barkley/project-name -name "compose.yml"

# Check SELECTED_COMPOSE_FILES is set correctly
# (Rocker uses this global variable for port discovery)
```

## Advanced Usage

### Multiple Remote Machines
Add multiple remote contexts to your config:

```json
{
  "contexts": [
    {"name": "local", "type": "local", ...},
    {"name": "remote_mac", "type": "remote", "host": "mac.local", ...},
    {"name": "remote_linux", "type": "remote", "host": "linux.local", ...}
  ]
}
```

### Project-Specific Colima Instances

```bash
# On remote Mac, start multiple Colima instances
colima start project-a --cpu 4 --memory 8
colima start project-b --cpu 2 --memory 4

# Create Docker contexts for each
docker context create colima-project-a \
  --docker "host=unix://$HOME/.colima/project-a/docker.sock"

docker context create colima-project-b \
  --docker "host=unix://$HOME/.colima/project-b/docker.sock"

# On local machine, create SSH contexts
docker context create colima-project-a \
  --docker "host=ssh://user@remote.local"

docker context create colima-project-b \
  --docker "host=ssh://user@remote.local"
```

### Custom Port Mappings

Rocker reads ports from compose files. To customize:

1. Add ports to your `compose.yml`:
```yaml
services:
  app:
    ports:
      - "3000:3000"
      - "5173:5173"
```

2. When starting tunnel, select specific compose files or "All"
3. Rocker discovers and maps these ports automatically

### Headless Mode (macOS Only)

For macOS laptops used as remote development servers:

```bash
# Enable headless mode (lid-closed operation)
./rocker-headless on

# Disable headless mode
./rocker-headless off

# Check current status
./rocker-headless status
```

## Configuration Reference

### Context Types

**Local Context:**
```json
{
  "name": "local",
  "type": "local",
  "docker_engine": "docker-desktop",
  "docker_context": "desktop-linux"
}
```

**Remote Context:**
```json
{
  "name": "remote_machine",
  "type": "remote",
  "host": "hostname.local",
  "user": "username",
  "docker_engine": "colima",
  "docker_context_pattern": "colima-{project}"
}
```

### Paths Configuration

```json
"paths": {
  "local_root_dir": "~/Development",
  "local_namespace": "Barkley"
}
```

Projects are expected at: `~/Development/Barkley/project-name/`

### Headless Configuration (macOS)

```json
"headless": {
  "normal_sleep": 10,
  "normal_display_sleep": 10,
  "normal_disk_sleep": 10
}
```

## How It Works

### Port Discovery Flow

1. User selects Docker context → system infers project name
2. User starts tunnel → system detects active Docker context on remote
3. User selects compose files (individual or all)
4. Rocker scans selected compose files for port mappings
5. Generates tunnel with conflict-free local ports
6. SSH tunnel started with `-L localport:localhost:remoteport` for each mapping

### Context Inference

- `colima-tapestry-mono` → Project: `tapestry-mono`
- `colima-ai-intake` → Project: `ai-intake`
- Custom contexts use full name as project

## License

MIT

## Contributing

Issues and pull requests welcome!
