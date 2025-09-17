+++
title = "Conduit's improvements"
date = 2009-05-25
aliases = ["/posts/conduits-improvements/"]
description = "As GSoC is officially starting yesterday and I made a promess to finish what I begun almost six months ago (sorry about taking so long), last week I commited the last parts of my branch. So, in the en"
tags = ["#wordpress", "#Import 2023-07-26 18:26"]
+++

<p>As GSoC is officially starting yesterday and I made a promess to finish what I begun almost six months ago (sorry about taking so long), last week I commited the last parts of my branch. So, in the end I rewrote the configuration system of Conduit, based on a previous limited implementation that I met when working at Summer of Code 2008. If anyone wants to know if Summer of Code works, it does. I would never knew so much about Conduit had I never entered Summer of Code last year.</p>
<p>Why is the configuration system so important? Well, every dataprovider needs to be configured. What we do now, is that we open a configuration dialog for the user, with the standard configuration widgets: text entries, drop-boxes, item-lists, etc, and, of course, an OK and Cancel button. The problem was that every dataprovider had its own Gtk and Glade code, meaning a lot of duplicate code and usually confusing interfaces, not HIG-compliant at all. On top of that, every dataprovider showed their own configuration dialog, so we couldnt do anything else then displaying the dialog. Fixing all of this meant fixing each one of them.</p>
<p>I started with the idea that in order to be more useful to outside applications, we had to be more flexible and we had to fix our problems once and for all in all configuration dialogs. I knew I would have to change every dataprovider we ship, so I wanted to do it only once. In the end I created a wrapper to Gtk, letting dataproviders only deal with what matter to them. Because we have a limited set of widgets, we can have a much more useful API then dealing with Gtk directly. We also get some benefits:</p>
<ul>
<li>Fixing code in one place fixes it for all dataproviders.</li>
<li>Being HIG compliant is much easier.</li>
<li>We could change from Gtk to something else in the future much more quickly.</li>
<li>We can handle configuration dialogs on clients in a much better way (think about embedding an iPod sync configuration into Rhythmbox).</li>
<li>We can do something else then dialogs for configuration. Think about a sidebar, a la Glade.</li>
</ul>
<p>It was explicitely designed for the last two points, because my first work at Conduit was the iPod module and having the same iTunes experience of syncing it was one of the main goals.</p>
<p>So, I wished to show a screenshot of how it looked before, but it seems we fixed so much of it lately (or we screwed up so much before) I can&#8217;t run older version. Anyway, here is a screenshot of the new code:</p>
<figure id="attachment_24" aria-describedby="caption-attachment-24" style="width: 361px" class="wp-caption aligncenter"><img decoding="async" loading="lazy" class="size-full wp-image-24" title="Conduit Picasa Screenshot" src="__GHOST_URL__/content/images/wordpress/2009/05/screenshot21.png" alt="Picasa Screenshot" width="361" height="370" srcset="__GHOST_URL__/content/images/wordpress/2009/05/screenshot21.png 361w, __GHOST_URL__/content/images/wordpress/2009/05/screenshot21-293x300.png 293w" sizes="(max-width: 361px) 100vw, 361px" /><figcaption id="caption-attachment-24" class="wp-caption-text">Picasa Screenshot</figcaption></figure>
<p>Of course, we changed a lot of code with the last commits and not without bugs. Our UI is still quite bad, but hopefully we can improve it soon.</p>
<p>I should start thinking about this year&#8217;s Summer of Code now. Hopefully we will have something really good at the end of the summer (my winter actually).</p>