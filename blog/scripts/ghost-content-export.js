#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

// Configuration - using Content API instead of Admin API
const GHOST_URL = 'https://blog.arsfeld.dev';
const OUTPUT_DIR = path.join(__dirname, '..', 'content', 'posts');

// Improved HTML to Markdown converter
function htmlToMarkdown(html) {
  if (!html) return '';
  
  return html
    // Handle headings
    .replace(/<h1[^>]*>(.*?)<\/h1>/gis, '# $1\n\n')
    .replace(/<h2[^>]*>(.*?)<\/h2>/gis, '## $1\n\n')
    .replace(/<h3[^>]*>(.*?)<\/h3>/gis, '### $1\n\n')
    .replace(/<h4[^>]*>(.*?)<\/h4>/gis, '#### $1\n\n')
    .replace(/<h5[^>]*>(.*?)<\/h5>/gis, '##### $1\n\n')
    .replace(/<h6[^>]*>(.*?)<\/h6>/gis, '###### $1\n\n')
    
    // Handle formatting
    .replace(/<strong[^>]*>(.*?)<\/strong>/gis, '**$1**')
    .replace(/<b[^>]*>(.*?)<\/b>/gis, '**$1**')
    .replace(/<em[^>]*>(.*?)<\/em>/gis, '*$1*')
    .replace(/<i[^>]*>(.*?)<\/i>/gis, '*$1*')
    
    // Handle code blocks and inline code - preserve whitespace and newlines
    .replace(/<pre[^>]*><code[^>]*>(.*?)<\/code><\/pre>/gis, (match, code) => {
      // Decode HTML entities in code blocks and preserve formatting
      const cleanCode = code
        .replace(/&lt;/g, '<')
        .replace(/&gt;/g, '>')
        .replace(/&amp;/g, '&')
        .replace(/&quot;/g, '"')
        .replace(/&#39;/g, "'");
      return '\n```\n' + cleanCode + '\n```\n\n';
    })
    .replace(/<code[^>]*>(.*?)<\/code>/gis, '`$1`')
    
    // Handle links and images
    .replace(/<a[^>]*href=["']([^"']*)["'][^>]*>(.*?)<\/a>/gis, '[$2]($1)')
    .replace(/<img[^>]*src=["']([^"']*)["'][^>]*alt=["']([^"']*)["'][^>]*\/?>/gis, '![$2]($1)')
    .replace(/<img[^>]*alt=["']([^"']*)["'][^>]*src=["']([^"']*)["'][^>]*\/?>/gis, '![$1]($2)')
    .replace(/<img[^>]*src=["']([^"']*)["'][^>]*\/?>/gis, '![]($1)')
    
    // Handle lists
    .replace(/<ul[^>]*>/gis, '\n')
    .replace(/<\/ul>/gis, '\n')
    .replace(/<ol[^>]*>/gis, '\n')
    .replace(/<\/ol>/gis, '\n')
    .replace(/<li[^>]*>(.*?)<\/li>/gis, '- $1\n')
    
    // Handle blockquotes
    .replace(/<blockquote[^>]*>(.*?)<\/blockquote>/gis, (match, content) => {
      return '> ' + content.replace(/\n/g, '\n> ').trim() + '\n\n';
    })
    
    // Handle line breaks and paragraphs
    .replace(/<br\s*\/?>/gis, '\n')
    .replace(/<p[^>]*>(.*?)<\/p>/gis, '$1\n\n')
    .replace(/<div[^>]*>(.*?)<\/div>/gis, '$1\n')
    
    // Remove any remaining HTML tags
    .replace(/<[^>]*>/g, '')
    
    // Decode HTML entities
    .replace(/&quot;/g, '"')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&nbsp;/g, ' ')
    .replace(/&#8217;/g, "'")
    .replace(/&#8216;/g, "'")
    .replace(/&#8220;/g, '"')
    .replace(/&#8221;/g, '"')
    
    // Clean up excessive whitespace
    .replace(/\n\n\n+/g, '\n\n')
    .replace(/\s+$/gm, '') // Remove trailing spaces
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

// Fetch posts using Content API (public, no auth needed)
async function fetchPosts() {
  try {
    // Using Content API - no authentication needed, but limited fields
    const response = await fetch(`${GHOST_URL}/ghost/api/content/posts/?limit=all&include=tags&formats=html`);

    if (response.ok) {
      const result = await response.json();
      console.log(`Found ${result.posts.length} posts via Content API`);
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
  
  // Clean and properly escape description
  const description = (post.excerpt || post.meta_description || post.title || '')
    .replace(/\n/g, ' ')  // Replace newlines with spaces
    .replace(/\r/g, '')   // Remove carriage returns
    .replace(/"/g, '\\"') // Escape quotes
    .trim()
    .substring(0, 200);   // Limit length
  
  const frontmatter = `+++
title = "${post.title.replace(/"/g, '\\"')}"
date = ${publishedDate}
description = "${description}"
tags = [${tags.map(tag => `"${tag.replace(/"/g, '\\"')}"`).join(', ')}]
+++

`;

  // Convert HTML content to markdown
  const content = htmlToMarkdown(post.html || '');
  
  return frontmatter + content;
}

// Main function
async function main() {
  console.log('Fetching posts from Ghost Content API...');
  const posts = await fetchPosts();
  
  if (posts.length === 0) {
    console.log('No posts found');
    return;
  }

  // Ensure output directory exists
  if (!fs.existsSync(OUTPUT_DIR)) {
    fs.mkdirSync(OUTPUT_DIR, { recursive: true });
  }

  for (const post of posts) {
    const slug = createSlug(post.title);
    const filename = `${slug}.md`;
    const filepath = path.join(OUTPUT_DIR, filename);
    
    // Debug: log post content info
    console.log(`\nProcessing: ${post.title}`);
    console.log(`HTML length: ${post.html ? post.html.length : 'none'}`);
    if (post.html && post.html.includes('<code>')) {
      console.log(`Contains code blocks: Yes`);
    }
    if (post.html && post.html.includes('<pre>')) {
      console.log(`Contains pre blocks: Yes`);
    }
    
    const markdownContent = convertPost(post);
    
    fs.writeFileSync(filepath, markdownContent);
    console.log(`Exported: ${post.title} -> ${filename}`);
  }

  console.log(`\nExport complete! Files saved to ${OUTPUT_DIR}`);
}

if (require.main === module) {
  main().catch(console.error);
}