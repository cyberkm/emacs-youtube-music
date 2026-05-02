# youtube-music

YouTube Music. In Emacs.

```
── Now Playing ──
  ▶ Beautiful Day  👍  🔁
  ████████████░░░░░░░░░░░░░░░░░░   1:42 / 4:08

── Queue ──
    1  Wonderwall
    2  Sweet Child O' Mine
 ▶  3  Beautiful Day                          👍
    4  Karma Police
    5  Hey Jude

── Sources ──
  s  Search (enqueue)    S  Search (replace)
  u  Play URL             e  Enqueue URL
  l  Library (liked, playlists, home)

── Status ──
  ● signed in as Pavel B.
```

A magit-style status buffer for browsing, searching, and playing
music from your YouTube Music library. Press `?` for the menu.

## What it does

- Search and play. `s` to queue, `S` to play now.
- Browse your liked songs, your saved playlists, and YouTube
  Music Home (Discover Mix, Replay Mix, New releases, Albums for
  you, …).
- Like / dislike with `+` / `-`. Hearts you've liked show up
  next to every track in the queue.
- `R` starts a radio of similar tracks from whatever you're on.
- Shuffle, repeat-track, repeat-playlist.
- Mode-line indicator and MPRIS support, so `playerctl` and
  waybar see what's playing.

## Quick start

You need `mpv` and `yt-dlp` installed.

```elisp
(add-to-list 'load-path "/path/to/emacs-youtube-music")
(use-package youtube-music
  :ensure nil
  :bind ("C-c y" . youtube-music)
  :config (youtube-music-modeline-mode 1))
```

`C-c y` opens the status buffer. Press `a` then `l` to log in —
the package picks up your YouTube Music cookie from your browser
automatically (Firefox / Chromium / Brave / Chrome).

That's it.

## Keys

| Key       | Action                                          |
| --------- | ----------------------------------------------- |
| `?` / `h` | Command menu                                    |
| `SPC`     | Play / pause                                    |
| `n` / `p` | Next / previous track                           |
| `x`       | Stop                                            |
| `f` / `b` | Seek ±5 seconds                                 |
| `s`       | Search (enqueue)                                |
| `S`       | Search (play now)                               |
| `l`       | Library — liked / playlists / home              |
| `a`       | Log in / out                                    |
| `+` / `-` | Like / dislike                                  |
| `z`       | Shuffle                                         |
| `r`       | Cycle repeat                                    |
| `R`       | Radio of similar tracks                         |
| `u` / `e` | Play URL / enqueue URL                          |
| `RET`     | Play the track at point                         |
| `k`       | Remove from queue (or stop, on Now Playing)     |
| `g` / `q` | Refresh / bury                                  |

Press `?` to see them in a popup menu.

## Tips

Bind playback commands globally so you can control music from any
buffer — including media keys on your keyboard:

```elisp
(use-package youtube-music
  :ensure nil
  :bind (("C-c y" . youtube-music)
         ("<XF86AudioPlay>" . youtube-music-play-pause)
         ("<XF86AudioNext>" . youtube-music-next)
         ("<XF86AudioPrev>" . youtube-music-prev)
         ("<XF86AudioStop>" . youtube-music-stop))
  :config (youtube-music-modeline-mode 1))
```

Every interactive command is bindable: `youtube-music-play-pause`,
`-next`, `-prev`, `-stop`, `-like`, `-dislike`, `-radio`,
`-search`, `-toggle-shuffle`, `-cycle-repeat`, `-liked`, `-home`,
…  When called outside the status buffer, they act on the current
track.

## License

GPL-3.0-or-later. See [LICENSE](./LICENSE).
