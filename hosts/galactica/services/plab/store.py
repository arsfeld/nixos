"""plab's files under the state dir: cache.json, added.json, queued.json and img/<sha1 of url>.

`refresh` and `serve` are separate processes sharing this directory, so every write is a
temp file + rename: a reader sees the old file or the new one, never half of either.
"""
import hashlib
import json
import os
import threading
import time


def key(url):
    return hashlib.sha1(url.encode()).hexdigest()


def _write(path, data):
    # Unique per writer: two server threads may cache the same image at once.
    tmp = f"{path}.{os.getpid()}.{threading.get_ident()}.tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)


class Store:
    def __init__(self, root):
        self.root = root
        self.img = os.path.join(root, "img")
        os.makedirs(self.img, exist_ok=True)

    def _read_json(self, name, default):
        try:
            with open(os.path.join(self.root, name)) as f:
                return json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            # Missing or half-written/corrupt: treat as empty rather than crash the server.
            return default

    def cache(self):
        return self._read_json("cache.json", {"updated": 0, "topics": []})

    def save_cache(self, topics):
        data = {"updated": int(time.time()), "topics": topics}
        _write(os.path.join(self.root, "cache.json"), json.dumps(data).encode())

    def added(self):
        return set(self._read_json("added.json", []))

    def mark_added(self, topic_id):
        ids = sorted(self.added() | {topic_id})
        _write(os.path.join(self.root, "added.json"), json.dumps(ids).encode())

    def queued(self):
        return list(self._read_json("queued.json", []))

    def _save_queue(self, ids):
        _write(os.path.join(self.root, "queued.json"), json.dumps(ids).encode())

    def enqueue(self, topic_id):
        ids = self.queued()
        if topic_id not in ids and topic_id not in self.added():
            self._save_queue(ids + [topic_id])

    def dequeue(self, topic_id):
        ids = self.queued()
        if topic_id in ids:
            self._save_queue([i for i in ids if i != topic_id])

    def image_path(self, url):
        return os.path.join(self.img, key(url))

    def ensure_image(self, url, fetch):
        path = self.image_path(url)
        if not os.path.exists(path):
            _write(path, fetch(url))
        return path

    def prune_images(self, keep_urls):
        keep = {key(u) for u in keep_urls}
        for name in os.listdir(self.img):
            # In-flight temp files belong to a concurrent writer; leave them alone.
            if name in keep or name.endswith(".tmp"):
                continue
            try:
                os.remove(os.path.join(self.img, name))
            except FileNotFoundError:
                pass  # another process pruned it first
