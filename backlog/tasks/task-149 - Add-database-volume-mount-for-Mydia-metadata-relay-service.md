---
id: task-149
title: Add database volume mount for Mydia metadata-relay service
status: Done
assignee: []
created_date: '2025-11-15 22:47'
updated_date: '2025-11-20 03:48'
labels:
  - cloud
  - mydia
  - fix
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The metadata-relay service needs a persistent volume for its SQLite database. According to the upstream docker-compose.yml (https://github.com/getmydia/mydia/blob/master/metadata-relay/docker-compose.yml), the service requires:

- Volume mount: `/app/data` for SQLite database storage
- Environment variable: `SQLITE_DB_PATH=/app/data/metadata_relay.db`

Current deployment is missing the database volume, which may cause data loss on container restart.

This needs to be added to `modules/constellation/media.nix` in the cloudServices section for metadata-relay.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 metadata-relay service has volume mount for /app/data configured
- [x] #2 SQLITE_DB_PATH environment variable is set to /app/data/metadata_relay.db
- [x] #3 Service successfully deploys to cloud host
- [x] #4 Database persists across container restarts
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Updated modules/constellation/media.nix:
- Added volume mount: ${vars.configDir}/metadata-relay:/app/data
- Added SQLITE_DB_PATH environment variable: /app/data/metadata_relay.db

This uses configDir (defaults to /var/data on cloud host) instead of storageDir, which is appropriate for the cloud host deployment.

Deployment completed successfully. Service is running with:
- Volume mount: /var/data/metadata-relay:/app/data
- Environment: SQLITE_DB_PATH=/app/data/metadata_relay.db
- Redis connected: 127.0.0.1:6380
- Service processing requests normally
- Database directory accessible with correct permissions (user 5000)
- SQLite database will be created on first write operation

## Permission Issue Found and Fixed (2025-11-19)

After the initial deployment, the metadata-relay service was experiencing database connection errors:
```
[error] Exqlite.Connection failed to connect: ** (Exqlite.Error) database_open_failed
```

**Root Cause:** The Mydia metadata-relay container runs as the hardcoded 'relay' user (UID 1000), not honoring the PUID/PGID environment variables (5000) that were being set. The directory was created with UID 5000 ownership, causing permission denied errors when the container tried to write the database file.

**Solution:** Added a systemd preStart hook to the docker-metadata-relay service in modules/constellation/media.nix that ensures the /var/data/metadata-relay directory is owned by UID 1000:1000 before the container starts.

This fix will persist across deployments and container restarts.

## OpenSubtitles Issue Resolved (2025-11-19)

After fixing the database permissions, the service crashed with OpenSubtitles authentication errors. Initially added placeholder credentials (OPENSUBTITLES_API_KEY, OPENSUBTITLES_USERNAME, OPENSUBTITLES_PASSWORD) which failed with HTTP 403.

User confirmed that the new version of metadata-relay works without OpenSubtitles credentials. Removed all three OpenSubtitles environment variables from secrets/sops/cloud.yaml.

**Final working state:**
- Database: SQLite at /var/data/metadata-relay/metadata_relay.db (owned by UID 1000)
- Redis: Connected to 127.0.0.1:6380
- TVDB: Authenticated successfully
- OpenSubtitles: Disabled (credentials not configured)
- Service status: Running stably with health checks returning 200
- Endpoint: http://0.0.0.0:4001
<!-- SECTION:NOTES:END -->
