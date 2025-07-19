{ lib
, stdenv
, fetchurl
, nodejs
}:

stdenv.mkDerivation rec {
  pname = "signoz-frontend";
  version = "0.90.1";

  src = fetchurl {
    url = "https://github.com/SigNoz/signoz/releases/download/v${version}/signoz_linux_amd64.tar.gz";
    sha256 = "13hqrcq0zllpfr8zmv20ismx9476m3xv8g2b9s2hw57jy3p41d2v";
  };

  installPhase = ''
    runHook preInstall
    
    # Create output directory
    mkdir -p $out/share/signoz-frontend
    
    # Extract only the web directory from the tarball
    tar -xzf $src --strip-components=2 -C $out/share/signoz-frontend signoz_linux_amd64/web
    
    # Create static server
    mkdir -p $out/bin
    cat > $out/bin/signoz-frontend << 'EOF'
    #!${nodejs}/bin/node
    const http = require('http');
    const fs = require('fs');
    const path = require('path');
    const url = require('url');
    
    const PORT = process.env.PORT || 3301;
    const ROOT_DIR = '${placeholder "out"}/share/signoz-frontend';
    
    const MIME_TYPES = {
      '.html': 'text/html; charset=utf-8',
      '.js': 'application/javascript; charset=utf-8',
      '.css': 'text/css; charset=utf-8',
      '.json': 'application/json; charset=utf-8',
      '.png': 'image/png',
      '.jpg': 'image/jpeg',
      '.jpeg': 'image/jpeg',
      '.gif': 'image/gif',
      '.svg': 'image/svg+xml; charset=utf-8',
      '.woff': 'font/woff',
      '.woff2': 'font/woff2',
      '.ttf': 'font/ttf',
      '.eot': 'application/vnd.ms-fontobject',
      '.ico': 'image/x-icon',
      '.webp': 'image/webp',
      '.map': 'application/json',
      '.gz': 'application/gzip'
    };
    
    console.log('Starting SigNoz Frontend Server');
    console.log('Serving from: ' + ROOT_DIR);
    console.log('Listening on: http://0.0.0.0:' + PORT);
    
    const server = http.createServer((req, res) => {
      let pathname = decodeURIComponent(url.parse(req.url).pathname);
      
      // Security check
      if (pathname.includes('..')) {
        res.writeHead(403);
        res.end('Forbidden');
        return;
      }
      
      // Handle root path
      if (pathname === '/') {
        pathname = '/index.html';
      }
      
      let filePath = path.join(ROOT_DIR, pathname);
      
      // Check if gzipped version exists and client accepts gzip
      const acceptsGzip = req.headers['accept-encoding'] && req.headers['accept-encoding'].includes('gzip');
      const gzPath = filePath + '.gz';
      
      if (acceptsGzip && fs.existsSync(gzPath)) {
        filePath = gzPath;
        var isGzipped = true;
      }
      
      const ext = path.extname(filePath.replace('.gz', ''')).toLowerCase();
      
      fs.readFile(filePath, (err, data) => {
        if (err) {
          // SPA fallback - serve index.html for client-side routing
          if (!ext || ext === '.html') {
            const indexPath = path.join(ROOT_DIR, 'index.html');
            const indexGzPath = indexPath + '.gz';
            
            if (acceptsGzip && fs.existsSync(indexGzPath)) {
              fs.readFile(indexGzPath, (err2, indexData) => {
                if (err2) {
                  res.writeHead(404);
                  res.end('Not Found');
                } else {
                  res.writeHead(200, {
                    'Content-Type': 'text/html; charset=utf-8',
                    'Content-Encoding': 'gzip',
                    'Cache-Control': 'no-cache'
                  });
                  res.end(indexData);
                }
              });
            } else {
              fs.readFile(indexPath, (err2, indexData) => {
                if (err2) {
                  res.writeHead(404);
                  res.end('Not Found');
                } else {
                  res.writeHead(200, {
                    'Content-Type': 'text/html; charset=utf-8',
                    'Cache-Control': 'no-cache'
                  });
                  res.end(indexData);
                }
              });
            }
          } else {
            res.writeHead(404);
            res.end('Not Found');
          }
        } else {
          const contentType = MIME_TYPES[ext] || 'application/octet-stream';
          const headers = {
            'Content-Type': contentType,
            'X-Content-Type-Options': 'nosniff'
          };
          
          if (isGzipped) {
            headers['Content-Encoding'] = 'gzip';
          }
          
          // Cache static assets
          if (ext !== '.html' && ext !== '.json') {
            headers['Cache-Control'] = 'public, max-age=31536000';
          } else {
            headers['Cache-Control'] = 'no-cache';
          }
          
          res.writeHead(200, headers);
          res.end(data);
        }
      });
    });
    
    server.listen(PORT, '0.0.0.0');
    
    process.on('SIGTERM', () => {
      server.close(() => process.exit(0));
    });
    EOF
    
    chmod +x $out/bin/signoz-frontend
    
    runHook postInstall
  '';

  meta = with lib; {
    description = "SigNoz Frontend - Observability platform UI";
    homepage = "https://signoz.io";
    license = licenses.asl20;
    platforms = platforms.linux;
    mainProgram = "signoz-frontend";
  };
}