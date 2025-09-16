+++
title = "DACP in Rhythmbox: Week 11"
date = 2010-08-06
description = "I just went from week 2 to week 11 in the GSoC progress in my blog 😉 Well, there is not much to tell in a blog if there is not a picture to show (and showing off the iPhone remote working with Rhythm"
tags = ["#wordpress", "#Import 2023-07-26 18:26"]
+++

<p>I just went from <a href="http://arosenfeld.wordpress.com/2010/06/07/dacp-in-rhythmbox-week-2/">week 2</a> to week 11 in the <a href="http://live.gnome.org/SummerOfCode2010/AlexandreRosenfeld_Rhythmbox">GSoC progress</a> in my blog 😉 Well, there is not much to tell in a blog if there is not a picture to show (and showing off the iPhone remote working with Rhythmbox should not be any different than iTunes if I&#8217;m doing my job correctly).</p>
<p>I realized these last weeks that I had completely mis-planned my project, because I had no idea what I was getting into. I thought DACP would be quite easy to implement and I would focus on other things (making a client library for instance). But I discovered it is a much more complex protocol then I thought, mostly because of DAAP.</p>
<p>What I discovered is that DACP is just an extension for DAAP, and being an Apple protocol, it&#8217;s closed and has been reverse-engineered and re-implemented several times in the open source world. The problem is that DACP uses several features in DAAP that were not implemented in libdmapsharing, simply because there is no real standard on DAAP. It took some time for me to learn DAAP enough to find out what was missing in libdmapsharing for DACP to work.</p>
<p>So I spent most of the time fixing, tweaking and implementing stuff on DAAP in libdmapsharing. Which was pretty cool, I improved a lot of my C skills, learned GObject (and quite frankly, liked it a lot) and learned a lot about DAAP and libdmapharing.</p>
<p>By the way, thanks for all the people who have <a href="http://dacp.jsharkey.org/">reverse-engineered DACP</a> and the <a href="http://jsharkey.org/blog/2009/06/21/itunes-dacp-pairing-hash-is-broken/">pairing process</a>, you have greatly simplified my life. It&#8217;s truly great to work in the open-source world.</p>