#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const jwt = require('jsonwebtoken');

// Configuration
const GHOST_URL = 'https://blog.arsfeld.dev';
const GHOST_ADMIN_API_KEY = process.env.GHOST_ADMIN_API_KEY; // Format: id:secret
const POSTS_DIR = __dirname;

// Convert markdown to HTML (basic conversion)
function markdownToHtml(markdown) {
  return markdown
    .replace(/^# (.*$)/gim, '<h1>$1</h1>')
    .replace(/^## (.*$)/gim, '<h2>$1</h2>')
    .replace(/^### (.*$)/gim, '<h3>$1</h3>')
    .replace(/\*\*(.*?)\*\*/g, '<strong>$1</strong>')
    .replace(/\*(.*?)\*/g, '<em>$1</em>')
    .replace(/```([\s\S]*?)```/g, '<pre><code>$1</code></pre>')
    .replace(/`(.*?)`/g, '<code>$1</code>')
    .replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2">$1</a>')
    .replace(/!\[([^\]]*)\]\(([^)]+)\)/g, '<img alt="$1" src="$2">')
    .replace(/\n\n/g, '</p><p>')
    .replace(/\n/g, '<br>')
    .replace(/^/, '<p>')
    .replace(/$/, '</p>');
}

// Generate JWT token for Ghost Admin API
function generateToken(apiKey) {
  const [id, secret] = apiKey.split(':');
  return jwt.sign({}, Buffer.from(secret, 'hex'), {
    keyid: id,
    algorithm: 'HS256',
    expiresIn: '5m',
    audience: '/admin/'
  });
}

// Upload image to Ghost
async function uploadImage(imagePath) {
  if (!fs.existsSync(imagePath)) {
    console.log(`Image not found: ${imagePath}`);
    return null;
  }

  const FormData = require('form-data');
  const form = new FormData();
  form.append('file', fs.createReadStream(imagePath));
  form.append('purpose', 'image');

  const token = generateToken(GHOST_ADMIN_API_KEY);
  
  try {
    const response = await fetch(`${GHOST_URL}/ghost/api/admin/images/upload/`, {
      method: 'POST',
      headers: {
        'Authorization': `Ghost ${token}`,
        ...form.getHeaders()
      },
      body: form
    });

    if (response.ok) {
      const result = await response.json();
      return result.images[0].url;
    } else {
      console.error(`Failed to upload image: ${response.statusText}`);
      return null;
    }
  } catch (error) {
    console.error(`Error uploading image: ${error.message}`);
    return null;
  }
}

// Process images in markdown content
async function processImages(content, postDir) {
  const imageRegex = /!\[([^\]]*)\]\(([^)]+)\)/g;
  let processedContent = content;
  const matches = [...content.matchAll(imageRegex)];

  for (const match of matches) {
    const [fullMatch, altText, imagePath] = match;
    
    // Skip if already an absolute URL
    if (imagePath.startsWith('http')) continue;
    
    const localImagePath = path.resolve(postDir, imagePath);
    const uploadedUrl = await uploadImage(localImagePath);
    
    if (uploadedUrl) {
      processedContent = processedContent.replace(fullMatch, `![${altText}](${uploadedUrl})`);
      console.log(`Uploaded image: ${imagePath} -> ${uploadedUrl}`);
    }
  }

  return processedContent;
}

// Publish post to Ghost
async function publishPost(title, content, tags = []) {
  const token = generateToken(GHOST_ADMIN_API_KEY);
  
  const post = {
    posts: [{
      title: title,
      html: markdownToHtml(content),
      status: 'published',
      tags: tags.map(tag => ({ name: tag }))
    }]
  };

  try {
    const response = await fetch(`${GHOST_URL}/ghost/api/admin/posts/`, {
      method: 'POST',
      headers: {
        'Authorization': `Ghost ${token}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(post)
    });

    if (response.ok) {
      const result = await response.json();
      console.log(`Published: ${title}`);
      console.log(`URL: ${result.posts[0].url}`);
      return result.posts[0];
    } else {
      const error = await response.text();
      console.error(`Failed to publish ${title}: ${error}`);
      return null;
    }
  } catch (error) {
    console.error(`Error publishing ${title}: ${error.message}`);
    return null;
  }
}

// Parse frontmatter from markdown
function parseFrontmatter(content) {
  const frontmatterRegex = /^---\n([\s\S]*?)\n---\n([\s\S]*)$/;
  const match = content.match(frontmatterRegex);
  
  if (!match) {
    return { metadata: {}, content };
  }

  const [, frontmatter, bodyContent] = match;
  const metadata = {};
  
  frontmatter.split('\n').forEach(line => {
    const [key, ...valueParts] = line.split(':');
    if (key && valueParts.length) {
      const value = valueParts.join(':').trim();
      metadata[key.trim()] = value.replace(/^["']|["']$/g, '');
    }
  });

  return { metadata, content: bodyContent };
}

// Main function
async function main() {
  if (!GHOST_ADMIN_API_KEY) {
    console.error('GHOST_ADMIN_API_KEY environment variable is required');
    process.exit(1);
  }

  const files = fs.readdirSync(POSTS_DIR)
    .filter(file => file.endsWith('.md') && !file.startsWith('image-prompts') && !file.startsWith('outline'))
    .sort();

  console.log(`Found ${files.length} markdown files`);

  for (const file of files) {
    const filePath = path.join(POSTS_DIR, file);
    const fileContent = fs.readFileSync(filePath, 'utf8');
    
    const { metadata, content } = parseFrontmatter(fileContent);
    
    // Extract title from filename or frontmatter
    const title = metadata.title || 
                 content.match(/^# (.+)$/m)?.[1] || 
                 path.basename(file, '.md').replace(/^\d+-/, '').replace(/-/g, ' ');
    
    // Process images
    const processedContent = await processImages(content, POSTS_DIR);
    
    // Extract tags
    const tags = metadata.tags ? metadata.tags.split(',').map(t => t.trim()) : ['NixOS', 'Self-Hosting'];
    
    console.log(`Publishing: ${title}`);
    await publishPost(title, processedContent, tags);
  }

  console.log('Publishing complete!');
}

if (require.main === module) {
  main().catch(console.error);
}