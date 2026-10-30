"""Tags, quality, studio and category read from a release title. Pure."""
import re

from forums import category

_GROUP = re.compile(r"\[([^\[\]]*)\]")
_DATE = re.compile(r"\d{4}(\s*г\.?)?|\d{1,2}[./-]\d{1,2}[./-]\d{4}|\d{4}[./-]\d{1,2}[./-]\d{1,2}")
_RES = re.compile(r"\d{3,4}p")
_UHD = ("4k", "uhd")


def _quality(token):
    if _RES.fullmatch(token):
        return token
    return "2160p" if token in _UHD else None


# The rip, not the content: never a tag.
_NOISE = {"siterip", "webrip", "web-dl", "camrip", "dvdrip", "hd", "fullhd"}


def labels(title, forum):
    """The title's parts: studio, the release's own name, tags and quality, plus the forum's category."""
    tags, quality, site = [], None, None
    title = title.strip()
    # The leading bracket is the studio, not a tag list, even if it holds a comma.
    groups = [m for m in _GROUP.finditer(title) if "," in m.group(1) and m.start() != 0]
    # A performer list has commas too; the tag list is the one dated or carrying a quality.
    dated = [m for m in groups if any(_DATE.fullmatch(t) or _quality(t) for t in
                                      (x.strip().lower() for x in m.group(1).split(",")))]
    tag_group = (dated or groups or [None])[-1]
    for raw in tag_group.group(1).split(",") if tag_group else ():
        token = raw.strip()
        low = token.lower()
        if not low or _DATE.fullmatch(low) or low in _NOISE:
            continue
        q = _quality(low)
        if q:
            quality = quality or q
        elif "." in low:  # a site named among the tags, as the Russian titles do
            site = site or token
        elif low not in tags:
            tags.append(low)
    studio, name = site, title
    if tag_group:
        name = title[:tag_group.start()] + title[tag_group.end():]
    if title.startswith("["):
        m = _GROUP.match(title)
        first = m and m.group(1).split(" / ")[0].strip()
        if first and "." in first:
            studio = first
            name = name[m.end():]
    return {"tags": tags, "quality": quality, "studio": studio, "category": category(forum),
            "name": re.sub(r"\s+", " ", name).strip() or title}


def _squash(s):
    return re.sub(r"[\W_]+", "", s.lower())


def match_term(term, title):
    """True if `title` contains the search `term`, ignoring case, spaces and punctuation."""
    t = _squash(term)
    return bool(t) and t in _squash(title)


def term_label(term):
    """A search term as a badge: quotes dropped, an all-lowercase term capitalized."""
    t = term.strip().strip("\"'")
    return t.title() if t == t.lower() else t
