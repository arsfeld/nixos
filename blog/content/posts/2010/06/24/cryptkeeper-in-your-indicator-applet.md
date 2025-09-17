+++
title = "Cryptkeeper in your Indicator Applet"
date = 2010-06-24
aliases = ["/posts/cryptkeeper-in-your-indicator-applet/"]
description = "I like the Indicator Applet and I like Cryptkeeper, so I decided to create an indicator for Cryptkeeper:      For anyone who doesn’t know, Cryptkeeper is a very useful application that allows you to m"
tags = ["#wordpress", "#Import 2023-07-26 18:26"]
+++

<p>I like the Indicator Applet and I like Cryptkeeper, so I decided to create an indicator for Cryptkeeper:</p>
<p><a href="__GHOST_URL__/content/images/wordpress/2010/06/screenshot2.jpg"><img decoding="async" loading="lazy" class="aligncenter size-full wp-image-76" title="Cryptkeeper in your Indicator Applet" src="__GHOST_URL__/content/images/wordpress/2010/06/screenshot2.jpg" alt="" width="607" height="48" srcset="__GHOST_URL__/content/images/wordpress/2010/06/screenshot2.jpg 607w, __GHOST_URL__/content/images/wordpress/2010/06/screenshot2-300x24.jpg 300w" sizes="(max-width: 607px) 100vw, 607px" /></a></p>
<p>For anyone who doesn&#8217;t know, <a href="http://tom.noflag.org.uk/cryptkeeper.html" target="_blank" rel="noopener">Cryptkeeper</a> is a very useful application that allows you to mount/unmount an encrypted folder with just one click. It&#8217;s one of the most useful applications running on my startup. But up until now it had a quite ugly icon:</p>
<p><a href="__GHOST_URL__/content/images/wordpress/2010/06/screenshot.jpg"><img decoding="async" loading="lazy" class="aligncenter size-full wp-image-77" title="Cryptkeeper before" src="__GHOST_URL__/content/images/wordpress/2010/06/screenshot.jpg" alt="" width="607" height="48" srcset="__GHOST_URL__/content/images/wordpress/2010/06/screenshot.jpg 607w, __GHOST_URL__/content/images/wordpress/2010/06/screenshot-300x24.jpg 300w" sizes="(max-width: 607px) 100vw, 607px" /></a></p>
<p>Can you spot the difference?</p>
<p>This is actually a plot to make people to like it and finish it. The patch adds support for showing and letting you mount/unmount folders, but it doesn&#8217;t let you delete folders or view information, as it did. Also, when adding a new folder, it doesn&#8217;t show up on the list if you don&#8217;t restart Cryptkeeper. But the patch does what I wanted it to (I rarely create or delete an encrypted folder), so I probably won&#8217;t change it further.</p>
<p>So, the patch is <a href="https://bugs.launchpad.net/ubuntu/+source/cryptkeeper/+bug/571473">here</a>. Have fun 😉</p>