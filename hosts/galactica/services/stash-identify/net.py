"""JSON over HTTP, shared by the Stash, OpenRouter and ThePornDB clients."""
import json
import urllib.request


def post_json(url, body, headers=None, timeout=120):
    req = urllib.request.Request(
        url, json.dumps(body).encode(),
        {"Content-Type": "application/json", **(headers or {})})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def get_json(url, headers=None, timeout=120):
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)
