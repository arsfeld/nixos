+++
title = "Laravel 5 and FileMaker"
date = 2015-06-30
aliases = ["/posts/laravel-5-and-filemaker/"]
description = "A few weeks ago I was searching Google for exactly the two words in the title, how to connect a Laravel 5 web application to a FileMaker database and I couldn’t find anything at all. Not really surpri"
tags = ["FileMaker", "laravel", "PHP", "#wordpress", "#Import 2023-07-26 18:26"]
+++

<p>A few weeks ago I was searching Google for exactly the two words in the title, how to connect a Laravel 5 web application to a FileMaker database and I couldn&#8217;t find anything at all. Not really surprising, since that is one of the last things you would want to do.</p>
<p>So, why we wanted to do that in the first place? Well, we have a client that has a legacy application running on FileMaker and maintaining it was becoming a huge burden, so they want to migrate to something else. The server itself to host FileMaker is expensive (let alone it has to be a Mac or Windows) and it&#8217;s almost impossible to add new features.</p>
<p>While a Laravel connector for FileMaker was not found, I did find a PHP library to connect to FileMaker called <a href="https://github.com/soliantconsulting/SimpleFM" target="_blank" rel="noopener">SimpleFM</a>. Adding a provider for it in Laravel was pretty easy (I also included the .env configuration introduced in Laravel 5 and the database.php configuration).</p>


**Code:** [View GitHub Gist](https://gist.github.com/arsfeld/3a6995d50128061ba709)



<p>There is a bunch of ways you could have implemented this, I just wanted an easy way to get a FileMaker connection.</p>
<p>I also wanted to see information about the available layouts, since I prefer to avoid logging in to FileMaker at all costs. So I wrote a command to display all layout names in a database or to display column information in a specific database:</p>


**Code:** [View GitHub Gist](https://gist.github.com/arsfeld/eed276cd33bf61b857db)



<p><strong>Please note: I&#8217;m using a Laravel 5.1 feature to describe the command as a signature, instead of the obscure and error-prone getOptions and getArguments.</strong></p>
<p>Use it like this:</p>
<pre>./artisan fm:show
</pre>
<pre>Getting layout names
• Layout1
• Layout2
...
</pre>
<p>And you get a pretty table in response of a specific layout:</p>
<pre>
./artisan fm:show REPORTS
</pre>
<pre>Getting info for REPORTS
+-------+-------+-------+
| index | recid | modid |
+-------+-------+-------+
| 0 | 77 | 0 |
+-------+-------+-------+
</pre>
<p>Take a look <a href="https://www.filemaker.com/support/product/docs/12/fms/fms12_cwp_xml_en.pdf" target="_blank" rel="noopener">at the FileMaker docs</a> for more commands and then you&#8217;re ready to do whatever you want with FileMaker inside your Laravel 5 application.</p>
<p>Happy hacking!</p>