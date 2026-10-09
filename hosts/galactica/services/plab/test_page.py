import unittest

import page
from store import key

TOPIC = {"id": 3313754, "title": "Studio <script>alert(1)</script> & Co", "forum": 1875,
         "size": 2254024095, "seeders": 310, "leechers": 4, "completed": 3189,
         "added": 1791117232, "images": ["https://x/cover.jpg", "https://x/shot.jpg"]}


class Render(unittest.TestCase):
    def render(self, topics, added=frozenset(), queued=frozenset(), updated=1791117232, now=1791117232 + 7200):
        return page.render({"updated": updated, "topics": topics}, set(added), set(queued), now)

    def test_card(self):
        out = self.render([TOPIC], updated=TOPIC["added"] + 2 * 86400 - 7200, now=TOPIC["added"] + 2 * 86400)
        self.assertIn('src="img/%s"' % key("https://x/cover.jpg"), out)
        self.assertIn(key("https://x/shot.jpg"), out)
        self.assertIn('data-id="3313754"', out)
        self.assertIn("2.1 GB", out)
        self.assertIn("310", out)
        self.assertIn("2026-10-04", out)  # UTC
        self.assertIn("https://pornolab.net/forum/viewtopic.php?t=3313754", out)
        self.assertIn("updated 2 h ago", out)

    def fresh(self, delta):
        return self.render([TOPIC], now=TOPIC["added"] + delta)

    def test_fresh_minutes(self):
        out = self.fresh(25 * 60)
        self.assertIn('<span class="fresh">uploaded 25 min ago</span>', out)
        self.assertNotIn("2026-10-04", out)

    def test_fresh_hours(self):
        self.assertIn('<span class="fresh">uploaded 3 h ago</span>', self.fresh(3 * 3600 + 5))
        self.assertIn('<span class="fresh">uploaded 23 h ago</span>', self.fresh(86400 - 1))

    def test_old_upload_shows_date(self):
        out = self.fresh(86400)
        self.assertIn("2026-10-04", out)
        self.assertNotIn('class="fresh"', out)

    def test_future_upload_not_negative(self):
        out = self.fresh(-600)
        self.assertIn('<span class="fresh">uploaded 0 min ago</span>', out)
        self.assertNotIn("-", out.split('class="meta"')[1].split("</div>")[0].replace("▲", "").split("·")[-1])

    def test_new_badge_hooks(self):
        out = self.render([TOPIC])
        self.assertIn("plab.seen", out)
        self.assertIn("badge new", out)
        self.assertIn('id="newcount"', out)
        self.assertIn(".card { ", out.replace("\n", " "))
        self.assertIn("position: relative", out)

    def test_title_escaped(self):
        out = self.render([TOPIC])
        self.assertNotIn("<script>alert", out)
        self.assertIn("&lt;script&gt;", out)

    def test_added_topic(self):
        out = self.render([TOPIC], added={3313754})
        self.assertIn('<button class="add" data-id="3313754" disabled>Added ✓</button>', out)

    def test_not_added_topic(self):
        out = self.render([TOPIC], added=set())
        self.assertIn('<button class="add" data-id="3313754">Add to Vault</button>', out)
        self.assertNotIn('data-id="3313754" disabled', out)

    def test_queued_topic(self):
        out = self.render([TOPIC], queued={3313754})
        self.assertIn('<button class="add queued" data-id="3313754" title="Click to remove from queue">Queued ⏳</button>', out)
        self.assertNotIn("disabled>Queued", out)
        self.assertIn("· 1 queued", out)

    def test_added_wins_over_queued(self):
        out = self.render([TOPIC], added={3313754}, queued={3313754})
        self.assertIn('<button class="add" data-id="3313754" disabled>Added ✓</button>', out)
        self.assertNotIn("Queued ⏳</button>", out)

    def test_no_queued_in_header_by_default(self):
        self.assertNotIn("queued", self.render([TOPIC]).split("<header>")[1].split("</header>")[0])

    def test_no_images(self):
        out = self.render([dict(TOPIC, images=[])])
        self.assertIn('class="thumb none"', out)

    def test_size_and_age(self):
        self.assertEqual(page.size(2254024095), "2.1 GB")
        self.assertEqual(page.size(900), "900 B")
        self.assertEqual(page.age(0, 100), "never")
        self.assertEqual(page.age(100, 100 + 600), "10 min ago")
        self.assertEqual(page.age(100, 100 + 3 * 3600), "3 h ago")
        self.assertEqual(page.age(100, 100 - 600), "0 min ago")


def tp(i, title, forum=1875, added=1791117232 - 10 * 86400):
    return dict(TOPIC, id=i, title=title, forum=forum, added=added)


class Labels(unittest.TestCase):
    def render(self, topics, **kw):
        return page.render({"updated": 1791117232, "topics": topics}, set(kw.get("added", ())),
                           set(kw.get("queued", ())), kw.get("now", 1791117232 + 7200))

    def card(self, out, i):
        return out.split('data-id="%d"' % i)[0].rsplit('<div class="card"', 1)[1]

    def test_data_attributes(self):
        out = self.render([tp(1, "[OnlyFans.com] A, B [2026, Anal, Gape, 1080p]")])
        c = self.card(out, 1)
        self.assertIn('data-tags="anal|gape"', c)
        self.assertIn('data-quality="1080p"', c)
        self.assertIn('data-studio="OnlyFans.com"', c)
        self.assertIn('data-category="Clips and siterips"', c)
        self.assertIn('data-fresh=""', c)
        self.assertIn('data-state=""', c)

    def test_attributes_escaped(self):
        out = self.render([tp(1, '[St"x.<b>] A [2026, Ta"g<i>, Foo]')])
        c = self.card(out, 1)
        self.assertIn('data-studio="St&quot;x.&lt;b&gt;"', c)
        self.assertIn('data-tags="ta&quot;g&lt;i&gt;|foo"', c)
        self.assertNotIn("<i>,", out)
        self.assertNotIn('<option value="ta"g', out)

    def test_state(self):
        out = self.render([tp(1, "a"), tp(2, "b"), tp(3, "c")], added={1}, queued={2})
        self.assertIn('data-state="added"', self.card(out, 1))
        self.assertIn('data-state="queued"', self.card(out, 2))
        self.assertIn('data-state=""', self.card(out, 3))

    def test_fresh_badge_hours_and_minutes(self):
        now = 1791117232 + 7200
        out = self.render([tp(1, "a", added=now - 7 * 3600 - 5), tp(2, "b", added=now - 5 * 60),
                           tp(3, "c", added=now - 86400)])
        self.assertIn('data-fresh="1"', self.card(out, 1))
        self.assertIn('<span class="badge fresh-badge">7h</span>', self.card(out, 1))
        self.assertIn('<span class="badge fresh-badge">5m</span>', self.card(out, 2))
        self.assertIn('class="fresh">uploaded 7 h ago', out)
        c3 = self.card(out, 3)
        self.assertNotIn("fresh-badge", c3)
        self.assertIn('data-fresh=""', c3)

    def test_fresh_badge_token_and_is_new_css(self):
        out = self.render([TOPIC])
        self.assertIn("--fresh:", out)
        self.assertIn(".card.is-new { outline: 2px solid var(--accent); }", out)
        self.assertIn("is-new", out.split("<script>")[1])


class FilterBar(unittest.TestCase):
    TOPICS = [
        tp(1, "[A.com] x [2026, Anal, Gape, 1080p]", 1875),
        tp(2, "[A.com] y [2026, Anal, Bbw, 1080p]", 1875),
        tp(3, "[B.com] z [2026, Anal, 720p]", 1670),
        tp(4, "[A.com] w [2026, Solo, 4K]", 1823),
    ]

    def render(self, topics=None):
        return page.render({"updated": 0, "topics": topics or self.TOPICS}, set(), set(), 1791117232)

    def bar(self, out):
        return out.split('<div id="filters">')[1].split('<div class="grid">')[0]

    def select(self, out, k):
        return out.split('<select data-key="%s"' % k)[1].split("</select>")[0]

    def test_toggles(self):
        bar = self.bar(self.render())
        for hook in ('data-toggle="h24">Last 24h', 'data-toggle="new">New only',
                     'data-toggle="hide">Hide added/queued'):
            self.assertIn(hook, bar)

    def test_select_options_with_counts_sorted(self):
        out = self.render()
        cat = self.select(out, "cat")
        self.assertTrue(cat.split(">", 1)[1].startswith('<option value="">All</option>'))
        self.assertLess(cat.index("Clips and siterips (2)"), cat.index("VR (1)"))
        self.assertIn('<option value="Erotic &amp; softcore">Erotic &amp; softcore (1)</option>', cat)
        q = self.select(out, "q")
        self.assertLess(q.index('1080p (2)'), q.index('720p (1)'))
        self.assertIn('2160p (1)', q)
        studio = self.select(out, "studio")
        self.assertLess(studio.index("A.com (3)"), studio.index("B.com (1)"))

    def test_empty_values_not_options(self):
        out = self.render([tp(1, "plain")])
        self.assertEqual(self.select(out, "studio").count("<option"), 1)

    def test_tag_chips_top_20(self):
        tags = ", ".join("t%02d" % i for i in range(25))
        topics = [tp(i, "[S] a [2026, %s]" % tags) for i in range(3)] + [tp(9, "[S] a [2026, t24, t23, only-once]")]
        bar = self.bar(self.render(topics))
        chips = bar.split('id="chips"')[1].split("</div>")[0]
        self.assertEqual(chips.count("data-tag="), 20)
        self.assertIn('data-tag="t24">t24<i>4</i>', chips)
        self.assertNotIn("only-once", chips)

    def test_chips_sorted_by_count(self):
        chips = self.bar(self.render()).split('id="chips"')[1].split("</div>")[0]
        self.assertLess(chips.index('data-tag="anal"'), chips.index('data-tag="gape"'))
        self.assertIn('data-tag="anal">anal<i>3</i>', chips)

    def test_datalist_has_all_tags(self):
        topics = [tp(i, "[S] a [2026, %s]" % ", ".join("t%02d" % j for j in range(30))) for i in range(2)]
        bar = self.bar(self.render(topics))
        dl = bar.split("<datalist")[1].split("</datalist>")[0]
        self.assertEqual(dl.count("<option"), 30)
        self.assertIn('list="taglist"', bar)

    def test_count_and_clear(self):
        bar = self.bar(self.render())
        self.assertIn("Showing 4 of 4", bar)
        self.assertIn('id="clear"', bar)
        self.assertIn('id="seltags"', bar)

    def test_filter_script_hooks(self):
        script = self.render().split("<script>")[1]
        for hook in ("plab.filters", "h24", "'new'", "'hide'", "replaceState", "location.hash",
                     "'tags'", "d.state"):
            self.assertIn(hook, script)
        # the NEW pass must come before the filter pass
        self.assertLess(script.index("plab.seen"), script.index("plab.filters"))

    def test_hidden_attribute_wins_over_card_display(self):
        css = self.render().split("<style>")[1].split("</style>")[0]
        self.assertIn("[hidden] { display: none !important; }", css)

    def test_new_survives_reload_hooks(self):
        script = self.render().split("<script>")[1]
        for hook in ("prev", "cur", "30 * 60 * 1000", "Array.isArray", "Object.hasOwn"):
            self.assertIn(hook, script)

    def test_sticky_and_mobile_css(self):
        out = self.render()
        self.assertIn("@media (max-width: 640px) { #filters { position: static; } }", out)
        self.assertIn("position: sticky", out)
        self.assertIn("flex-wrap: wrap", out)
        self.assertIn("overflow-x: hidden", out)


if __name__ == "__main__":
    unittest.main()
