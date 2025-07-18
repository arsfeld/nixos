// Theme management
const themeToggle = document.getElementById('theme-toggle');
const prefersDarkScheme = window.matchMedia('(prefers-color-scheme: dark)');

// Get current theme from localStorage or system preference
function getCurrentTheme() {
  const storedTheme = localStorage.getItem('theme');
  if (storedTheme) {
    return storedTheme;
  }
  return prefersDarkScheme.matches ? 'dark' : 'light';
}

// Apply theme
function applyTheme(theme) {
  document.documentElement.setAttribute('data-theme', theme);
  localStorage.setItem('theme', theme);
}

// Initialize theme
applyTheme(getCurrentTheme());

// Theme toggle handler
if (themeToggle) {
  themeToggle.addEventListener('click', () => {
    const currentTheme = getCurrentTheme();
    const newTheme = currentTheme === 'dark' ? 'light' : 'dark';
    applyTheme(newTheme);
  });
}

// Listen for system preference changes
prefersDarkScheme.addEventListener('change', (e) => {
  const storedTheme = localStorage.getItem('theme');
  if (!storedTheme) {
    applyTheme(e.matches ? 'dark' : 'light');
  }
});

// Smooth scroll for anchor links
document.querySelectorAll('a[href^="#"]').forEach(anchor => {
  anchor.addEventListener('click', function (e) {
    e.preventDefault();
    const target = document.querySelector(this.getAttribute('href'));
    if (target) {
      target.scrollIntoView({
        behavior: 'smooth',
        block: 'start'
      });
    }
  });
});

// Add copy button to code blocks
document.addEventListener('DOMContentLoaded', () => {
  const codeBlocks = document.querySelectorAll('pre code');
  
  codeBlocks.forEach((codeBlock) => {
    const pre = codeBlock.parentElement;
    const wrapper = document.createElement('div');
    wrapper.className = 'code-block-wrapper';
    pre.parentNode.insertBefore(wrapper, pre);
    wrapper.appendChild(pre);
    
    const copyButton = document.createElement('button');
    copyButton.className = 'copy-button';
    copyButton.textContent = 'Copy';
    copyButton.setAttribute('aria-label', 'Copy code');
    
    copyButton.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(codeBlock.textContent);
        copyButton.textContent = 'Copied!';
        setTimeout(() => {
          copyButton.textContent = 'Copy';
        }, 2000);
      } catch (err) {
        console.error('Failed to copy:', err);
        copyButton.textContent = 'Error';
      }
    });
    
    wrapper.appendChild(copyButton);
  });
});


// Reading progress indicator
const progressBar = document.createElement('div');
progressBar.className = 'reading-progress';
document.body.appendChild(progressBar);

window.addEventListener('scroll', () => {
  const article = document.querySelector('.post-content');
  if (article) {
    const articleTop = article.offsetTop;
    const articleHeight = article.offsetHeight;
    const windowHeight = window.innerHeight;
    const scrolled = window.scrollY;
    
    const progress = Math.max(0, Math.min(100, 
      ((scrolled - articleTop + windowHeight) / articleHeight) * 100
    ));
    
    progressBar.style.width = `${progress}%`;
  }
});