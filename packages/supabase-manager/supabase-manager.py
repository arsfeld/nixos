#!/usr/bin/env -S uv run --quiet --script
# /// script
# dependencies = [
#   "textual>=0.47.0",
#   "docker>=7.0.0",
#   "rich>=13.0.0",
#   "httpx>=0.25.0",
#   "pyyaml>=6.0",
#   "click>=8.1.0",
#   "python-dotenv>=1.0.0",
# ]
# ///

import asyncio
import json
import os
import secrets
import shutil
import string
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional

import click
import docker
import httpx
import yaml
from rich.console import Console
from rich.table import Table
from textual import on
from textual.app import App, ComposeResult
from textual.containers import Container, Horizontal, Vertical
from textual.reactive import reactive
from textual.screen import Screen
from textual.widgets import Button, DataTable, Footer, Header, Label, Static

console = Console()

# Configuration
SUPABASE_DATA_DIR = Path(os.environ.get("SUPABASE_DATA_DIR", "/var/lib/supabase"))
SUPABASE_DOMAIN = os.environ.get("SUPABASE_DOMAIN", "arsfeld.dev")
STATE_FILE = SUPABASE_DATA_DIR / "state.json"
GITHUB_BASE_URL = "https://raw.githubusercontent.com/supabase/supabase/master/docker"

# Port ranges - only Kong needs external access
KONG_PORT_START = 8000


class InstanceState:
    """Manages the state of all Supabase instances"""
    
    def __init__(self):
        self.state_file = STATE_FILE
        self.state = self._load_state()
    
    def _load_state(self) -> dict:
        """Load state from file or create new"""
        if self.state_file.exists():
            try:
                with open(self.state_file, 'r') as f:
                    return json.load(f)
            except:
                console.print("[red]Warning: Could not load state file, creating new one[/red]")
        
        return {"instances": {}}
    
    def save(self):
        """Save current state to file"""
        self.state_file.parent.mkdir(parents=True, exist_ok=True)
        with open(self.state_file, 'w') as f:
            json.dump(self.state, f, indent=2)
    
    def add_instance(self, name: str, ports: dict, version: str = "latest"):
        """Add a new instance to state"""
        self.state["instances"][name] = {
            "created_at": datetime.now().isoformat(),
            "ports": ports,
            "version": version,
            "status": "created"
        }
        self.save()
    
    def remove_instance(self, name: str):
        """Remove instance from state"""
        if name in self.state["instances"]:
            del self.state["instances"][name]
            self.save()
    
    def get_instance(self, name: str) -> Optional[dict]:
        """Get instance details"""
        return self.state["instances"].get(name)
    
    def list_instances(self) -> dict:
        """List all instances"""
        return self.state["instances"]
    
    def get_next_ports(self) -> dict:
        """Get next available Kong port for a new instance"""
        used_kong_ports = set()
        
        for instance in self.state["instances"].values():
            ports = instance.get("ports", {})
            if "kong" in ports:
                used_kong_ports.add(ports["kong"])
        
        # Find next available Kong port
        kong_port = KONG_PORT_START
        while kong_port in used_kong_ports:
            kong_port += 1
        
        return {
            "kong": kong_port
        }


class SupabaseManager:
    """Core Supabase instance management logic"""
    
    def __init__(self):
        self.state = InstanceState()
        self.docker_client = docker.from_env()
        self.templates_dir = SUPABASE_DATA_DIR / "templates"
        self.instances_dir = SUPABASE_DATA_DIR / "instances"
        self.caddy_dir = SUPABASE_DATA_DIR / "caddy"
    
    def generate_password(self, length: int = 32) -> str:
        """Generate a secure random password"""
        alphabet = string.ascii_letters + string.digits
        return ''.join(secrets.choice(alphabet) for _ in range(length))
    
    def generate_jwt_secret(self) -> str:
        """Generate a JWT secret"""
        return secrets.token_urlsafe(32)
    
    async def download_supabase_files(self):
        """Download Supabase Docker files from GitHub"""
        self.templates_dir.mkdir(parents=True, exist_ok=True)
        
        files_to_download = [
            "docker-compose.yml",
            ".env.example",
            "volumes/api/kong.yml",
            "volumes/db/init/data.sql",
            "volumes/db/realtime.sql",
            "volumes/db/webhooks.sql",
            "volumes/db/roles.sql",
            "volumes/db/jwt.sql",
            "volumes/logs/vector.yml",
        ]
        
        async with httpx.AsyncClient() as client:
            for file_path in files_to_download:
                url = f"{GITHUB_BASE_URL}/{file_path}"
                console.print(f"Downloading {file_path}...")
                
                try:
                    response = await client.get(url)
                    response.raise_for_status()
                    
                    local_path = self.templates_dir / file_path
                    local_path.parent.mkdir(parents=True, exist_ok=True)
                    local_path.write_text(response.text)
                except Exception as e:
                    console.print(f"[yellow]Warning: Could not download {file_path}: {e}[/yellow]")
                    continue
    
    def render_docker_compose(self, name: str, ports: dict, env_vars: dict) -> str:
        """Render docker-compose.yml template with instance-specific values"""
        template_path = self.templates_dir / "docker-compose.yml" 
        
        if not template_path.exists():
            raise FileNotFoundError(f"Docker compose template not found at {template_path}. Run 'supabase-manager download' first.")
        
        template = template_path.read_text()
        
        # Replace hardcoded values that can't be set via environment variables
        
        # 1. Change the compose project name from "supabase" to "supabase-{instance}"
        rendered = template.replace("name: supabase", f"name: supabase-{name}")
        
        # 2. Replace all container names to include instance name
        container_replacements = [
            ("supabase-studio", f"supabase-{name}-studio"),
            ("supabase-kong", f"supabase-{name}-kong"),
            ("supabase-auth", f"supabase-{name}-auth"),
            ("supabase-rest", f"supabase-{name}-rest"),
            ("realtime-dev.supabase-realtime", f"supabase-{name}-realtime"),
            ("supabase-storage", f"supabase-{name}-storage"),
            ("supabase-imgproxy", f"supabase-{name}-imgproxy"),
            ("supabase-meta", f"supabase-{name}-meta"),
            ("supabase-edge-functions", f"supabase-{name}-functions"),
            ("supabase-analytics", f"supabase-{name}-analytics"),
            ("supabase-db", f"supabase-{name}-db"),
            ("supabase-vector", f"supabase-{name}-vector"),
            ("supabase-pooler", f"supabase-{name}-pooler"),
        ]
        
        for old_name, new_name in container_replacements:
            rendered = rendered.replace(f"container_name: {old_name}", f"container_name: {new_name}")
        
        # No modifications needed - vector.yml will be fixed instead
        
        return rendered
    
    def create_caddy_config(self, name: str):
        """Create Caddy configuration for instance"""
        instance = self.state.get_instance(name)
        if not instance:
            raise ValueError(f"Instance {name} not found")
        
        ports = instance["ports"]
        config = f"""
# Supabase instance: {name}

# Main API endpoint - Kong routes to all services internally
{name}.{SUPABASE_DOMAIN} {{
    reverse_proxy localhost:{ports['kong']}
}}
"""
        
        caddy_file = self.caddy_dir / f"{name}.conf"
        caddy_file.write_text(config)
        
        # Reload Caddy
        os.system("systemctl reload caddy")
    
    def remove_caddy_config(self, name: str):
        """Remove Caddy configuration for instance"""
        caddy_file = self.caddy_dir / f"{name}.conf"
        if caddy_file.exists():
            caddy_file.unlink()
            os.system("systemctl reload caddy")
    
    def get_instance_status(self, name: str) -> str:
        """Get status of instance containers"""
        try:
            containers = self.docker_client.containers.list(
                all=True,
                filters={"label": f"supabase.instance={name}"}
            )
            
            if not containers:
                return "not_found"
            
            running = sum(1 for c in containers if c.status == "running")
            total = len(containers)
            
            if running == total:
                return "running"
            elif running > 0:
                return "partial"
            else:
                return "stopped"
        except:
            return "error"
    
    def create_instance(self, name: str) -> dict:
        """Create a new Supabase instance"""
        # Validate name
        if not name.replace("-", "").isalnum():
            raise ValueError("Instance name must be alphanumeric with hyphens only")
        
        if self.state.get_instance(name):
            raise ValueError(f"Instance {name} already exists")
        
        # Get available ports
        ports = self.state.get_next_ports()
        
        # Create instance directory
        instance_dir = self.instances_dir / name
        instance_dir.mkdir(parents=True, exist_ok=True)
        
        # Generate secrets
        jwt_secret = self.generate_jwt_secret()
        anon_key = self.generate_password(64)
        service_key = self.generate_password(64)
        db_password = self.generate_password()
        dashboard_password = self.generate_password()
        
        # Environment variables for templates
        env_vars = {
            'POSTGRES_PASSWORD': db_password,
            'JWT_SECRET': jwt_secret,
            'ANON_KEY': anon_key,
            'SERVICE_KEY': service_key,
            'DASHBOARD_PASSWORD': dashboard_password,
            'STUDIO_DEFAULT_ORGANIZATION': f"{name} Organization",
            'STUDIO_DEFAULT_PROJECT': f"{name} Project",
        }
        
        # Create .env file with all required Supabase environment variables
        env_content = f"""# Instance: {name}
# Generated on {datetime.now().isoformat()}

# Database
POSTGRES_PASSWORD={db_password}
POSTGRES_HOST=supabase-{name}-db
POSTGRES_PORT=5432
POSTGRES_DB=postgres

# Auth & JWT
JWT_SECRET={jwt_secret}
ANON_KEY={anon_key}
SERVICE_ROLE_KEY={service_key}
JWT_EXPIRY=3600

# Dashboard
DASHBOARD_USERNAME=supabase
DASHBOARD_PASSWORD={dashboard_password}

# Ports - only Kong is exposed externally
KONG_HTTP_PORT={ports['kong']}
KONG_HTTPS_PORT={ports['kong'] + 1000}

# Studio configuration
STUDIO_DEFAULT_ORGANIZATION={name} Organization
STUDIO_DEFAULT_PROJECT={name} Project

# API URLs
SUPABASE_PUBLIC_URL=https://{name}.{SUPABASE_DOMAIN}
API_EXTERNAL_URL=https://{name}.{SUPABASE_DOMAIN}
SITE_URL=https://{name}.{SUPABASE_DOMAIN}

# Auth configuration
ENABLE_EMAIL_SIGNUP=true
ENABLE_EMAIL_AUTOCONFIRM=false
ENABLE_PHONE_SIGNUP=true
ENABLE_PHONE_AUTOCONFIRM=false
ENABLE_ANONYMOUS_USERS=false
DISABLE_SIGNUP=false

# Additional configuration
MAILER_URLPATHS_CONFIRMATION=/auth/v1/verify
MAILER_URLPATHS_INVITE=/auth/v1/verify
MAILER_URLPATHS_RECOVERY=/auth/v1/verify
MAILER_URLPATHS_EMAIL_CHANGE=/auth/v1/verify

# PostgREST
PGRST_DB_SCHEMAS=public,storage,graphql_public

# Pooler
POOLER_DEFAULT_POOL_SIZE=20
POOLER_MAX_CLIENT_CONN=100
POOLER_PROXY_PORT_TRANSACTION=6543
POOLER_TENANT_ID={name}

# Functions
FUNCTIONS_VERIFY_JWT=false

# Storage
IMGPROXY_ENABLE_WEBP_DETECTION=true

# SMTP (optional - leave blank for now)
SMTP_HOST=
SMTP_PORT=587
SMTP_USER=
SMTP_PASS=
SMTP_ADMIN_EMAIL=
SMTP_SENDER_NAME=

# Analytics (default Supabase values)
LOGFLARE_PRIVATE_ACCESS_TOKEN=your-super-secret-and-long-logflare-key-private
LOGFLARE_PUBLIC_ACCESS_TOKEN=your-super-secret-and-long-logflare-key-public

# Additional URLs (optional)
ADDITIONAL_REDIRECT_URLS=

# Vault (generated)
VAULT_ENC_KEY={self.generate_password(32)}
SECRET_KEY_BASE={self.generate_password(64)}

# Docker socket - fix the invalid spec
DOCKER_SOCKET_LOCATION=/var/run/docker.sock

# Instance metadata
INSTANCE_NAME={name}
"""
        
        env_file = instance_dir / ".env"
        env_file.write_text(env_content)
        
        # Render and save docker-compose.yml
        docker_compose_content = self.render_docker_compose(name, ports, env_vars)
        compose_file = instance_dir / "docker-compose.yml"
        compose_file.write_text(docker_compose_content)
        
        # Copy volume files if they exist
        volumes_dir = instance_dir / "volumes"
        volumes_dir.mkdir(exist_ok=True)
        
        for vol_path in ["volumes/api/kong.yml", "volumes/db", "volumes/logs/vector.yml"]:
            src_path = self.templates_dir / vol_path
            dst_path = volumes_dir / vol_path.replace("volumes/", "")
            
            if src_path.exists():
                dst_path.parent.mkdir(parents=True, exist_ok=True)
                if src_path.is_file():
                    content = src_path.read_text()
                    
                    # No modifications needed for vector.yml - using default Supabase tokens
                    
                    dst_path.write_text(content)
                else:
                    # Copy directory recursively
                    if dst_path.exists():
                        shutil.rmtree(dst_path)
                    shutil.copytree(src_path, dst_path)
        
        # Start containers
        try:
            result = subprocess.run(
                ["docker-compose", "up", "-d"],
                cwd=instance_dir,
                capture_output=True,
                text=True,
                check=True
            )
            console.print(f"[green]Started containers for {name}[/green]")
        except subprocess.CalledProcessError as e:
            console.print(f"[red]Failed to start containers: {e.stderr}[/red]")
            # Don't fail the creation, just warn
        except Exception as e:
            console.print(f"[yellow]Warning: Could not start containers: {e}[/yellow]")
        
        # Add to state
        self.state.add_instance(name, ports)
        
        # Create Caddy config
        self.create_caddy_config(name)
        
        return {
            "name": name,
            "ports": ports,
            "urls": {
                "api": f"https://{name}.{SUPABASE_DOMAIN}",
                "studio": f"https://{name}.{SUPABASE_DOMAIN}/dashboard",
                "docs": f"https://{name}.{SUPABASE_DOMAIN}/rest/v1/"
            }
        }
    
    def start_instance(self, name: str):
        """Start an instance's containers"""
        instance_dir = self.instances_dir / name
        if not instance_dir.exists():
            raise ValueError(f"Instance {name} not found")
        
        try:
            result = subprocess.run(
                ["docker-compose", "up", "-d"],
                cwd=instance_dir,
                capture_output=True,
                text=True,
                check=True
            )
            console.print(f"[green]Started instance {name}[/green]")
        except subprocess.CalledProcessError as e:
            console.print(f"[red]Failed to start {name}: {e.stderr}[/red]")
            raise
    
    def stop_instance(self, name: str):
        """Stop an instance's containers"""
        instance_dir = self.instances_dir / name
        if not instance_dir.exists():
            raise ValueError(f"Instance {name} not found")
        
        try:
            result = subprocess.run(
                ["docker-compose", "down"],
                cwd=instance_dir,
                capture_output=True,
                text=True,
                check=True
            )
            console.print(f"[green]Stopped instance {name}[/green]")
        except subprocess.CalledProcessError as e:
            console.print(f"[red]Failed to stop {name}: {e.stderr}[/red]")
            raise
    
    def delete_instance(self, name: str):
        """Delete an instance completely"""
        instance_dir = self.instances_dir / name
        if not instance_dir.exists():
            raise ValueError(f"Instance {name} not found")
        
        # Stop containers first
        try:
            self.stop_instance(name)
        except:
            pass  # Continue even if stop fails
        
        # Remove containers and volumes
        try:
            subprocess.run(
                ["docker-compose", "down", "-v", "--remove-orphans"],
                cwd=instance_dir,
                capture_output=True,
                text=True,
                check=True
            )
        except:
            pass  # Continue even if docker cleanup fails
        
        # Remove instance directory
        shutil.rmtree(instance_dir)
        
        # Remove from state
        self.state.remove_instance(name)
        
        # Remove Caddy config
        self.remove_caddy_config(name)
        
        console.print(f"[green]Deleted instance {name}[/green]")
    
    def start_all_instances(self):
        """Start all instances"""
        for name in self.state.list_instances():
            try:
                self.start_instance(name)
            except Exception as e:
                console.print(f"[red]Failed to start {name}: {e}[/red]")
    
    def stop_all_instances(self):
        """Stop all instances"""
        for name in self.state.list_instances():
            try:
                self.stop_instance(name)
            except Exception as e:
                console.print(f"[red]Failed to stop {name}: {e}[/red]")


class DashboardScreen(Screen):
    """Main dashboard screen"""
    
    def compose(self) -> ComposeResult:
        yield Header()
        yield Container(
            DataTable(id="instances_table"),
            id="dashboard"
        )
        yield Footer()
    
    def on_mount(self) -> None:
        table = self.query_one("#instances_table", DataTable)
        table.add_columns("Instance", "Status", "Created", "API URL", "Actions")
        self.refresh_instances()
    
    def refresh_instances(self):
        """Refresh the instances table"""
        manager = SupabaseManager()
        table = self.query_one("#instances_table", DataTable)
        table.clear()
        
        for name, details in manager.state.list_instances().items():
            status = manager.get_instance_status(name)
            created = details.get("created_at", "Unknown")[:10]
            api_url = f"{name}.{SUPABASE_DOMAIN}"
            
            table.add_row(name, status, created, api_url, "...")


class SupabaseManagerApp(App):
    """Terminal UI Application"""
    
    CSS = """
    #dashboard {
        height: 100%;
    }
    
    DataTable {
        height: 100%;
    }
    """
    
    BINDINGS = [
        ("q", "quit", "Quit"),
        ("r", "refresh", "Refresh"),
        ("c", "create", "Create"),
    ]
    
    def on_mount(self) -> None:
        self.push_screen(DashboardScreen())
    
    def action_refresh(self) -> None:
        """Refresh the current screen"""
        if isinstance(self.screen, DashboardScreen):
            self.screen.refresh_instances()
    
    def action_create(self) -> None:
        """Create new instance"""
        # TODO: Push create instance screen
        pass


@click.command()
@click.argument("command", required=False)
@click.argument("name", required=False)
def cli(command: Optional[str], name: Optional[str]):
    """Supabase instance manager"""
    
    if not command:
        # Launch TUI
        app = SupabaseManagerApp()
        app.run()
        return
    
    manager = SupabaseManager()
    
    if command == "create":
        if not name:
            console.print("[red]Error: Instance name required[/red]")
            sys.exit(1)
        
        try:
            result = manager.create_instance(name)
            console.print(f"[green]Created instance: {name}[/green]")
            console.print(f"API: {result['urls']['api']}")
            console.print(f"Studio: {result['urls']['studio']}")
            console.print(f"Docs: {result['urls']['docs']}")
        except Exception as e:
            console.print(f"[red]Error: {e}[/red]")
            sys.exit(1)
    
    elif command == "list":
        table = Table(title="Supabase Instances")
        table.add_column("Name")
        table.add_column("Status")
        table.add_column("Created")
        table.add_column("API URL")
        
        for name, details in manager.state.list_instances().items():
            status = manager.get_instance_status(name)
            created = details.get("created_at", "Unknown")[:10]
            api_url = f"https://{name}.{SUPABASE_DOMAIN}"
            table.add_row(name, status, created, api_url)
        
        console.print(table)
    
    elif command == "start":
        if not name:
            console.print("[red]Error: Instance name required[/red]")
            sys.exit(1)
        try:
            manager.start_instance(name)
        except Exception as e:
            console.print(f"[red]Error: {e}[/red]")
            sys.exit(1)
    
    elif command == "stop":
        if not name:
            console.print("[red]Error: Instance name required[/red]")
            sys.exit(1)
        try:
            manager.stop_instance(name)
        except Exception as e:
            console.print(f"[red]Error: {e}[/red]")
            sys.exit(1)
    
    elif command == "delete":
        if not name:
            console.print("[red]Error: Instance name required[/red]")
            sys.exit(1)
        try:
            manager.delete_instance(name)
        except Exception as e:
            console.print(f"[red]Error: {e}[/red]")
            sys.exit(1)
    
    elif command == "start-all":
        # Used by systemd service
        manager.start_all_instances()
    
    elif command == "stop-all":
        # Used by systemd service
        manager.stop_all_instances()
    
    elif command == "download":
        # Download Supabase files
        import asyncio
        asyncio.run(manager.download_supabase_files())
        console.print("[green]Downloaded Supabase template files[/green]")
    
    elif command == "maintenance":
        # Used by systemd timer
        console.print("Running maintenance tasks...")
        # Clean up stopped containers
        try:
            subprocess.run(["docker", "system", "prune", "-f"], check=True)
            console.print("[green]Cleaned up Docker system[/green]")
        except Exception as e:
            console.print(f"[yellow]Warning: Could not clean Docker: {e}[/yellow]")
    
    else:
        console.print(f"[red]Unknown command: {command}[/red]")
        console.print("Available commands: create, list, start, stop, delete, start-all, stop-all, download, maintenance")
        sys.exit(1)


if __name__ == "__main__":
    cli()