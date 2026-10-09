"""Pure HTML -> data for the tracker's pages. No I/O, so it is tested against fixtures.

The tracker's markup is old, regular phpBB-style HTML; each field sits in a fixed cell,
so a regex per field over one row's markup is enough and far shorter than a parser.
"""
import html
import re


def _int(pattern, text):
    m = re.search(pattern, text, re.S)
    return int(m.group(1)) if m else 0


def _text(fragment):
    return html.unescape(re.sub(r"<[^>]+>", "", fragment)).strip()


def logged_in(page):
    # The top menu's logout link only renders for a live session.
    return "{logout: 1}" in page


def needs_captcha(page):
    return "cap_sid" in page


def daily_limit(page):
    """The tracker's per-day .torrent quota if `page` is its limit-reached reply, else None."""
    if "исчерпали суточный лимит" not in page:
        return None
    m = re.search(r"текущий лимит:\s*(\d+)", page)
    return int(m.group(1)) if m else 0


def info_message(page):
    """Text of the tracker's info box (first mrg_16 div), or None; best effort."""
    m = re.search(r'<div class="mrg_16">(.*?)</div>', page, re.S)
    if not m:
        return None
    return " ".join(html.unescape(re.sub(r"<[^>]+>", " ", m.group(1))).split()) or None


def rows(page):
    """Tracker result rows in page order."""
    start = page.find('id="tor-tbl"')
    if start < 0:
        return []
    body = page[page.find("<tbody>", start):page.find("</tbody>", start)]
    out = []
    for chunk in body.split('<tr class="tCenter">')[1:]:
        link = re.search(r'class="[^"]*\btLink\b[^"]*" href="\./viewtopic\.php\?t=(\d+)">(.*?)</a>', chunk, re.S)
        if not link:
            continue
        out.append({
            "id": int(link.group(1)),
            "title": _text(link.group(2)),
            "forum": _int(r'href="tracker\.php\?f=(\d+)"', chunk),
            "size": _int(r"<u>(\d+)</u>\s*<a [^>]*\btr-dl\b", chunk),
            "seeders": _int(r'class="row4 seed[^"]*"><u>(\d+)</u>', chunk),
            "leechers": _int(r'class="row4 leech[^"]*"[^>]*><b>(\d+)</b>', chunk),
            "completed": _int(r'<td class="row4 small">(\d+)</td>', chunk),
            "added": _int(r'title="Добавлен">\s*<u>(\d+)</u>', chunk),
        })
    return out


def page_link(page, start):
    """The pager's link to the results page beginning at row `start`, if there is one."""
    m = re.search(r'href="(tracker\.php\?search_id=[^"&]+&amp;start=%d)"' % start, page)
    return html.unescape(m.group(1)) if m else None


def images(page):
    """Image URLs of the topic's first post (the release), in order, without repeats."""
    start = page.find('class="post_body"')
    if start < 0:
        return []
    ends = [i for i in (page.find('id="tor-reged"', start), page.find('class="post_body"', start + 1)) if i > 0]
    post = page[start:min(ends)] if ends else page[start:]
    out = []
    for url in re.findall(r'<var class="postImg[^"]*" title="([^"]+)"', post):
        url = html.unescape(url)
        if url.startswith(("https://", "http://")) and url not in out:
            out.append(url)
    return out
