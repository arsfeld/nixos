+++
title = "glib-mkenums"
date = 2010-08-12
aliases = ["/posts/glib-mkenums/"]
description = "I’m posting this here both to help someone else looking for this and to check if I got everything right.   I needed to use enums in a GObject property. So I needed a enum type for my property param sp"
tags = ["#wordpress", "#Import 2023-07-26 18:26"]
+++

<p>I&#8217;m posting this here both to help someone else looking for this and to check if I got everything right.</p>
<p>I needed to use enums in a GObject property. So I needed a <a href="http://library.gnome.org/devel/gobject/unstable/gobject-Enumeration-and-Flag-Types.html">enum type</a> for my property <a href="http://library.gnome.org/devel/gobject/unstable/gobject-Standard-Parameter-and-Value-Types.html#g-param-spec-enum">param spec</a>. I thought I could hard-code it somehow, but after some long time pondering (actually knocking my head into the wall) I decided to integrate <a href="http://library.gnome.org/devel/gobject/unstable/glib-mkenums.html">glib-mkenums</a> into autoconf so that it could generate the types for me automatically when running make from my C sources. Unfortunately for me, Google wasn&#8217;t being friendly when searching for information on glib-mkenums.</p>
<p>I found somewhere, some program that used glib-mkenums in a simple way (sorry, I forgot where I fount it), close to what I had in mind, so I decided to adapt it to my needs. What I had to do was to add two more files, automatically generated (in this case named dmap-enums.c and dmap-enums.h) adding <a href="http://gitorious.org/arosenfeld-gsoc-2010/libdmapsharing/blobs/c7c495219221e6d90dc581822262c99563894011/libdmapsharing/Makefile.am#line103">some commands</a> to Makefile.am (linked to Gitorious because WordPress removes all formatting). Hopefully that is the right way to do it, at least it is working for me.</p>