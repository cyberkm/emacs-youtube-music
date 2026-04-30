# emacs-youtube-music

A YouTube Music client for Emacs.

The primary interface is a magit-style status buffer with sectioned
layout — Now Playing, Queue, Sources — driven by an `mpv` subprocess
over a UNIX-socket JSON IPC channel. A signed `youtubei/v1` HTTP
client talks to the YouTube Music internal API for search, library,
liked-songs, and like/dislike actions.

## Status

Early development. Not yet on MELPA.

Implemented:

- Playback skeleton: spawn/supervise `mpv`, observe properties,
  display now-playing in the global mode line.
- Magit-style status buffer with progress bar, queue (showing past /
  current / upcoming with the current track highlighted), and
  rating glyphs.
- Cookie-based authentication, stored in a `0600` credentials file
  (use a `.gpg` suffix to encrypt at rest via EPA).
- Search (replace or enqueue), library playlists, liked songs.
- Like / dislike, sourced from the server's liked-songs list with a
  session-local memory of explicit dislikes.
- Shuffle (`playlist-shuffle`/`-unshuffle`) and repeat (off /
  playlist / track).
- Optional `mpv-mpris` autoload so MPRIS controllers (`playerctl`,
  waybar) see playback state.
- Auto-pagination of all browse endpoints — no 25-track cap.

Deferred:

- True OAuth (Google has been restricting the YT Music scopes for
  unofficial clients; the cookie path is what actually works
  today).

## Requirements

- Emacs 29.1 or newer.
- `mpv` with its bundled `ytdl_hook` Lua script (the default).
- `yt-dlp` on `PATH` is recommended; `mpv` picks it up
  automatically when present.
- *Optional*: `mpv-mpris` plugin for MPRIS bus integration.

## Install (from this repo)

```elisp
(add-to-list 'load-path "/path/to/emacs-youtube-music")
(use-package youtube-music
  :ensure nil
  :bind ("C-c y" . youtube-music)
  :config (youtube-music-modeline-mode 1))
```

## Usage

1. `M-x youtube-music` (or `C-c y`) — pop the status buffer.
2. Press `a` to open the auth transient, then `l` to log in. A
   buffer opens with step-by-step instructions for grabbing the
   `Cookie` header from a browser session at
   `https://music.youtube.com`. Saved to
   `~/.config/youtube-music/credentials.eld` with mode `0600`.
3. Press `?` for the dispatch menu, or use the bindings directly.

### Buffer keybindings

| Key      | Action                                        |
| -------- | --------------------------------------------- |
| `?` `h`  | Open the dispatch transient                   |
| `SPC`    | Play / pause                                  |
| `n` `p`  | Next / previous track                         |
| `x`      | Stop                                          |
| `f` `b`  | Seek ±5 seconds                               |
| `s`      | Search (enqueue chosen result)                |
| `S`      | Search (replace playlist with chosen result)  |
| `l`      | Library (liked songs / saved playlists)       |
| `a`      | Authentication (login / logout / status)      |
| `u` `e`  | Play URL / enqueue URL                        |
| `+` `-`  | Like / dislike track at point or current      |
| `z`      | Toggle shuffle                                |
| `r`      | Cycle repeat (off → playlist → track → off)   |
| `RET`    | Play track at point                           |
| `k`      | Remove track at point (or stop, on Now Playing) |
| `g`      | Refresh                                       |
| `q`      | Bury buffer                                   |
| `L`      | Show the mpv log buffer                       |

## Security notes

- The credentials file is created with mode `0600`.
- The mpv IPC socket is `chmod`-ed to `0600` after creation.
- No tokens are passed on the mpv command line.

## License

GPL-3.0-or-later. See [LICENSE](./LICENSE).
