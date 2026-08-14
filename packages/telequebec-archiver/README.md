# telequebec-archiver

Archive [Télé-Québec](https://telequebec.tv) series into a Plex-friendly folder layout.

## Usage

```console
$ telequebec-archiver <slug-or-url> [options]
```

Examples:

```console
# Whole series (all seasons/episodes)
$ telequebec-archiver on-joue-avec-biscuit-et-cassonade

# From a URL, a single season, or a single episode
$ telequebec-archiver https://telequebec.tv/contenu/passe-partout --seasons 1-3
$ telequebec-archiver passe-partout --seasons 2 --episodes 3-5
$ telequebec-archiver https://telequebec.tv/regarder/on-joue-avec-biscuit-et-cassonade/4/16

# Preview without downloading
$ telequebec-archiver passe-partout --dry-run
```

Options:

- `-o, --output` — output root (default `/mnt/storage/media/Series`)
- `--seasons` — comma/range list (e.g. `1,2` or `1-4`)
- `--episodes` — comma/range list within one season
- `--quality` — max video height (default `720`)
- `--subtitles` — download and embed fr-CA subtitles
- `--dry-run` — list episodes without downloading
- `--no-skip-existing` — re-download files already present

Files are written as:

```
<output>/<Show>/Season NN/<Show> - SNNENN - <Title>.mkv
```

Downloads are delegated to `yt-dlp` (with `ffmpeg`), both of which must be on `PATH`.

## Development

```console
$ uv sync
$ uv run telequebec-archiver --help
```
