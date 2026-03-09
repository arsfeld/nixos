#!/usr/bin/env python3
"""Sync Cloudflare DNS CNAME records for cloudflared tunnel services.

Creates CNAME records pointing service subdomains to the tunnel endpoint.
Skips records that already exist.

Supports two auth methods (checked in order):
  1. API Token: CLOUDFLARE_DNS_API_TOKEN or CF_DNS_API_TOKEN
  2. Global API Key: CLOUDFLARE_API_KEY + CLOUDFLARE_EMAIL
"""

import argparse
import json
import os
import sys
import urllib.request


def get_auth_headers():
    """Determine auth headers from environment variables."""
    token = os.environ.get("CLOUDFLARE_DNS_API_TOKEN") or os.environ.get("CF_DNS_API_TOKEN")
    if token:
        return {"Authorization": f"Bearer {token}"}

    api_key = os.environ.get("CLOUDFLARE_API_KEY")
    email = os.environ.get("CLOUDFLARE_EMAIL")
    if api_key and email:
        return {"X-Auth-Key": api_key, "X-Auth-Email": email}

    print("ERROR: No Cloudflare credentials found in environment", file=sys.stderr)
    print("Set CLOUDFLARE_DNS_API_TOKEN, or CLOUDFLARE_API_KEY + CLOUDFLARE_EMAIL", file=sys.stderr)
    sys.exit(1)


def cf_api(method, path, auth_headers, data=None):
    headers = {**auth_headers, "Content-Type": "application/json"}
    req = urllib.request.Request(
        f"https://api.cloudflare.com/client/v4/{path}",
        method=method,
        headers=headers,
        data=json.dumps(data).encode() if data else None,
    )
    with urllib.request.urlopen(req) as resp:
        result = json.loads(resp.read())
    if not result.get("success"):
        errors = result.get("errors", [])
        raise RuntimeError(f"Cloudflare API error: {errors}")
    return result


def main():
    parser = argparse.ArgumentParser(
        description="Sync Cloudflare DNS CNAME records for tunnel services"
    )
    parser.add_argument("--tunnel-id", required=True, help="Cloudflare tunnel UUID")
    parser.add_argument("--domain", required=True, help="Base domain (e.g. arsfeld.one)")
    parser.add_argument(
        "--hostnames", required=True, help="JSON array of FQDNs to create CNAMEs for"
    )
    args = parser.parse_args()

    auth = get_auth_headers()

    hostnames = json.loads(args.hostnames)
    tunnel_cname = f"{args.tunnel_id}.cfargotunnel.com"

    print(f"Syncing {len(hostnames)} DNS records for tunnel {args.tunnel_id}")
    print(f"Tunnel CNAME target: {tunnel_cname}")

    # Get zone ID for the domain
    zones = cf_api("GET", f"zones?name={args.domain}", auth)
    if not zones["result"]:
        print(f"ERROR: Zone not found for domain {args.domain}", file=sys.stderr)
        sys.exit(1)
    zone_id = zones["result"][0]["id"]
    print(f"Zone ID: {zone_id}")

    # Get existing CNAME records in the zone
    existing = cf_api(
        "GET", f"zones/{zone_id}/dns_records?type=CNAME&per_page=500", auth
    )
    existing_map = {r["name"]: r for r in existing["result"]}

    created = 0
    updated = 0
    skipped = 0

    for hostname in hostnames:
        if hostname in existing_map:
            record = existing_map[hostname]
            if record["content"] == tunnel_cname:
                print(f"  skip (exists): {hostname}")
                skipped += 1
            else:
                # Update existing record to point to our tunnel
                print(
                    f"  update: {hostname} ({record['content']} -> {tunnel_cname})"
                )
                cf_api(
                    "PUT",
                    f"zones/{zone_id}/dns_records/{record['id']}",
                    auth,
                    {
                        "type": "CNAME",
                        "name": hostname,
                        "content": tunnel_cname,
                        "proxied": True,
                    },
                )
                updated += 1
        else:
            print(f"  create: {hostname} -> {tunnel_cname}")
            cf_api(
                "POST",
                f"zones/{zone_id}/dns_records",
                auth,
                {
                    "type": "CNAME",
                    "name": hostname,
                    "content": tunnel_cname,
                    "proxied": True,
                },
            )
            created += 1

    print(f"Done: {created} created, {updated} updated, {skipped} unchanged")


if __name__ == "__main__":
    main()
