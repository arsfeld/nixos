+++
title = "Analyzing HTTP packets with Wireshark and Python"
date = 2010-11-21
aliases = ["/posts/analyzing-http-packets-with-wireshark-and-python/"]
description = "I’m doing some reverse-engineering stuff and it has been quite fun so far (hopefully I’ll blog more about why I’m doing this in the future). I needed to dump some HTTP traffic and analyse the data. Of"
tags = ["#wordpress", "#Import 2023-07-26 18:26"]
+++

<p>I&#8217;m doing some reverse-engineering stuff and it has been quite fun so far (hopefully I&#8217;ll blog more about why I&#8217;m doing this in the future). I needed to dump some HTTP traffic and analyse the data. Of course, Wireshark comes straight to mind for something like this and it is indeed really useful. It took me some time to understand the Wireshark interface and I still think it&#8217;s hiding some great functionality from me. But anyway, I was able to set the filters I wanted and it was showing me exactly the data I wanted. But I still had to right-click the data I wanted and save it to disk, which was not ideal.</p>
<p>Then I thought, if people were smart enough to build such a powerful tool, they probably created a command-line interface as well, probably with scripting. Indeed they did! The command-line interface is called Tshark and the scripting is done in Lua. But I don&#8217;t know Lua and it would take too much time to learn it for this task. So I started to look a way to dump everything and then write a small script in Python to extract the data I really want. Took some time but the solution was much simpler then I thought (by the way, there are probably other solutions for this, but my Google skills were not good enough to find anything obvious).</p>
<p>First you run Tshark to dump any HTTP traffic to a XML file (I usually hate XML, but this time it was useful). This is what I used:</p>
<pre>sudo tshark -i wlan0 "host 192.168.1.100 and port 45000" -d tcp.port==45000,http -T pdml &gt; dump.xml</pre>
<p>Of course, it all depends on what you want to dump. You should read the &#8220;man pcap-filter&#8221; to get the capture filter right and it is really useful (crucial sometimes) to only get the traffic you want. And I wanted to treat traffic in port 45000 as HTTP, so I think that is what the -d switch does 😉 The most important thing it &#8220;-T pdml&#8221;, which tells tshark to dump in this XML format.</p>
<p>Next thing is to analyze in Python, which was much easier than I thought. I was only worried about the data field in the HTTP packets, but if you take a look in the dumped file, you&#8217;ll see you have information about all kind of things. My script turned out to be this:</p>
<pre>from lxml import etree
import binascii
tree = etree.parse('dump.xml')
data = [binascii.unhexlify(e.get("value")) for e in tree.xpath('/pdml/packet/proto[@name="http"]/field[@name="data"]')]</pre>
<p>I used lxml because I found it has great support for XPath, which is quite useful here. Also, the HTTP data is stored as a hex string, which you can easily convert with unhexlify. So, in the end I was able to automate an annoying process with just a few lines of code. And if I need anything else, it&#8217;s quite easy to expand the script. I&#8217;m quite happy with the results!</p>
<p><strong>Update: </strong>Someone pointed out in the comments about Scapy (http://www.secdev.org/projects/scapy/), which by reading it&#8217;s documentation seems awesome!</p>