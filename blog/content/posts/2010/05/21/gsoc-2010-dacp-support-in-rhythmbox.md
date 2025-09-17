+++
title = "GSoC 2010: DACP Support in Rhythmbox"
date = 2010-05-21
aliases = ["/posts/gsoc-2010-dacp-support-in-rhythmbox/"]
description = "Community bonding is almost over so I thought I could share some details about my Google Summer of Code project.   As the title says, I will implement DACP support for Rhythmbox. You probably never he"
tags = ["#wordpress", "#Import 2023-07-26 18:26"]
+++

<p>Community bonding is almost over so I thought I could share some details about my Google Summer of Code project.</p>
<p>As the title says, I will implement DACP support for Rhythmbox. You probably never heard of DACP but you&#8217;ve probably seen it in action. It&#8217;s the protocol that is used by the Remote application in iPhone and iPod Touch.</p><figure class="kg-card kg-image-card"><img src="__GHOST_URL__/content/images/2023/07/apple-iphone-remote.jpg" class="kg-image" alt loading="lazy" width="555" height="350"></figure><p>I&#8217;ll be implementing the server side in Rhythmbox, so you&#8217;ll be able to control Rhythmbox with your iPhone, iPod Touch or even your <a href="http://dacp.jsharkey.org/" target="_blank" rel="noopener">Android</a>.</p>
<p>I&#8217;ll actually be implementing this inside <a href="http://www.flyn.org/projects/libdmapsharing/" target="_blank" rel="noopener">libdmapsharing</a>, a <a href="http://en.wikipedia.org/wiki/Digital_Audio_Access_Protocol" target="_blank" rel="noopener">DMAP (DAAP &amp; DPAP)</a> library that was once extracted from Rhythmbox sources, improved and will be integrated again into Rhythmbox as a library, once my <a href="https://bugzilla.gnome.org/show_bug.cgi?id=566852" target="_blank" rel="noopener">mentor&#8217;s patch</a> is accepted. So hopefully, more applications will be able to support DACP, DAAP and DPAP by using libdmapsharing.</p>