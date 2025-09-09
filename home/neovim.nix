{
  config,
  pkgs,
  lib,
  ...
}: {
  programs.neovim = {
    enable = true;
    viAlias = true;
    vimAlias = true;
    vimdiffAlias = true;

    # Essential plugins for VS Code-like navigation
    plugins = with pkgs.vimPlugins; [
      # File explorer
      {
        plugin = nvim-tree-lua;
        type = "lua";
        config = ''
          require("nvim-tree").setup({
            view = {
              width = 30,
              side = "left",
            },
            renderer = {
              group_empty = true,
              icons = {
                show = {
                  file = true,
                  folder = true,
                  folder_arrow = true,
                  git = true,
                },
              },
            },
            filters = {
              dotfiles = false,
            },
            git = {
              enable = true,
              ignore = false,
            },
          })
        '';
      }

      # Fuzzy finder
      {
        plugin = telescope-nvim;
        type = "lua";
        config = ''
          local telescope = require('telescope')
          local builtin = require('telescope.builtin')

          telescope.setup({
            defaults = {
              layout_strategy = 'horizontal',
              layout_config = {
                horizontal = {
                  preview_width = 0.55,
                },
              },
              file_ignore_patterns = {
                "node_modules",
                ".git",
                "dist",
                "build",
              },
            },
            pickers = {
              find_files = {
                hidden = true,
              },
            },
          })
        '';
      }
      telescope-fzf-native-nvim

      # LSP and autocompletion
      {
        plugin = nvim-lspconfig;
        type = "lua";
        config = ''
          local lspconfig = require('lspconfig')

          -- Nix LSP
          lspconfig.nil_ls.setup({
            autostart = true,
            settings = {
              ['nil'] = {
                formatting = {
                  command = { "alejandra" },
                },
              },
            },
          })

          -- TypeScript/JavaScript
          lspconfig.tsserver.setup({})

          -- Python
          lspconfig.pyright.setup({})

          -- Rust
          lspconfig.rust_analyzer.setup({})

          -- Go
          lspconfig.gopls.setup({})
        '';
      }

      # Autocompletion
      {
        plugin = nvim-cmp;
        type = "lua";
        config = ''
          local cmp = require('cmp')
          local luasnip = require('luasnip')

          cmp.setup({
            snippet = {
              expand = function(args)
                luasnip.lsp_expand(args.body)
              end,
            },
            mapping = cmp.mapping.preset.insert({
              ['<C-b>'] = cmp.mapping.scroll_docs(-4),
              ['<C-f>'] = cmp.mapping.scroll_docs(4),
              ['<C-Space>'] = cmp.mapping.complete(),
              ['<C-e>'] = cmp.mapping.abort(),
              ['<CR>'] = cmp.mapping.confirm({ select = true }),
              ['<Tab>'] = cmp.mapping(function(fallback)
                if cmp.visible() then
                  cmp.select_next_item()
                elseif luasnip.expand_or_jumpable() then
                  luasnip.expand_or_jump()
                else
                  fallback()
                end
              end, { 'i', 's' }),
              ['<S-Tab>'] = cmp.mapping(function(fallback)
                if cmp.visible() then
                  cmp.select_prev_item()
                elseif luasnip.jumpable(-1) then
                  luasnip.jump(-1)
                else
                  fallback()
                end
              end, { 'i', 's' }),
            }),
            sources = cmp.config.sources({
              { name = 'nvim_lsp' },
              { name = 'luasnip' },
              { name = 'path' },
            }, {
              { name = 'buffer' },
            })
          })
        '';
      }
      cmp-nvim-lsp
      cmp-buffer
      cmp-path
      cmp_luasnip
      luasnip

      # Git integration
      {
        plugin = gitsigns-nvim;
        type = "lua";
        config = ''
          require('gitsigns').setup({
            signs = {
              add = { text = '+' },
              change = { text = '~' },
              delete = { text = '_' },
              topdelete = { text = '‾' },
              changedelete = { text = '~' },
            },
          })
        '';
      }

      # Status line
      {
        plugin = lualine-nvim;
        type = "lua";
        config = ''
          require('lualine').setup({
            options = {
              theme = 'auto',
              component_separators = { left = '|', right = '|' },
              section_separators = { left = ' ', right = ' ' },
            },
            sections = {
              lualine_a = {'mode'},
              lualine_b = {'branch', 'diff', 'diagnostics'},
              lualine_c = {'filename'},
              lualine_x = {'encoding', 'fileformat', 'filetype'},
              lualine_y = {'progress'},
              lualine_z = {'location'}
            },
          })
        '';
      }

      # Buffer line (tabs)
      {
        plugin = bufferline-nvim;
        type = "lua";
        config = ''
          require("bufferline").setup({
            options = {
              mode = "buffers",
              separator_style = "thin",
              always_show_bufferline = true,
              show_buffer_close_icons = true,
              show_close_icon = true,
              color_icons = true,
              diagnostics = "nvim_lsp",
            },
          })
        '';
      }

      # Treesitter for better syntax highlighting
      {
        plugin = nvim-treesitter.withAllGrammars;
        type = "lua";
        config = ''
          require('nvim-treesitter.configs').setup({
            highlight = {
              enable = true,
              additional_vim_regex_highlighting = false,
            },
            indent = {
              enable = true,
            },
            incremental_selection = {
              enable = true,
              keymaps = {
                init_selection = "<C-space>",
                node_incremental = "<C-space>",
                scope_incremental = false,
                node_decremental = "<bs>",
              },
            },
          })
        '';
      }

      # Which-key for keybinding help
      {
        plugin = which-key-nvim;
        type = "lua";
        config = ''
          require("which-key").setup({})
        '';
      }

      # Comment toggling
      {
        plugin = comment-nvim;
        type = "lua";
        config = ''
          require('Comment').setup({
            toggler = {
              line = 'gcc',
              block = 'gbc',
            },
            opleader = {
              line = 'gc',
              block = 'gb',
            },
          })
        '';
      }

      # Auto pairs
      {
        plugin = nvim-autopairs;
        type = "lua";
        config = ''
          require('nvim-autopairs').setup({})
        '';
      }

      # Indent guides
      {
        plugin = indent-blankline-nvim;
        type = "lua";
        config = ''
          require("ibl").setup({
            indent = {
              char = "│",
            },
            scope = {
              enabled = true,
              show_start = false,
              show_end = false,
            },
          })
        '';
      }

      # Better UI
      {
        plugin = noice-nvim;
        type = "lua";
        config = ''
          require("noice").setup({
            lsp = {
              override = {
                ["vim.lsp.util.convert_input_to_markdown_lines"] = true,
                ["vim.lsp.util.stylize_markdown"] = true,
                ["cmp.entry.get_documentation"] = true,
              },
            },
            presets = {
              bottom_search = true,
              command_palette = true,
              long_message_to_split = true,
              inc_rename = false,
              lsp_doc_border = false,
            },
          })
        '';
      }
      nui-nvim
      nvim-notify

      # Icons
      nvim-web-devicons

      # Dependencies
      plenary-nvim
      popup-nvim
    ];

    # Extra packages needed for LSP servers
    extraPackages = with pkgs; [
      # LSP servers
      nil
      nodePackages.typescript-language-server
      pyright
      rust-analyzer
      gopls
      lua-language-server

      # Formatters and tools
      alejandra
      rustfmt
      black
      nodePackages.prettier

      # For telescope
      ripgrep
      fd
    ];

    # Extra configuration
    extraLuaConfig = ''
      -- General settings
      vim.opt.number = true
      vim.opt.relativenumber = true
      vim.opt.mouse = 'a'
      vim.opt.ignorecase = true
      vim.opt.smartcase = true
      vim.opt.hlsearch = false
      vim.opt.wrap = false
      vim.opt.breakindent = true
      vim.opt.tabstop = 2
      vim.opt.shiftwidth = 2
      vim.opt.expandtab = true
      vim.opt.termguicolors = true
      vim.opt.signcolumn = 'yes'
      vim.opt.updatetime = 250
      vim.opt.timeoutlen = 300
      vim.opt.completeopt = 'menuone,noselect'
      vim.opt.undofile = true
      vim.opt.clipboard = 'unnamedplus'
      vim.opt.cursorline = true
      vim.opt.scrolloff = 8
      vim.opt.sidescrolloff = 8

      -- Set leader key
      vim.g.mapleader = ' '
      vim.g.maplocalleader = ' '

      -- VS Code-like keybindings
      local keymap = vim.keymap.set

      -- File explorer
      keymap('n', '<C-b>', ':NvimTreeToggle<CR>', { desc = 'Toggle file explorer' })
      keymap('n', '<leader>e', ':NvimTreeFocus<CR>', { desc = 'Focus file explorer' })

      -- Telescope (fuzzy finder)
      keymap('n', '<C-p>', ':Telescope find_files<CR>', { desc = 'Find files' })
      keymap('n', '<C-S-p>', ':Telescope commands<CR>', { desc = 'Command palette' })
      keymap('n', '<C-S-f>', ':Telescope live_grep<CR>', { desc = 'Search in files' })
      keymap('n', '<leader>fb', ':Telescope buffers<CR>', { desc = 'Find buffers' })
      keymap('n', '<leader>fh', ':Telescope help_tags<CR>', { desc = 'Find help' })
      keymap('n', '<leader>fg', ':Telescope git_files<CR>', { desc = 'Find git files' })
      keymap('n', '<leader>fs', ':Telescope grep_string<CR>', { desc = 'Search current word' })
      keymap('n', '<leader>fd', ':Telescope diagnostics<CR>', { desc = 'Find diagnostics' })
      keymap('n', '<leader>fr', ':Telescope oldfiles<CR>', { desc = 'Recent files' })

      -- LSP keybindings (VS Code-like)
      keymap('n', 'gd', vim.lsp.buf.definition, { desc = 'Go to definition' })
      keymap('n', 'gD', vim.lsp.buf.declaration, { desc = 'Go to declaration' })
      keymap('n', 'gi', vim.lsp.buf.implementation, { desc = 'Go to implementation' })
      keymap('n', 'gr', vim.lsp.buf.references, { desc = 'Find references' })
      keymap('n', 'K', vim.lsp.buf.hover, { desc = 'Hover documentation' })
      keymap('n', '<C-k>', vim.lsp.buf.signature_help, { desc = 'Signature help' })
      keymap('n', '<leader>rn', vim.lsp.buf.rename, { desc = 'Rename symbol' })
      keymap('n', '<leader>ca', vim.lsp.buf.code_action, { desc = 'Code action' })
      keymap('n', '<leader>f', vim.lsp.buf.format, { desc = 'Format document' })
      keymap('n', '[d', vim.diagnostic.goto_prev, { desc = 'Previous diagnostic' })
      keymap('n', ']d', vim.diagnostic.goto_next, { desc = 'Next diagnostic' })
      keymap('n', '<leader>d', vim.diagnostic.open_float, { desc = 'Show diagnostic' })
      keymap('n', '<leader>q', vim.diagnostic.setloclist, { desc = 'Diagnostic list' })

      -- Buffer navigation (tabs)
      keymap('n', '<Tab>', ':BufferLineCycleNext<CR>', { desc = 'Next buffer' })
      keymap('n', '<S-Tab>', ':BufferLineCyclePrev<CR>', { desc = 'Previous buffer' })
      keymap('n', '<leader>x', ':bdelete<CR>', { desc = 'Close buffer' })
      keymap('n', '<leader>X', ':bdelete!<CR>', { desc = 'Force close buffer' })
      keymap('n', '<C-w>', ':bdelete<CR>', { desc = 'Close buffer' })

      -- Window navigation
      keymap('n', '<C-h>', '<C-w>h', { desc = 'Navigate left' })
      keymap('n', '<C-j>', '<C-w>j', { desc = 'Navigate down' })
      keymap('n', '<C-k>', '<C-w>k', { desc = 'Navigate up' })
      keymap('n', '<C-l>', '<C-w>l', { desc = 'Navigate right' })

      -- Terminal
      keymap('n', '<leader>t', ':terminal<CR>', { desc = 'Open terminal' })
      keymap('t', '<Esc>', '<C-\\><C-n>', { desc = 'Exit terminal mode' })

      -- Save shortcuts
      keymap('n', '<C-s>', ':w<CR>', { desc = 'Save file' })
      keymap('i', '<C-s>', '<Esc>:w<CR>a', { desc = 'Save file' })

      -- Select all
      keymap('n', '<C-a>', 'ggVG', { desc = 'Select all' })

      -- Undo/Redo
      keymap('n', '<C-z>', 'u', { desc = 'Undo' })
      keymap('i', '<C-z>', '<Esc>ui', { desc = 'Undo' })
      keymap('n', '<C-y>', '<C-r>', { desc = 'Redo' })
      keymap('i', '<C-y>', '<Esc><C-r>i', { desc = 'Redo' })

      -- Move lines up/down
      keymap('n', '<A-k>', ':m .-2<CR>==', { desc = 'Move line up' })
      keymap('n', '<A-j>', ':m .+1<CR>==', { desc = 'Move line down' })
      keymap('v', '<A-k>', ":m '<-2<CR>gv=gv", { desc = 'Move selection up' })
      keymap('v', '<A-j>', ":m '>+1<CR>gv=gv", { desc = 'Move selection down' })

      -- Better indenting
      keymap('v', '<', '<gv', { desc = 'Indent left' })
      keymap('v', '>', '>gv', { desc = 'Indent right' })

      -- Quick escape
      keymap('i', 'jk', '<Esc>', { desc = 'Quick escape' })
      keymap('i', 'kj', '<Esc>', { desc = 'Quick escape' })

      -- Highlight on yank
      vim.api.nvim_create_autocmd('TextYankPost', {
        group = vim.api.nvim_create_augroup('YankHighlight', { clear = true }),
        callback = function()
          vim.highlight.on_yank()
        end,
      })

      -- Format on save
      vim.api.nvim_create_autocmd('BufWritePre', {
        pattern = '*',
        callback = function()
          if vim.bo.filetype ~= 'markdown' then
            vim.lsp.buf.format({ async = false })
          end
        end,
      })
    '';
  };
}
