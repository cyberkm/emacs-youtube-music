# youtube-music

YouTube Music, in Emacs.

A magit-style status buffer for browsing your library, searching,
and playing music — without leaving your editor. Your full
playlists, your liked songs, your queue. Press `?` for the menu;
press `SPC` to pause; press `+` to like.

## Features

- **Status buffer** — Now Playing with progress bar, full queue
  showing what's played and what's next, and your sources at a
  glance. The currently playing track is highlighted; thumbs-up
  marks your liked songs.
- **Search** — find a song, play it now or queue it for later.
- **Library** — pick from your liked songs or any of your saved
  playlists.
- **Like / dislike** — works on the current track or whatever's
  under your cursor in the queue. The thumbs-up indicator updates
  immediately.
- **Shuffle and repeat** — toggle shuffle, cycle through repeat
  modes (off → playlist → single track → off).
- **Mode-line indicator** — see what's playing without switching
  buffers.
- **MPRIS support** — `playerctl`, waybar, and any other media
  controller see your playback.
- **Discoverable** — every command is one keystroke away from the
  status buffer; press `?` for a popup menu.

## Quick start

You need `mpv` and `yt-dlp` installed.

Drop this in your Emacs config:

```elisp
(add-to-list 'load-path "/path/to/emacs-youtube-music")
(use-package youtube-music
  :ensure nil
  :bind ("C-c y" . youtube-music)
  :config (youtube-music-modeline-mode 1))
```

### First time only — log in

1. `C-c y` (or `M-x youtube-music`) to open the status buffer.
2. Press `a` then `l`. A buffer appears with step-by-step
   instructions for grabbing your YouTube Music cookie from your
   browser. Paste, `C-c C-c`, done.

That's it. The cookie is saved to disk and loaded automatically
on every Emacs session afterwards.

### After that — just use it

- `C-c y` (or `M-x youtube-music`) — open the status buffer.
- `s` to search and queue a song.
- `l` for your library (liked songs, saved playlists).
- `?` to see every command.

The `C-c y` binding is whatever you set in `:bind` above; the
underlying entry-point command is `M-x youtube-music` — bind it
however you like.

That's it.

## Keys

Inside the status buffer:

| Key       | Action                                 |
| --------- | -------------------------------------- |
| `?` / `h` | Open the command menu                  |
| `SPC`     | Play / pause                           |
| `n` / `p` | Next / previous track                  |
| `x`       | Stop                                   |
| `f` / `b` | Seek forward / back 5 seconds          |
| `s`       | Search and queue a song                |
| `S`       | Search and play now (replacing queue)  |
| `l`       | Browse your library                    |
| `a`       | Log in / out                           |
| `+` / `-` | Like / dislike                         |
| `z`       | Shuffle                                |
| `r`       | Cycle repeat mode                      |
| `RET`     | Play the track at point                |
| `k`       | Remove from queue (or stop, on Now Playing) |
| `g`       | Refresh                                |
| `q`       | Bury the buffer                        |

Don't memorise any of it. Press `?` (or `h`) and pick from the menu.

## What's the deal with the cookie

YouTube Music doesn't have an official API for personal libraries.
The way `youtube-music` (and every other unofficial client) sees
your account is by reusing the cookie your browser already has.
The package walks you through copying it once. The cookie is saved
to `~/.config/youtube-music/credentials.eld` with strict
permissions (`0600`). Add `.gpg` to the filename if you want it
encrypted at rest.

You can log out at any time with `M-x youtube-music-logout` (or
press `a` then `o` from the status buffer); that deletes the
credentials file.

## Status

If something breaks or feels wrong, file an issue.

## License

GPL-3.0-or-later. See [LICENSE](./LICENSE).
