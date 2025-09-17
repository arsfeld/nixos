+++
title = "Laravel and Azure SQL Server"
date = 2015-07-14
aliases = ["/posts/laravel-and-azure-sql-server/"]
description = "From the same project as my last blog post, we had to connect a Laravel 5 web application to a SQL Server instance running on Azure. It took me awhile to get everything working well, so I want to shar"
tags = ["Azure", "laravel", "PHP", "SQLServer", "#wordpress", "#Import 2023-07-26 18:26"]
+++

<p>From the same project as my <a href="https://arosenfeld.wordpress.com/2015/06/30/laravel-5-and-filemaker/">last blog post</a>, we had to connect a Laravel 5 web application to a SQL Server instance running on Azure. It took me awhile to get everything working well, so I want to share a few tips for anyone looking for something like that.</p>
<p>A quick Google search gives lots of good resources and once you find out the SQL Server connector in Ubuntu / Linux is actually called FreeTDS or Sybase (btw, Wikipedia has <a href="https://en.wikipedia.org/wiki/Sybase">a nice article</a> about why this name), you&#8217;re good to go with a few <strong>apt-get </strong>commands if you&#8217;re on Ubuntu:</p>
<pre>sudo apt-get install freetds-common freetds-bin unixodbc php5-sybase
</pre>
<p>Great, but then you get this error:</p>
<pre>SQLSTATE[01002] Adaptive Server connection failed (severity 9)
</pre>
<p>Oops! This happens because we&#8217;re trying to connect to an Azure server, so you can actually ignore this if you&#8217;re not getting this error.</p>
<p>Somewhere in the internet you discover you have to <a href="http://martinrichards.tumblr.com/post/28488121620/connecting-to-sql-azure-using-freetds">change the TDS</a> protocol version to connect to Azure. Cool! You also discover you can do that in a configuration file. So, open up <code>/etc/freetds/freetds.conf</code> and change a few lines around:</p>
<pre>[global]
        # TDS protocol version
        ;tds version = 4.2
        tds version = 8.0
</pre>
<p>Everything is great and life can move on!</p>
<p>Or, so you thought! Once you started handling dates in your models, all hell break loose and you start to get Carbon and Datetime issues everywhere. Don&#8217;t worry, the fix is <a href="http://stackoverflow.com/questions/11824323/freetds-strange-date-time-format">simple again</a>, now go to <code>/etc/freetds/locales.conf</code> and make it look like:</p>
<pre>[default]
date format = %Y-%m-%d %I:%M:%S.%z</pre>
<p>Now you can actually start working on something productive again!</p>