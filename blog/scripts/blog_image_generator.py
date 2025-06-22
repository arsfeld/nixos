#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "requests>=2.31.0",
#     "pyyaml>=6.0.1",
#     "rich>=13.7.0",
#     "typer>=0.9.0",
# ]
# ///
"""
AI Image Generation for Blog Posts

A structured system for generating images using Google Cloud Imagen API
with YAML-configured prompts, styles, and post personalities.
"""

import base64
import json
import subprocess
import tempfile
from pathlib import Path
from typing import Dict, List, Optional, Any
import yaml

import requests
import typer
from rich.console import Console
from rich.table import Table
from rich.panel import Panel
from rich.progress import Progress, SpinnerColumn, TextColumn
from rich import print as rprint

app = typer.Typer(
    help="Generate AI images for blog posts with structured prompts and styles"
)
console = Console()

# Configuration
PROJECT_ID = "gen-lang-client-0826920246"
LOCATION_ID = "us-central1"
API_ENDPOINT = "us-central1-aiplatform.googleapis.com"
MODEL_ID = "imagen-4.0-generate-preview-05-20"

DEFAULT_OUTPUT_DIR = Path("../static/images/generated")
PROMPTS_FILE = Path("image-prompts.yaml")


class ImageGenerator:
    """Main class for handling image generation with Google Cloud Imagen API."""

    def __init__(self, prompts_file: Path = PROMPTS_FILE):
        self.prompts_file = prompts_file
        self.config = self._load_config()

    def _load_config(self) -> Dict[str, Any]:
        """Load configuration from YAML file."""
        if not self.prompts_file.exists():
            console.print(
                f"[red]Error: Prompts file '{self.prompts_file}' not found[/red]"
            )
            raise typer.Exit(1)

        with open(self.prompts_file, "r") as f:
            return yaml.safe_load(f)

    def _get_auth_token(self) -> str:
        """Get authentication token using gcloud via Nix."""
        try:
            result = subprocess.run(
                [
                    "nix",
                    "run",
                    "nixpkgs#google-cloud-sdk",
                    "--",
                    "auth",
                    "print-access-token",
                ],
                capture_output=True,
                text=True,
                check=True,
            )
            return result.stdout.strip()
        except subprocess.CalledProcessError as e:
            if "You do not currently have an active account" in e.stderr:
                console.print(
                    "[red]Error: No authenticated Google Cloud account found.[/red]"
                )
                console.print("Please authenticate first:")
                console.print('  nix run "nixpkgs#google-cloud-sdk" -- auth login')
                console.print(f"Then set your project:")
                console.print(
                    f'  nix run "nixpkgs#google-cloud-sdk" -- config set project {PROJECT_ID}'
                )
            else:
                console.print(f"[red]Authentication error: {e.stderr}[/red]")
            raise typer.Exit(1)

    def _build_full_prompt(self, post_id: str, base_prompt: str) -> str:
        """Build complete prompt including post style and personality."""
        post_styles = self.config.get("post_styles", {})
        post_style = post_styles.get(post_id, {})

        full_prompt = base_prompt

        style_desc = post_style.get("description", "")
        if style_desc:
            full_prompt += f", {style_desc}"

        personality = post_style.get("personality", "")
        if personality:
            full_prompt += f", {personality}"

        return full_prompt

    def _generate_image(
        self,
        full_prompt: str,
        output_id: str,
        aspect_ratio: str = "16:9",
        sample_count: int = 3,
        output_dir: Path = DEFAULT_OUTPUT_DIR,
    ) -> List[Path]:
        """Generate images using Google Cloud Imagen API."""

        console.print(f"[blue]Generating: {output_id}[/blue]")
        console.print(f"Prompt: {full_prompt}")
        console.print(f"Samples: {sample_count}")

        # Prepare request
        request_data = {
            "instances": [{"prompt": full_prompt}],
            "parameters": {
                "aspectRatio": aspect_ratio,
                "sampleCount": sample_count,
                "negativePrompt": "text, watermark, logo, signature, low quality, blurry, people, faces",
                "enhancePrompt": True,
                "personGeneration": "dont_allow",
                "safetySetting": "block_some",
                "addWatermark": False,
                "includeRaiReason": True,
                "language": "auto",
            },
        }

        # Get auth token and make request
        auth_token = self._get_auth_token()
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {auth_token}",
        }

        url = f"https://{API_ENDPOINT}/v1/projects/{PROJECT_ID}/locations/{LOCATION_ID}/publishers/google/models/{MODEL_ID}:predict"

        with Progress(
            SpinnerColumn(),
            TextColumn("[progress.description]{task.description}"),
            console=console,
        ) as progress:
            task = progress.add_task("Calling Imagen API...", total=None)

            try:
                response = requests.post(
                    url, headers=headers, json=request_data, timeout=120
                )
                response.raise_for_status()
            except requests.exceptions.RequestException as e:
                console.print(f"[red]API request failed: {e}[/red]")
                raise typer.Exit(1)

        response_data = response.json()

        # Check for API errors
        if "error" in response_data:
            console.print(f"[red]API Error: {response_data['error']}[/red]")
            raise typer.Exit(1)

        # Save response for debugging
        output_dir.mkdir(parents=True, exist_ok=True)
        response_file = output_dir / f"{output_id}_response.json"
        with open(response_file, "w") as f:
            json.dump(response_data, f, indent=2)

        # Extract and save images
        saved_files = []
        predictions = response_data.get("predictions", [])

        for i, prediction in enumerate(predictions, 1):
            base64_image = prediction.get("bytesBase64Encoded")
            if base64_image:
                filename = f"{output_id}_{i}.png"
                filepath = output_dir / filename

                # Decode and save image
                image_data = base64.b64decode(base64_image)
                with open(filepath, "wb") as f:
                    f.write(image_data)

                saved_files.append(filepath)
                console.print(f"[green]✓ Saved: {filepath}[/green]")

        return saved_files

    def list_prompts(self, post_filter: Optional[str] = None) -> None:
        """List all available prompts, optionally filtered by post."""

        prompts = self.config.get("prompts", {})
        post_styles = self.config.get("post_styles", {})

        if post_filter:
            if post_filter not in prompts:
                console.print(f"[red]Error: Post '{post_filter}' not found[/red]")
                raise typer.Exit(1)
            posts_to_show = {post_filter: prompts[post_filter]}
        else:
            posts_to_show = prompts

        console.print("[blue]Available Image Prompts:[/blue]\n")

        for post_id, post_prompts in posts_to_show.items():
            # Create post panel
            style_info = post_styles.get(post_id, {})
            style_desc = style_info.get("description", "No style defined")
            personality = style_info.get("personality", "No personality defined")

            table = Table(show_header=True, header_style="bold magenta", width=120)
            table.add_column("P", style="dim", width=3)
            table.add_column("Key", style="cyan", width=12)
            table.add_column("ID", style="green", width=30)
            table.add_column("Prompt", style="white", width=70)

            # Sort prompts by priority
            sorted_prompts = sorted(
                post_prompts.items(), key=lambda x: x[1].get("priority", 999)
            )

            for prompt_key, prompt_data in sorted_prompts:
                prompt_text = prompt_data.get("base_prompt", "")
                if len(prompt_text) > 65:
                    prompt_text = prompt_text[:65] + "..."

                table.add_row(
                    str(prompt_data.get("priority", "?")),
                    prompt_key,
                    prompt_data.get("id", ""),
                    prompt_text,
                )

            # Create panel with style info and table
            style_info = f"[bold]Style:[/bold] {style_desc}\n[bold]Personality:[/bold] {personality}"

            # Print style info first, then table in a panel
            console.print(f"📝 [bold blue]{post_id}[/bold blue]")
            console.print(style_info)
            console.print()
            panel = Panel(table, border_style="blue")
            console.print(panel)
            console.print()

    def list_styles(self) -> None:
        """List all post styles."""
        post_styles = self.config.get("post_styles", {})

        console.print("[blue]Post Styles:[/blue]\n")

        for post_id, style_data in post_styles.items():
            description = style_data.get("description", "")
            personality = style_data.get("personality", "")

            panel = Panel(
                f"[bold]Description:[/bold] {description}\n[bold]Personality:[/bold] {personality}",
                title=f"🎨 {post_id}",
                title_align="left",
                border_style="yellow",
            )
            console.print(panel)

    def generate_images(
        self,
        post_id: str,
        prompt_key: Optional[str] = None,
        sample_count: int = 3,
        output_dir: Path = DEFAULT_OUTPUT_DIR,
    ) -> None:
        """Generate images for a post or specific prompt."""

        prompts = self.config.get("prompts", {})

        if post_id not in prompts:
            console.print(f"[red]Error: Post '{post_id}' not found[/red]")
            raise typer.Exit(1)

        post_prompts = prompts[post_id]

        if prompt_key:
            # Generate specific prompt
            if prompt_key not in post_prompts:
                console.print(
                    f"[red]Error: Prompt '{prompt_key}' not found for post '{post_id}'[/red]"
                )
                raise typer.Exit(1)

            prompts_to_generate = {prompt_key: post_prompts[prompt_key]}
        else:
            # Generate all prompts for post
            prompts_to_generate = post_prompts
            console.print(f"[blue]Generating all images for: {post_id}[/blue]\n")

        # Generate images
        for prompt_key, prompt_data in prompts_to_generate.items():
            prompt_id = prompt_data.get("id", f"{post_id}-{prompt_key}")
            base_prompt = prompt_data.get("base_prompt", "")
            aspect_ratio = prompt_data.get("aspect_ratio", "16:9")

            full_prompt = self._build_full_prompt(post_id, base_prompt)

            try:
                saved_files = self._generate_image(
                    full_prompt, prompt_id, aspect_ratio, sample_count, output_dir
                )
                console.print(
                    f"[green]Generated {len(saved_files)} images for {prompt_id}[/green]\n"
                )
            except Exception as e:
                console.print(f"[red]Failed to generate {prompt_id}: {e}[/red]\n")

    def regenerate_by_id(
        self,
        target_id: str,
        sample_count: int = 3,
        output_dir: Path = DEFAULT_OUTPUT_DIR,
    ) -> None:
        """Regenerate images by ID."""

        prompts = self.config.get("prompts", {})

        # Find the prompt by ID
        found = False
        for post_id, post_prompts in prompts.items():
            for prompt_key, prompt_data in post_prompts.items():
                if prompt_data.get("id") == target_id:
                    base_prompt = prompt_data.get("base_prompt", "")
                    aspect_ratio = prompt_data.get("aspect_ratio", "16:9")

                    console.print(f"[blue]Regenerating: {target_id}[/blue]")
                    full_prompt = self._build_full_prompt(post_id, base_prompt)

                    self._generate_image(
                        full_prompt, target_id, aspect_ratio, sample_count, output_dir
                    )
                    found = True
                    break
            if found:
                break

        if not found:
            console.print(f"[red]Error: Image ID '{target_id}' not found[/red]")
            raise typer.Exit(1)


# CLI Commands
@app.command()
def list_prompts(
    post: Optional[str] = typer.Argument(None, help="Filter by specific post ID")
):
    """List all available prompts, optionally filtered by post."""
    generator = ImageGenerator()
    generator.list_prompts(post)


@app.command()
def styles():
    """List all post styles."""
    generator = ImageGenerator()
    generator.list_styles()


@app.command()
def generate(
    post_id: str = typer.Argument(..., help="Post ID to generate images for"),
    prompt_key: Optional[str] = typer.Argument(
        None, help="Specific prompt key (optional)"
    ),
    count: int = typer.Option(3, "--count", "-n", help="Number of samples to generate"),
    output_dir: str = typer.Option(
        str(DEFAULT_OUTPUT_DIR), "--output-dir", "-d", help="Output directory"
    ),
):
    """Generate images for a post or specific prompt."""
    generator = ImageGenerator()
    generator.generate_images(post_id, prompt_key, count, Path(output_dir))


@app.command()
def regenerate(
    image_id: str = typer.Argument(..., help="Image ID to regenerate"),
    count: int = typer.Option(3, "--count", "-n", help="Number of samples to generate"),
    output_dir: str = typer.Option(
        str(DEFAULT_OUTPUT_DIR), "--output-dir", "-d", help="Output directory"
    ),
):
    """Regenerate images by ID."""
    generator = ImageGenerator()
    generator.regenerate_by_id(image_id, count, Path(output_dir))


@app.command()
def add_prompt():
    """Interactive prompt to add a new image prompt."""
    console.print("[yellow]Interactive prompt addition not yet implemented[/yellow]")
    console.print("Please edit image-prompts.yaml manually for now.")


if __name__ == "__main__":
    app()
