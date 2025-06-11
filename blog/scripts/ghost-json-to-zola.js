#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

// Configuration
const GHOST_JSON_FILE = path.join(__dirname, '..', 'alexandre-rosenfeld.ghost.2025-06-11-22-08-51.json');
const OUTPUT_DIR = path.join(__dirname, '..', 'content', 'posts');

// Keep HTML as-is since HTML is valid Markdown
function htmlToMarkdown(html) {
  if (!html) return '';
  
  // Only do minimal processing to handle Ghost-specific elements
  return html
    // Remove Ghost comment cards
    .replace(/<!--kg-card-begin: html-->/g, '')
    .replace(/<!--kg-card-end: html-->/g, '')
    
    // Handle GitHub Gist embeds - convert to links since scripts won't work in static site
    .replace(/<script[^>]*src=["']https:\/\/gist\.github\.com\/([^\/]+)\/([^"']+)\.js["'][^>]*><\/script>/gis, 
      (match, username, gistId) => {
        return `\n**Code:** [View GitHub Gist](https://gist.github.com/${username}/${gistId})\n\n`;
      })
    .trim();
}

// Create URL-friendly slug
function createSlug(title) {
  return title
    .toLowerCase()
    .replace(/[^a-z0-9\s-]/g, '') // Remove special characters
    .replace(/\s+/g, '-') // Replace spaces with hyphens
    .replace(/-+/g, '-') // Remove duplicate hyphens
    .replace(/^-+|-+$/g, '') // Remove leading/trailing hyphens
    .substring(0, 100); // Limit length
}

// Convert Ghost post to Zola format
function convertPost(post) {
  const publishedDate = post.published_at ? new Date(post.published_at).toISOString().split('T')[0] : new Date().toISOString().split('T')[0];
  
  // Extract tags from post_tag relationships (will be handled in main function)
  const tags = post.tags || [];
  
  // Clean and properly escape description
  const description = (post.custom_excerpt || post.plaintext || post.title || '')
    .replace(/\n/g, ' ')  // Replace newlines with spaces
    .replace(/\r/g, '')   // Remove carriage returns
    .replace(/"/g, '\\"') // Escape quotes
    .trim()
    .substring(0, 200);   // Limit length
  
  const frontmatter = `+++
title = "${post.title.replace(/"/g, '\\"')}"
date = ${publishedDate}
description = "${description}"
tags = [${tags.map(tag => `"${tag.name.replace(/"/g, '\\"')}"`).join(', ')}]
+++

`;

  // Convert HTML content to markdown
  const content = htmlToMarkdown(post.html || '');
  
  return frontmatter + content;
}

// Main function
async function main() {
  console.log('Reading Ghost JSON export...');
  
  if (!fs.existsSync(GHOST_JSON_FILE)) {
    console.error(`Ghost JSON file not found: ${GHOST_JSON_FILE}`);
    process.exit(1);
  }
  
  const jsonData = JSON.parse(fs.readFileSync(GHOST_JSON_FILE, 'utf8'));
  
  if (!jsonData.db || !jsonData.db[0] || !jsonData.db[0].data) {
    console.error('Invalid Ghost export format');
    process.exit(1);
  }
  
  const data = jsonData.db[0].data;
  const posts = data.posts || [];
  const tags = data.tags || [];
  const postsTags = data.posts_tags || [];
  
  console.log(`Found ${posts.length} posts, ${tags.length} tags`);
  
  // Create a map of tag IDs to tag names
  const tagMap = {};
  tags.forEach(tag => {
    tagMap[tag.id] = tag;
  });
  
  // Attach tags to posts
  posts.forEach(post => {
    post.tags = [];
    postsTags.forEach(pt => {
      if (pt.post_id === post.id && tagMap[pt.tag_id]) {
        post.tags.push(tagMap[pt.tag_id]);
      }
    });
  });
  
  // Filter out pages and drafts - only published posts
  const publishedPosts = posts.filter(post => 
    post.type === 'post' && 
    post.status === 'published'
  );
  
  console.log(`Found ${publishedPosts.length} published posts`);

  // Ensure output directory exists
  if (!fs.existsSync(OUTPUT_DIR)) {
    fs.mkdirSync(OUTPUT_DIR, { recursive: true });
  }

  for (const post of publishedPosts) {
    const slug = createSlug(post.title);
    const filename = `${slug}.md`;
    const filepath = path.join(OUTPUT_DIR, filename);
    
    // Debug: log post content info
    console.log(`\nProcessing: ${post.title}`);
    console.log(`HTML length: ${post.html ? post.html.length : 'none'}`);
    console.log(`Plaintext length: ${post.plaintext ? post.plaintext.length : 'none'}`);
    console.log(`Tags: ${post.tags.map(t => t.name).join(', ')}`);
    if (post.html && post.html.includes('<code>')) {
      console.log(`Contains code blocks: Yes`);
    }
    if (post.html && post.html.includes('<pre>')) {
      console.log(`Contains pre blocks: Yes`);
    }
    
    // Debug: show first 200 chars of HTML
    if (post.html && post.html.length > 0) {
      console.log(`HTML preview: ${post.html.substring(0, 200)}...`);
    }
    
    const markdownContent = convertPost(post);
    
    // Debug: show converted content length
    console.log(`Converted content length: ${markdownContent.length}`);
    console.log(`Content preview: ${markdownContent.substring(0, 300)}...`);
    
    fs.writeFileSync(filepath, markdownContent);
    console.log(`Exported: ${post.title} -> ${filename}`);
  }

  console.log(`\nExport complete! Files saved to ${OUTPUT_DIR}`);
}

if (require.main === module) {
  main().catch(console.error);
}