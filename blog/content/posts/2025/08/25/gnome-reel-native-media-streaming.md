+++
title = "Reel: Bringing Native Media Streaming to the GNOME Desktop"
date = 2025-08-25
aliases = ["/posts/gnome-reel-native-media-streaming/"]
draft = false

[taxonomies]
tags = ["gnome", "rust", "linux", "media", "plex", "jellyfin", "gtk4"]

[extra]
toc = true
+++

<div align="center">
  <img src="https://raw.githubusercontent.com/arsfeld/gnome-reel/refs/heads/master/logo.svg" alt="Reel Logo" width="400" />
</div>

It's always been a dream of mine to have a proper, native media streaming client for GNOME. Not a web wrapper, not a half-maintained GTK3 app from years ago, but a real, modern, performant application that feels like it belongs on my desktop. After years of waiting and watching the landscape, I decided to build it myself. Enter [Reel](https://github.com/arsfeld/gnome-reel).

## TL;DR

[Reel](https://github.com/arsfeld/gnome-reel) is a native GTK4 media streaming client for GNOME that supports Plex and Jellyfin. Built with Rust, it offers multiple video backends (GStreamer and MPV), handles large libraries, and feels like a proper desktop app—not another web wrapper. Still in active development but already my daily driver for watching movies and shows.

## Why Build This?

Let's be honest about where we stand today with media streaming on the Linux desktop. It's... not great.

- **Girens**: Was a GTK-based Plex client that showed what was possible with native integration. While I haven't tried it in years, at the time the design felt dated and it didn't quite hit the mark for what I was looking for in a modern media client.

- **Official Plex App**: Exists for Linux and works fine, though it's essentially an Electron wrapper around their web app. It gets the job done but doesn't feel native to the desktop.

- **Infuse**: On macOS, I use [Infuse](https://firecore.com/infuse) daily—it's a fantastic native media client that shows what's possible with proper desktop integration. It's been my inspiration for what a Linux media app could be.

Well, now we're building it.

[![Reel Main Window](https://raw.githubusercontent.com/arsfeld/gnome-reel/refs/heads/master/screenshots/main-window.png)](https://raw.githubusercontent.com/arsfeld/gnome-reel/refs/heads/master/screenshots/main-window.png)

## Building Reel: The Technical Journey

### Why Rust?

Why not? 🦀

### The Architecture: Flexibility First

One of my key design decisions was to build a multi-backend architecture from day one. I didn't want to create "just another Plex client"—I wanted to build a media streaming platform for GNOME that could adapt to whatever service users prefer. Each service (Plex, Jellyfin, and eventually local files) implements a common interface, making the UI completely agnostic about where the media comes from.

### The Player Backend Saga

Here's where things got interesting. Video playback on Linux is... complicated.

GStreamer is the obvious choice for GTK applications—it's lighter on resources, well-integrated with the GNOME stack, and powerful. However, I hit a frustrating wall: subtitle rendering. On my machine, GStreamer has colorspace issues with certain subtitle formats that make them nearly unreadable.

As a pragmatic solution, I added support for multiple player backends. Now Reel ships with both:

- **GStreamer**: The preferred backend—lighter and better integrated with GNOME
- **MPV**: A fallback option that handles subtitles correctly while we work on fixing the GStreamer issue

Once the subtitle bug is resolved, MPV will purely be a fallback option, but for now this flexibility ensures everyone can enjoy their media regardless of subtitle formats.

[![Player View](https://raw.githubusercontent.com/arsfeld/gnome-reel/refs/heads/master/screenshots/player.png)](https://raw.githubusercontent.com/arsfeld/gnome-reel/refs/heads/master/screenshots/player.png)

## The Jellyfin Milestone

Just this week (v0.3.0), I reached a personal milestone: Jellyfin support. This wasn't just about adding another backend—it was about proving the architecture works.

Jellyfin represents something important in the media server space: true open-source freedom. While Plex is great, having an open alternative that users can self-host without restrictions matters. The implementation came together surprisingly smoothly, validating the multi-backend design.

Now users can:
- Connect to multiple servers (Plex and Jellyfin)
- Switch between them seamlessly
- Use the same intuitive interface regardless of the backend

[![Show Details](https://raw.githubusercontent.com/arsfeld/gnome-reel/refs/heads/master/screenshots/show-details.png)](https://raw.githubusercontent.com/arsfeld/gnome-reel/refs/heads/master/screenshots/show-details.png)

## Current Challenges and Solutions

There are plenty of bugs still to squash, but I'm already using it as my daily driver to watch movies and shows. Here are the main areas I'm working on:

### The Subtitle Situation

As mentioned, GStreamer subtitle rendering has some colorspace issues that I'm investigating. The MPV backend provides a workaround for now, but fixing the GStreamer issue properly is a priority—it's the better integrated solution for GNOME.

### Performance Optimization

Loading large libraries can still feel sluggish. I'm working on:
- Better caching strategies with SQLite
- Predictive prefetching for smoother browsing
- Investigating why Jellyfin is hit particularly hard when loading libraries
- Fixing MPV backend smoothness under system load (can show skipped frames occasionally)

### Feature Parity

Compared to official clients, we're still missing:
- Advanced search filters
- Music library support (also on the roadmap)
- Displaying cast and crew information
- Marking episodes as watched
- Downloading subtitles (you can select them in the player already)
- Tons of small features that official clients have

## The Road Ahead

Looking at my [TASKS.md](https://github.com/arsfeld/gnome-reel/blob/master/TASKS.md), the focus is on polish and usability:

### Near Term (Next Few Releases)
- **Search functionality**: Full-text search across all your media
- **Filtering and sorting**: Better ways to browse large libraries
- **Performance optimizations**: Faster loading and smoother scrolling
- **Bug fixes and polish**: Making the experience more reliable
- **Meson build system**: Adding support to fully integrate with the GNOME ecosystem, including translations

### Medium Term
- **Local files backend**: For your personal collection
- **Music support**: Because media isn't just video
- **Flatpak distribution**: Easy installation for everyone ([PR in progress](https://github.com/flathub/flathub/pull/6848))

## The Role of LLMs in Building This

I need to be honest about something: without LLMs, I wouldn't have gotten even close to this far with Reel. Whatever your opinion on AI tools, there's no denying they've made side projects like this dramatically more feasible.

As a parent, my coding time is precious—usually just those quiet hours after the kids are asleep. LLMs have been invaluable for:
- Getting the basic project up and running with Rust and GTK4
- Debugging those cryptic GStreamer errors at 11 PM
- Refactoring code became so much easier—we can try different approaches very quickly and discard anything that doesn't work
- The MPV backend was only possible because of AI—I wouldn't have known where to start, and even once the code was in place, it took forever to get the flow of GLArea and MPV to work just right

More importantly, they've helped maintain momentum. When you're exhausted after a full day and finally sit down to code, having an AI assistant to help push through blockers makes the difference between making progress and giving up for the night. It's brought back some of the joy and motivation to work on passion projects, even when time and energy are limited.

One lesson learned is how to interact with the community when using AI. I made the pull request to Flathub using an LLM, and while I did read all the Flathub documentation myself and thought I had a good grasp of the process, the PR had a template that you could only see if you opened it through the web. Instead, I asked the AI to open it through the command-line and it wasn't well received that a chatbot had written the PR. I understand the frustration—it's hard to draw the line of what AI should and shouldn't do.

## Get Involved

Reel is still in active development, and I'd love your help:

- **Try it out**: Install from [GitHub](https://github.com/arsfeld/gnome-reel) and report your experience
- **Report bugs**: Every issue helps make it better
- **Contribute code**: Whether it's features, fixes, or translations
- **Spread the word**: Let other Linux users know there's a native option

The project is 100% open source, built with Rust and GTK4, and designed to be hackable. Whether you want to add a new backend, improve the UI, or optimize performance, there's room for your contributions.

---

*Reel is available on [GitHub](https://github.com/arsfeld/gnome-reel). Currently supporting Plex and Jellyfin, with more backends on the way. Built with Rust, GTK4, and love for the Linux desktop.*