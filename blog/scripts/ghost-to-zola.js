#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

// Configuration
const GHOST_URL = 'https://blog.arsfeld.dev';
const GHOST_ADMIN_API_KEY = process.env.GHOST_ADMIN_API_KEY; // Format: id:secret
const OUTPUT_DIR = path.join(__dirname, '..', 'content', 'posts');

// Simple HTML to Markdown converter
function htmlToMarkdown(html) {
  return html
    .replace(/<h1[^>]*>(.*?)<\/h1>/g, '# $1\n\n')
    .replace(/<h2[^>]*>(.*?)<\/h2>/g, '## $1\n\n')
    .replace(/<h3[^>]*>(.*?)<\/h3>/g, '### $1\n\n')
    .replace(/<h4[^>]*>(.*?)<\/h4>/g, '#### $1\n\n')
    .replace(/<h5[^>]*>(.*?)<\/h5>/g, '##### $1\n\n')
    .replace(/<h6[^>]*>(.*?)<\/h6>/g, '###### $1\n\n')
    .replace(/<strong[^>]*>(.*?)<\/strong>/g, '**$1**')
    .replace(/<b[^>]*>(.*?)<\/b>/g, '**$1**')
    .replace(/<em[^>]*>(.*?)<\/em>/g, '*$1*')
    .replace(/<i[^>]*>(.*?)<\/i>/g, '*$1*')
    .replace(/<pre[^>]*><code[^>]*>(.*?)<\/code><\/pre>/gs, '```\n$1\n```\n\n')
    .replace(/<code[^>]*>(.*?)<\/code>/g, '`$1`')
    .replace(/<a[^>]*href="([^"]*)"[^>]*>(.*?)<\/a>/g, '[$2]($1)')
    .replace(/<img[^>]*src="([^"]*)"[^>]*alt="([^"]*)"[^>]*\/?>/g, '![$2]($1)')
    .replace(/<img[^>]*alt="([^"]*)"[^>]*src="([^"]*)"[^>]*\/?>/g, '![$1]($2)')
    .replace(/<img[^>]*src="([^"]*)"[^>]*\/?>/g, '![]($1)')
    .replace(/<ul[^>]*>/g, '\n')
    .replace(/<\/ul>/g, '\n')
    .replace(/<ol[^>]*>/g, '\n')
    .replace(/<\/ol>/g, '\n')
    .replace(/<li[^>]*>(.*?)<\/li>/g, '- $1\n')
    .replace(/<blockquote[^>]*>(.*?)<\/blockquote>/gs, '> $1\n\n')
    .replace(/<br\s*\/?>/g, '\n')
    .replace(/<p[^>]*>(.*?)<\/p>/gs, '$1\n\n')
    .replace(/<div[^>]*>(.*?)<\/div>/gs, '$1\n')
    .replace(/<[^>]*>/g, '') // Remove any remaining HTML tags
    .replace(/&quot;/g, '"')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&nbsp;/g, ' ')
    .replace(/\n\n\n+/g, '\n\n') // Remove excessive newlines
    .trim();
}

// Generate JWT token for Ghost Admin API
function generateToken(apiKey) {
  const jwt = require('jsonwebtoken');
  const [id, secret] = apiKey.split(':');
  return jwt.sign({}, Buffer.from(secret, 'hex'), {
    keyid: id,
    algorithm: 'HS256',
    expiresIn: '5m',
    audience: '/admin/'
  });
}

// Create URL-friendly slug
function createSlug(title) {
  return title
    .toLowerCase()
    .replace(/[^a-z0-9\s-]/g, '') // Remove special characters
    .replace(/\s+/g, '-') // Replace spaces with hyphens
    .replace(/-+/g, '-') // Remove duplicate hyphens
    .trim('-'); // Remove leading/trailing hyphens
}

// Fetch posts from Ghost
async function fetchPosts() {
  const token = generateToken(GHOST_ADMIN_API_KEY);
  
  try {
    const response = await fetch(`${GHOST_URL}/ghost/api/admin/posts/?limit=all&include=tags`, {
      headers: {
        'Authorization': `Ghost ${token}`
      }
    });

    if (response.ok) {
      const result = await response.json();
      return result.posts;
    } else {
      console.error(`Failed to fetch posts: ${response.statusText}`);
      return [];
    }
  } catch (error) {
    console.error(`Error fetching posts: ${error.message}`);
    return [];
  }
}

// Convert Ghost post to Zola format
function convertPost(post) {
  const publishedDate = post.published_at ? new Date(post.published_at).toISOString().split('T')[0] : new Date().toISOString().split('T')[0];
  const tags = post.tags ? post.tags.map(tag => tag.name) : [];
  
  const frontmatter = `+++
title = "${post.title.replace(/"/g, '\\"')}"
date = ${publishedDate}
description = "${(post.excerpt || post.meta_description || '').replace(/"/g, '\\"')}"
tags = [${tags.map(tag => `"${tag}"`).join(', ')}]
+++

`;

  const content = htmlToMarkdown(post.html || '');
  
  return frontmatter + content;
}

// Main function
async function main() {
  if (!GHOST_ADMIN_API_KEY) {
    console.error('GHOST_ADMIN_API_KEY environment variable is required');
    console.error('Get it from Ghost Admin -> Settings -> Integrations');
    process.exit(1);
  }

  console.log('Fetching posts from Ghost...');
  const posts = await fetchPosts();
  
  if (posts.length === 0) {
    console.log('No posts found or failed to fetch posts');
    return;
  }

  console.log(`Found ${posts.length} posts`);

  // Ensure output directory exists
  if (!fs.existsSync(OUTPUT_DIR)) {
    fs.mkdirSync(OUTPUT_DIR, { recursive: true });
  }

  for (const post of posts) {
    const slug = createSlug(post.title);
    const filename = `${slug}.md`;
    const filepath = path.join(OUTPUT_DIR, filename);
    
    const markdownContent = convertPost(post);
    
    fs.writeFileSync(filepath, markdownContent);
    console.log(`Exported: ${post.title} -> ${filename}`);
  }

  console.log(`Export complete! Files saved to ${OUTPUT_DIR}`);
}

if (require.main === module) {
  main().catch(console.error);
}