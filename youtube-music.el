;;; youtube-music.el --- YouTube Music client -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Pavel Bibergal

;; Author: Pavel Bibergal <pavel@keewano.com>
;; URL: https://github.com/cyberkm/emacs-youtube-music
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: multimedia, youtube, music

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; youtube-music.el is a YouTube Music client for Emacs.  It uses
;; `mpv' as its playback backend (over a JSON IPC socket) and -- in
;; later phases -- the YouTube Music internal API for browsing and
;; search.
;;
;; The primary entry point is `M-x youtube-music', which pops a status
;; buffer styled after Magit: a Now Playing section, the upcoming
;; queue, and browseable sources.  Press `C-h m' inside the buffer to
;; see every key binding.
;;
;; Phase 1 ships the playback skeleton:
;;
;;   - spawn and supervise an `mpv' subprocess,
;;   - send commands and receive events over a UNIX-socket IPC channel,
;;   - track playback state via property observation,
;;   - render a status buffer with a magit-style sectioned layout,
;;   - display now-playing information in the global mode line.
;;
;; Phase 2 adds the YouTube Music API client and search:
;;
;;   - cookie-based authentication, stored in a 0600 credentials file,
;;   - signed youtubei/v1 POST requests with SAPISIDHASH auth,
;;   - `M-x youtube-music-search' to find songs and play one.
;;
;; Phase 3 adds login/logout management and library browse:
;;
;;   - `M-x youtube-music-auth' transient (login / logout / status),
;;   - `M-x youtube-music-liked'  to play your liked-songs list,
;;   - `M-x youtube-music-library-playlists' to pick and play a saved
;;     playlist,
;;   - `M-x youtube-music-library' transient that groups the above.
;;
;; OAuth device flow is intentionally deferred: Google has been
;; restricting which client_ids may grant the YouTube Music scopes,
;; so the unofficial-OAuth path is currently unreliable.  The cookie
;; flow is robust and is used by `ytmusicapi' and `ytermusic' alike.
;;
;; Required external programs: `mpv' and `yt-dlp'.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'transient)
(require 'url)

;;;; Customization

(defgroup youtube-music nil
  "YouTube Music client for Emacs."
  :group 'multimedia
  :prefix "youtube-music-")

(defcustom youtube-music-mpv-program "mpv"
  "Path to the mpv executable."
  :type 'string)

(defcustom youtube-music-mpv-extra-args
  '("--idle=yes"
    "--no-video"
    "--no-terminal"
    "--msg-level=all=warn"
    "--ytdl-format=bestaudio")
  "Additional arguments passed to mpv on startup.
Diagnostics from mpv land in the ` *youtube-music-mpv*' buffer; open
it with `youtube-music-show-log'."
  :type '(repeat string))

(defcustom youtube-music-mpv-mpris-search-paths
  '("/usr/lib64/mpv/scripts/mpris.so"
    "/usr/lib/mpv/scripts/mpris.so"
    "/usr/lib/mpv-mpris/mpris.so"
    "/usr/local/lib/mpv/scripts/mpris.so")
  "Candidate paths searched for the mpv-mpris plugin.
When the first existing path is non-nil it is loaded via mpv's
`--script' flag, exposing playback state on the MPRIS D-Bus
interface (`playerctl', the waybar mpris module, etc.).  Set to
nil to opt out."
  :type '(repeat file))

(defcustom youtube-music-modeline-format " %P♪ %t"
  "Format string for the mode-line indicator.
Recognised tokens:
  %t — media title
  %p — current position (m:ss)
  %d — total duration (m:ss)
  %P — pause indicator (\"⏸ \" while paused, empty otherwise)"
  :type 'string)

(defcustom youtube-music-seek-step 5
  "Seconds for `youtube-music-seek-forward' / `youtube-music-seek-backward'."
  :type 'integer)

(defcustom youtube-music-progress-bar-width 30
  "Width, in characters, of the now-playing progress bar."
  :type 'integer)

(defcustom youtube-music-buffer-name "*youtube-music*"
  "Name of the status buffer."
  :type 'string)

;;;; Faces

(defface youtube-music-section-heading
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for section headings in the status buffer.")

(defface youtube-music-current-track
  '((t :inherit font-lock-string-face :weight bold))
  "Face for the now-playing track title.")

(defface youtube-music-queue-current
  '((t :inherit font-lock-string-face :weight bold))
  "Face for the currently-playing entry inside the Queue section.")

(defface youtube-music-queue-past
  '((t :inherit shadow))
  "Face for already-played entries inside the Queue section.")

(defface youtube-music-thumbs-up
  '((t :inherit success :weight bold))
  "Face for the thumbs-up indicator on a track.")

(defface youtube-music-thumbs-down
  '((t :inherit error))
  "Face for the thumbs-down indicator on a track.")

(defface youtube-music-progress-fill
  '((t :inherit font-lock-keyword-face))
  "Face for the filled portion of the progress bar.")

(defface youtube-music-progress-empty
  '((t :inherit shadow))
  "Face for the empty portion of the progress bar.")

(defface youtube-music-help
  '((t :inherit shadow))
  "Face for the in-buffer help line.")

;;;; Internal state

(defvar youtube-music--mpv-process nil
  "The mpv subprocess, or nil.")

(defvar youtube-music--ipc-process nil
  "The network process connected to mpv's IPC socket, or nil.")

(defvar youtube-music--socket-path nil
  "Cached UNIX socket path used for the mpv IPC server.")

(defvar youtube-music--request-counter 0
  "Monotonically increasing counter for IPC request IDs.")

(defvar youtube-music--pending-requests (make-hash-table :test 'eql)
  "Map of pending IPC request IDs to callback functions.")

(defvar youtube-music--ipc-buffer ""
  "Accumulator for partial IPC messages received from mpv.")

(defvar youtube-music--state
  (list :title nil :pause t :time-pos 0 :duration 0 :playlist-pos -1
        :path nil :loop-file "no" :loop-playlist "no")
  "Cached playback state, refreshed by mpv property events.")

(defvar youtube-music--shuffled-p nil
  "Non-nil when we have shuffled the current mpv playlist.
Tracked locally because mpv has no runtime `shuffled' property.")

(defvar youtube-music--mode-line-string ""
  "Pre-formatted mode-line indicator, recomputed on state change.")

(defvar youtube-music--playlist-cache nil
  "Cached playlist contents fetched from mpv.")

(defvar youtube-music--track-meta (make-hash-table :test 'equal)
  "Map of videoId → plist (:title :subtitle) for tracks we queued.
Populated when we hand a track to mpv so the status buffer can
display the proper artist/song instead of mpv's URL filename
before metadata is resolved.")

(defvar youtube-music--liked-set nil
  "Hash-set of videoIds in the user's liked-songs list, or nil.
Nil until populated.  Use `youtube-music-refresh-liked-set' to
fetch (or play your liked songs, which seeds it as a side effect).")

(defvar youtube-music--disliked-set (make-hash-table :test 'equal)
  "Hash-set of videoIds the user disliked in the current session.
We cannot query the server for disliked tracks the way we do for
liked ones, so this is session-local.  Cleared on quit/logout.")

;;;; Lifecycle

(defun youtube-music--socket-path ()
  "Return the IPC socket path, computing it once on first use."
  (or youtube-music--socket-path
      (setq youtube-music--socket-path
            (expand-file-name (format "youtube-music-mpv-%d.sock" (user-uid))
                              temporary-file-directory))))

(defun youtube-music--mpv-running-p ()
  "Return non-nil when the mpv subprocess is alive."
  (and youtube-music--mpv-process (process-live-p youtube-music--mpv-process)))

(defun youtube-music--ipc-connected-p ()
  "Return non-nil when the IPC connection to mpv is open."
  (and youtube-music--ipc-process (process-live-p youtube-music--ipc-process)))

(defun youtube-music--mpv-sentinel (_proc event)
  "Process sentinel for the mpv subprocess.
EVENT is the `process-status' string supplied by Emacs.  When it
indicates that mpv has exited, reset cached state and clear the
mode-line indicator."
  (when (string-match-p
         "\\(exited\\|finished\\|killed\\|signal\\|deleted\\)" event)
    (setq youtube-music--mpv-process nil
          youtube-music--ipc-process nil
          youtube-music--state (list :title nil :pause t :time-pos 0
                                      :duration 0 :playlist-pos -1 :path nil)
          youtube-music--playlist-cache nil)
    (clrhash youtube-music--track-meta)
    (setq youtube-music--liked-set nil
          youtube-music--shuffled-p nil)
    (clrhash youtube-music--disliked-set)
    (youtube-music--refresh-modeline)
    (youtube-music--rerender)))

(defun youtube-music--mpris-script-path ()
  "Return the first existing path in `youtube-music-mpv-mpris-search-paths'."
  (cl-find-if #'file-exists-p youtube-music-mpv-mpris-search-paths))

(defun youtube-music--start-mpv ()
  "Spawn the mpv subprocess and wait for the IPC socket to appear."
  (let* ((sock (youtube-music--socket-path))
         (mpris (youtube-music--mpris-script-path)))
    (when (file-exists-p sock) (delete-file sock))
    (setq youtube-music--mpv-process
          (apply #'start-process
                 "youtube-music-mpv"
                 (get-buffer-create " *youtube-music-mpv*")
                 youtube-music-mpv-program
                 (append youtube-music-mpv-extra-args
                         (list (format "--input-ipc-server=%s" sock))
                         (when mpris
                           (list (format "--script=%s" mpris))))))
    (set-process-query-on-exit-flag youtube-music--mpv-process nil)
    (set-process-sentinel youtube-music--mpv-process #'youtube-music--mpv-sentinel)
    (let ((tries 0))
      (while (and (< tries 50) (not (file-exists-p sock)))
        (sleep-for 0.05)
        (cl-incf tries)))
    (unless (file-exists-p sock)
      (error "Mpv did not create IPC socket at %s" sock))
    ;; Restrict the IPC socket to the owning user.
    (set-file-modes sock #o600)))

(defun youtube-music--connect-ipc ()
  "Connect to mpv's IPC socket and start observing properties."
  (setq youtube-music--ipc-buffer "")
  (setq youtube-music--ipc-process
        (make-network-process
         :name "youtube-music-ipc"
         :family 'local
         :service (youtube-music--socket-path)
         :coding 'utf-8
         :filter #'youtube-music--ipc-filter
         :sentinel #'youtube-music--ipc-sentinel))
  (youtube-music--observe-properties))

(defun youtube-music--ensure-mpv ()
  "Start mpv and connect to its IPC socket if either is missing."
  (unless (youtube-music--mpv-running-p) (youtube-music--start-mpv))
  (unless (youtube-music--ipc-connected-p) (youtube-music--connect-ipc)))

;;;; IPC

(defun youtube-music--send (command &optional callback)
  "Send COMMAND (a list of strings/numbers) to mpv.
If CALLBACK is non-nil, it is invoked with the response plist."
  (youtube-music--ensure-mpv)
  (let* ((id (cl-incf youtube-music--request-counter))
         (payload (json-encode `((command . ,(vconcat command))
                                 (request_id . ,id)))))
    (when callback
      (puthash id callback youtube-music--pending-requests))
    (process-send-string youtube-music--ipc-process (concat payload "\n"))
    id))

(defun youtube-music--ipc-filter (_proc data)
  "Parse incoming IPC DATA from mpv and dispatch each line."
  (condition-case nil
      (progn
        (setq youtube-music--ipc-buffer (concat youtube-music--ipc-buffer data))
        (let (line)
          (while (string-match "\n" youtube-music--ipc-buffer)
            (setq line (substring youtube-music--ipc-buffer
                                  0 (match-beginning 0)))
            (setq youtube-music--ipc-buffer
                  (substring youtube-music--ipc-buffer (match-end 0)))
            (unless (string-empty-p line)
              (condition-case err
                  (youtube-music--handle-message
                   (json-parse-string line :object-type 'plist :null-object nil))
                (error (message "Youtube-music: bad IPC payload: %s -- %S"
                                line err)))))))
    (quit nil)))

(defun youtube-music--ipc-sentinel (_proc event)
  "Network process sentinel for the IPC connection.
EVENT is the `process-status' string supplied by Emacs."
  (when (string-match-p
         "\\(closed\\|exited\\|finished\\|connection broken\\|deleted\\)"
         event)
    (setq youtube-music--ipc-process nil)))

(defun youtube-music--handle-message (msg)
  "Dispatch a parsed IPC MSG plist to its callback or event handler."
  (let ((rid (plist-get msg :request_id))
        (event (plist-get msg :event))
        (err (plist-get msg :error)))
    (when (and rid err (not (equal err "success")))
      (message "youtube-music: mpv error: %s" err))
    (cond
     (rid
      (when-let ((cb (gethash rid youtube-music--pending-requests)))
        (remhash rid youtube-music--pending-requests)
        (funcall cb msg)))
     ((equal event "property-change")
      (youtube-music--apply-property
       (plist-get msg :name)
       (plist-get msg :data)))
     ((equal event "end-file")
      (let ((reason (plist-get msg :reason)))
        (when (member reason '("error" "unknown"))
          (message "youtube-music: playback ended (%s); see `youtube-music-show-log'"
                   reason)))))))

;;;; Property observation

(defconst youtube-music--observed-properties
  '("pause" "media-title" "time-pos" "duration"
    "playlist-pos" "playlist" "path"
    "loop-file" "loop-playlist")
  "List of mpv properties we subscribe to on connect.")

(defun youtube-music--observe-properties ()
  "Subscribe to every entry in `youtube-music--observed-properties'."
  (cl-loop for prop in youtube-music--observed-properties
           for i from 1
           do (youtube-music--send `("observe_property" ,i ,prop))))

(defun youtube-music--apply-property (name data)
  "Update cached state for the mpv property NAME with DATA."
  (pcase name
    ("pause"        (setq youtube-music--state
                          (plist-put youtube-music--state :pause (eq data t))))
    ("media-title"  (setq youtube-music--state
                          (plist-put youtube-music--state :title data)))
    ("time-pos"     (setq youtube-music--state
                          (plist-put youtube-music--state :time-pos (or data 0))))
    ("duration"     (setq youtube-music--state
                          (plist-put youtube-music--state :duration (or data 0))))
    ("playlist-pos" (setq youtube-music--state
                          (plist-put youtube-music--state :playlist-pos (or data -1))))
    ("playlist"     (setq youtube-music--playlist-cache
                          (when (sequencep data) (append data nil))))
    ("path"         (setq youtube-music--state
                          (plist-put youtube-music--state :path data)))
    ("loop-file"     (setq youtube-music--state
                           (plist-put youtube-music--state :loop-file
                                      (if (or (numberp data)
                                              (and (stringp data)
                                                   (member data '("inf" "yes"))))
                                          "inf" "no"))))
    ("loop-playlist" (setq youtube-music--state
                           (plist-put youtube-music--state :loop-playlist
                                      (if (or (numberp data)
                                              (and (stringp data)
                                                   (member data '("inf" "yes"))))
                                          "inf" "no")))))
  (youtube-music--refresh-modeline)
  (youtube-music--rerender))

;;;; Mode line

(defun youtube-music--format-time (seconds)
  "Format SECONDS as a m:ss string for display."
  (if (or (null seconds) (not (numberp seconds))) "0:00"
    (format "%d:%02d" (truncate (/ seconds 60)) (mod (truncate seconds) 60))))

(defun youtube-music--refresh-modeline ()
  "Recompute `youtube-music--mode-line-string' from cached state."
  (setq youtube-music--mode-line-string
        (let ((title (plist-get youtube-music--state :title))
              (pause (plist-get youtube-music--state :pause))
              (pos   (plist-get youtube-music--state :time-pos))
              (dur   (plist-get youtube-music--state :duration)))
          (if (null title) ""
            (let ((s youtube-music-modeline-format))
              (setq s (replace-regexp-in-string "%t" (or title "") s t t))
              (setq s (replace-regexp-in-string "%p" (youtube-music--format-time pos) s t t))
              (setq s (replace-regexp-in-string "%d" (youtube-music--format-time dur) s t t))
              (setq s (replace-regexp-in-string "%P" (if pause "⏸ " "") s t t))
              s))))
  (force-mode-line-update t))

;;;###autoload
(define-minor-mode youtube-music-modeline-mode
  "Show YouTube Music now-playing information in the global mode line."
  :global t
  :lighter ""
  (if youtube-music-modeline-mode
      (unless (member '(:eval youtube-music--mode-line-string) global-mode-string)
        (setq global-mode-string
              (append (or global-mode-string '(""))
                      '((:eval youtube-music--mode-line-string)))))
    (setq global-mode-string
          (delete '(:eval youtube-music--mode-line-string) global-mode-string))))

;;;; Status buffer

(defvar-keymap youtube-music-mode-map
  :doc "Keymap for `youtube-music-mode'."
  "?"   #'youtube-music-dispatch
  "h"   #'youtube-music-dispatch
  "SPC" #'youtube-music-play-pause
  "n"   #'youtube-music-next
  "p"   #'youtube-music-prev
  "x"   #'youtube-music-stop
  "f"   #'youtube-music-seek-forward
  "b"   #'youtube-music-seek-backward
  "g"   #'youtube-music-refresh
  "q"   #'quit-window
  "RET" #'youtube-music-play-at-point
  "k"   #'youtube-music-remove-at-point
  "u"   #'youtube-music-play-url
  "e"   #'youtube-music-enqueue-url
  "S"   #'youtube-music-search
  "s"   #'youtube-music-search-enqueue
  "l"   #'youtube-music-library
  "a"   #'youtube-music-auth
  "L"   #'youtube-music-show-log
  "+"   #'youtube-music-like
  "-"   #'youtube-music-dislike
  "z"   #'youtube-music-toggle-shuffle
  "r"   #'youtube-music-cycle-repeat)

(define-derived-mode youtube-music-mode special-mode "YT-Music"
  "Major mode for the YouTube Music status buffer.
\\{youtube-music-mode-map}"
  (setq-local revert-buffer-function
              (lambda (&rest _) (youtube-music-refresh)))
  (setq-local truncate-lines t))

(defun youtube-music--status-buffer ()
  "Return the status buffer, creating it in `youtube-music-mode' if needed."
  (or (get-buffer youtube-music-buffer-name)
      (with-current-buffer (get-buffer-create youtube-music-buffer-name)
        (youtube-music-mode)
        (current-buffer))))

;;;###autoload
(defun youtube-music ()
  "Pop up the YouTube Music status buffer."
  (interactive)
  (pop-to-buffer (youtube-music--status-buffer))
  (youtube-music-refresh)
  (when (and (null youtube-music--liked-set)
             (youtube-music--logged-in-p))
    (youtube-music-refresh-liked-set)))

(defun youtube-music-refresh ()
  "Refresh the status buffer from cached state, pulling from mpv if running."
  (interactive)
  (when (youtube-music--mpv-running-p)
    (youtube-music--send '("get_property" "playlist") #'youtube-music--on-playlist))
  (youtube-music--rerender))

(defun youtube-music--on-playlist (msg)
  "Cache the playlist returned by mpv (carried in MSG) and re-render."
  (let ((data (plist-get msg :data)))
    (setq youtube-music--playlist-cache
          (when (sequencep data) (append data nil))))
  (youtube-music--rerender))

(defun youtube-music--rerender ()
  "Redraw the status buffer if it exists, preserving point and scroll."
  (when-let ((buf (get-buffer youtube-music-buffer-name)))
    (with-current-buffer buf
      (let* ((inhibit-read-only t)
             (line (line-number-at-pos))
             (col (current-column))
             ;; Capture window-start per window so the view doesn't
             ;; snap to the top on every property tick.
             (window-states
              (mapcar (lambda (w)
                        (cons w (line-number-at-pos (window-start w))))
                      (get-buffer-window-list buf nil t))))
        (erase-buffer)
        (youtube-music--render-now-playing)
        (youtube-music--render-queue)
        (youtube-music--render-sources)
        (youtube-music--render-help)
        (goto-char (point-min))
        (forward-line (1- line))
        (move-to-column col)
        (dolist (ws window-states)
          (let ((w (car ws))
                (start-line (cdr ws)))
            (when (window-live-p w)
              (set-window-start
               w
               (save-excursion
                 (goto-char (point-min))
                 (forward-line (1- start-line))
                 (point))
               t))))))))

(defun youtube-music--insert-heading (text)
  "Insert TEXT as a section heading."
  (insert (propertize text 'face 'youtube-music-section-heading) "\n"))

(defun youtube-music--render-progress (pos dur width)
  "Return a propertized progress bar of WIDTH columns for POS/DUR."
  (if (or (not (numberp pos)) (not (numberp dur)) (<= dur 0))
      (propertize (make-string width ?░) 'face 'youtube-music-progress-empty)
    (let ((filled (truncate (* width (/ (float pos) dur)))))
      (concat (propertize (make-string filled ?█)
                          'face 'youtube-music-progress-fill)
              (propertize (make-string (max 0 (- width filled)) ?░)
                          'face 'youtube-music-progress-empty)))))

(defun youtube-music--render-now-playing ()
  "Render the Now Playing section."
  (youtube-music--insert-heading "── Now Playing ──")
  (let* ((mpv-title (plist-get youtube-music--state :title))
         (path  (plist-get youtube-music--state :path))
         (pause (plist-get youtube-music--state :pause))
         (pos   (plist-get youtube-music--state :time-pos))
         (dur   (plist-get youtube-music--state :duration))
         (title (and (or mpv-title path)
                     (youtube-music--display-title-for path mpv-title))))
    (if (null title)
        (insert "  (nothing playing)\n")
      (let ((start (point))
            (glyph (youtube-music--current-rating-glyph))
            (badges (youtube-music--mode-badges)))
        (insert "  " (if pause "⏸" "▶") " "
                (propertize title 'face 'youtube-music-current-track)
                (if glyph (concat "  " glyph) "")
                badges
                "\n")
        (insert (format "  %s   %s / %s\n"
                        (youtube-music--render-progress
                         pos dur youtube-music-progress-bar-width)
                        (youtube-music--format-time pos)
                        (youtube-music--format-time dur)))
        (put-text-property start (point) 'youtube-music-now-playing t))))
  (insert "\n"))

(defun youtube-music--render-queue ()
  "Render the queue section.
Shows every track in mpv's playlist; played entries are dimmed,
the currently-playing entry is highlighted with a leading arrow."
  (youtube-music--insert-heading "── Queue ──")
  (let* ((items youtube-music--playlist-cache)
         (cur   (plist-get youtube-music--state :playlist-pos)))
    (if (null items)
        (insert "  (queue empty)\n")
      (cl-loop
       for entry in items
       for i from 0
       do (let* ((filename (plist-get entry :filename))
                 (mpv-title (plist-get entry :title))
                 (title (youtube-music--display-title-for filename mpv-title))
                 (vid     (youtube-music--video-id-from-url filename))
                 (rating  (youtube-music--rating-glyph-for vid))
                 (current (and cur (= i cur)))
                 (past    (and cur (< i cur)))
                 (marker  (if current "▶" " "))
                 (face    (cond (current 'youtube-music-queue-current)
                                (past   'youtube-music-queue-past)
                                (t      'default)))
                 (line    (format " %s %2d  %s%s\n"
                                  marker (1+ i) title
                                  (if rating (concat "  " rating) ""))))
            (insert (propertize line
                                'face face
                                'youtube-music-playlist-index i))))))
  (insert "\n"))

(defun youtube-music--render-sources ()
  "Render the Sources section."
  (youtube-music--insert-heading "── Sources ──")
  (insert "  /  Search       l  Library (liked / playlists)\n")
  (insert "  u  Play URL     e  Enqueue URL\n")
  (insert "\n"))

(defun youtube-music--render-help ()
  "Render the in-buffer help line."
  (insert (propertize
           "  ? menu   SPC pause  n next  p prev  x stop  f/b seek    g refresh  q bury\n"
           'face 'youtube-music-help)))

;;;; Commands acting on the status buffer

;;;###autoload
(defun youtube-music-play-at-point ()
  "Play the playlist entry at point."
  (interactive)
  (let ((idx (get-text-property (point) 'youtube-music-playlist-index)))
    (if idx (youtube-music--send `("playlist-play-index" ,idx))
      (user-error "No track at point"))))

;;;###autoload
(defun youtube-music-remove-at-point ()
  "Remove the playlist entry at point.
On the Now Playing line, stop playback instead."
  (interactive)
  (let ((idx (get-text-property (point) 'youtube-music-playlist-index)))
    (cond
     (idx (youtube-music--send `("playlist-remove" ,idx)))
     ((get-text-property (point) 'youtube-music-now-playing)
      (youtube-music-stop))
     (t (user-error "Nothing to remove at point")))))

;;;; Playback commands

;;;###autoload
(defun youtube-music-play-url (url)
  "Replace the current playlist with URL and start playing it."
  (interactive "sYouTube URL: ")
  (youtube-music--send `("loadfile" ,url "replace")))

;;;###autoload
(defun youtube-music-enqueue-url (url)
  "Append URL to the mpv playlist."
  (interactive "sYouTube URL: ")
  (youtube-music--send `("loadfile" ,url "append-play")))

;;;###autoload
(defun youtube-music-play-pause ()
  "Toggle play / pause."
  (interactive)
  (youtube-music--send '("cycle" "pause")))

;;;###autoload
(defun youtube-music-play ()
  "Resume playback (un-pause)."
  (interactive)
  (youtube-music--send '("set" "pause" "no")))

;;;###autoload
(defun youtube-music-stop ()
  "Stop playback and clear the playlist."
  (interactive)
  (youtube-music--send '("stop")))

;;;###autoload
(defun youtube-music-toggle-shuffle ()
  "Shuffle (or un-shuffle) the current mpv playlist.
Uses mpv's `playlist-shuffle' / `playlist-unshuffle' commands so
that subsequent `youtube-music-next' calls follow the new order."
  (interactive)
  (cond
   (youtube-music--shuffled-p
    (youtube-music--send '("playlist-unshuffle"))
    (setq youtube-music--shuffled-p nil)
    (message "youtube-music: shuffle off"))
   (t
    (youtube-music--send '("playlist-shuffle"))
    (setq youtube-music--shuffled-p t)
    (message "youtube-music: shuffle on")))
  (youtube-music--rerender))

;;;###autoload
(defun youtube-music-cycle-repeat ()
  "Cycle repeat mode: off → repeat-playlist → repeat-track → off."
  (interactive)
  (let* ((file (plist-get youtube-music--state :loop-file))
         (pl   (plist-get youtube-music--state :loop-playlist))
         (mode (cond
                ((equal file "inf") 'track)
                ((equal pl   "inf") 'playlist)
                (t 'off))))
    (pcase mode
      ('off
       (youtube-music--send '("set" "loop-playlist" "inf"))
       (youtube-music--send '("set" "loop-file" "no"))
       (message "youtube-music: repeat playlist"))
      ('playlist
       (youtube-music--send '("set" "loop-playlist" "no"))
       (youtube-music--send '("set" "loop-file" "inf"))
       (message "youtube-music: repeat track"))
      ('track
       (youtube-music--send '("set" "loop-file" "no"))
       (youtube-music--send '("set" "loop-playlist" "no"))
       (message "youtube-music: repeat off")))))

(defun youtube-music--mode-badges ()
  "Return propertized status badges for shuffle/repeat, or empty string."
  (let* ((file (plist-get youtube-music--state :loop-file))
         (pl   (plist-get youtube-music--state :loop-playlist))
         badges)
    (when youtube-music--shuffled-p (push "🔀" badges))
    (cond
     ((equal file "inf") (push "🔂" badges))
     ((equal pl   "inf") (push "🔁" badges)))
    (if badges (concat "  " (string-join (nreverse badges) " ")) "")))

;;;###autoload
(defun youtube-music-next ()
  "Skip to the next track in the playlist."
  (interactive)
  (youtube-music--send '("playlist-next" "weak")))

;;;###autoload
(defun youtube-music-prev ()
  "Skip to the previous track in the playlist."
  (interactive)
  (youtube-music--send '("playlist-prev" "weak")))

;;;###autoload
(defun youtube-music-seek-forward ()
  "Seek forward by `youtube-music-seek-step' seconds."
  (interactive)
  (youtube-music--send `("seek" ,youtube-music-seek-step "relative")))

;;;###autoload
(defun youtube-music-seek-backward ()
  "Seek backward by `youtube-music-seek-step' seconds."
  (interactive)
  (youtube-music--send `("seek" ,(- youtube-music-seek-step) "relative")))

;;;###autoload
(defun youtube-music-show-log ()
  "Display the buffer containing mpv's stdout/stderr."
  (interactive)
  (let ((buf (get-buffer " *youtube-music-mpv*")))
    (if buf (pop-to-buffer buf)
      (message "youtube-music: no log buffer yet (mpv has not been started)"))))

;;;###autoload
(defun youtube-music-quit ()
  "Stop playback, kill mpv, and clear the mode line."
  (interactive)
  (when (youtube-music--ipc-connected-p) (delete-process youtube-music--ipc-process))
  (when (youtube-music--mpv-running-p)   (delete-process youtube-music--mpv-process))
  (setq youtube-music--ipc-process nil
        youtube-music--mpv-process nil
        youtube-music--mode-line-string ""
        youtube-music--state (list :title nil :pause t :time-pos 0
                                    :duration 0 :playlist-pos -1 :path nil)
        youtube-music--playlist-cache nil)
  (clrhash youtube-music--track-meta)
  (setq youtube-music--liked-set nil)
  (clrhash youtube-music--disliked-set)
  (force-mode-line-update t)
  (youtube-music--rerender))

;;;; Authentication

(defcustom youtube-music-credentials-file
  (let* ((dir (or (getenv "XDG_CONFIG_HOME") "~/.config"))
         (subdir (expand-file-name "youtube-music" dir)))
    (expand-file-name "credentials.eld" subdir))
  "File path for stored credentials.
Use a `.gpg' suffix to have Emacs encrypt the file via EPA.  The
file is created with mode 0600."
  :type 'file)

(defvar youtube-music--cookie nil
  "Cached Cookie header for music.youtube.com API requests.")

(defvar youtube-music--sapisid nil
  "Cached SAPISID value, extracted from the cookie.")

(defun youtube-music--extract-sapisid (cookie)
  "Pluck the SAPISID value out of COOKIE string, or return nil."
  (when (and cookie (string-match "\\bSAPISID=\\([^;]+\\)" cookie))
    (match-string 1 cookie)))

(defun youtube-music--credentials-load ()
  "Read and return the credentials plist from disk, or nil."
  (when (file-readable-p youtube-music-credentials-file)
    (with-temp-buffer
      (insert-file-contents youtube-music-credentials-file)
      (goto-char (point-min))
      (condition-case nil (read (current-buffer)) (error nil)))))

(defun youtube-music--credentials-save (plist)
  "Save PLIST to `youtube-music-credentials-file' with mode 0600."
  (let ((dir (file-name-directory youtube-music-credentials-file)))
    (unless (file-directory-p dir) (make-directory dir t)))
  (with-temp-file youtube-music-credentials-file
    (let ((print-length nil) (print-level nil))
      (prin1 plist (current-buffer))))
  (set-file-modes youtube-music-credentials-file #o600))

(defun youtube-music--auth-load ()
  "Hydrate `youtube-music--cookie' / `youtube-music--sapisid' from disk."
  (unless youtube-music--cookie
    (when-let ((creds (youtube-music--credentials-load)))
      (setq youtube-music--cookie (plist-get creds :cookie)
            youtube-music--sapisid (youtube-music--extract-sapisid
                                    youtube-music--cookie)))))

(defvar-keymap youtube-music-login-mode-map
  :doc "Keymap for `youtube-music-login-mode'."
  "C-c C-c" #'youtube-music-login-finish
  "C-c C-k" #'youtube-music-login-cancel)

(define-derived-mode youtube-music-login-mode text-mode "YT-Login"
  "Major mode for pasting the YouTube Music cookie header.")

(defun youtube-music--logged-in-p ()
  "Return non-nil if a usable cookie is loaded or available on disk."
  (youtube-music--auth-load)
  (and youtube-music--cookie t))

;;;###autoload
(defun youtube-music-login ()
  "Open a buffer for pasting the YouTube Music cookie header.
Press \\<youtube-music-login-mode-map>\\[youtube-music-login-finish] to save, \
\\[youtube-music-login-cancel] to cancel."
  (interactive)
  (let ((buf (get-buffer-create "*youtube-music-login*")))
    (with-current-buffer buf
      (youtube-music-login-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert
         "Paste your YouTube Music Cookie header below the line, then press\n"
         "C-c C-c to save, or C-c C-k to cancel.\n\n"
         "How to obtain it:\n"
         "  1. Open https://music.youtube.com (signed in) in a browser.\n"
         "  2. Open DevTools (F12) and switch to the Network tab.\n"
         "  3. Refresh the page and click any music.youtube.com request.\n"
         "  4. Copy the entire 'Cookie' request header value.\n"
         "  5. Make sure it contains 'SAPISID=...'.\n"
         "----------------------------------------------------------------\n"))
      (goto-char (point-max)))
    (pop-to-buffer buf)))

(defun youtube-music-login-finish ()
  "Save the cookie pasted in the current login buffer."
  (interactive)
  (goto-char (point-min))
  (unless (re-search-forward "^-+\n" nil t)
    (user-error "Login buffer is malformed"))
  (let ((cookie (string-trim
                 (buffer-substring-no-properties (point) (point-max)))))
    (cond
     ((string-empty-p cookie)
      (user-error "Cookie is empty; paste it after the line and try again"))
     ((not (youtube-music--extract-sapisid cookie))
      (user-error "Pasted text has no SAPISID=... entry; copy a fresh cookie"))
     (t
      (youtube-music--credentials-save (list :cookie cookie))
      (setq youtube-music--cookie cookie
            youtube-music--sapisid (youtube-music--extract-sapisid cookie))
      (message "youtube-music: logged in (cookie saved to %s)"
               youtube-music-credentials-file)
      (kill-buffer (current-buffer))))))

(defun youtube-music-login-cancel ()
  "Cancel the login and discard the buffer."
  (interactive)
  (kill-buffer (current-buffer)))

;;;###autoload
(defun youtube-music-logout ()
  "Forget the saved YouTube Music credentials.
Deletes `youtube-music-credentials-file' and clears in-memory cookie."
  (interactive)
  (when (file-exists-p youtube-music-credentials-file)
    (delete-file youtube-music-credentials-file))
  (setq youtube-music--cookie nil
        youtube-music--sapisid nil)
  (message "youtube-music: logged out"))

;;;###autoload
(defun youtube-music-auth-status ()
  "Echo whether the user is currently logged in."
  (interactive)
  (message "youtube-music: %s"
           (if (youtube-music--logged-in-p) "logged in" "logged out")))

(defun youtube-music--auth-header ()
  "Return the dynamic header for `youtube-music-auth'."
  (propertize
   (if (youtube-music--logged-in-p)
       "youtube-music auth — logged in"
     "youtube-music auth — logged out")
   'face 'transient-heading))

;;;###autoload (autoload 'youtube-music-auth "youtube-music" nil t)
(transient-define-prefix youtube-music-auth ()
  "Manage YouTube Music authentication."
  :description #'youtube-music--auth-header
  ["Authentication"
   ("l" "Login (paste cookie)" youtube-music-login)
   ("o" "Logout"               youtube-music-logout)
   ("s" "Status"               youtube-music-auth-status :transient t)])

;;;; YouTube Music HTTP client

(defcustom youtube-music-client-version "1.20250101.01.00"
  "Client version string sent in the WEB_REMIX context.
Bump this when YouTube changes the wire protocol."
  :type 'string)

(defcustom youtube-music-user-agent
  (concat "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
          "Chrome/120.0.0.0 Safari/537.36")
  "User-Agent string sent with API requests."
  :type 'string)

(defconst youtube-music--api-base "https://music.youtube.com/youtubei/v1"
  "Base URL for the WEB_REMIX internal API.")

(defconst youtube-music--api-origin "https://music.youtube.com"
  "Origin header value for API requests.")

(defun youtube-music--sapisid-hash (sapisid origin)
  "Build the `Authorization: SAPISIDHASH ...' value.
SAPISID is the SAPISID cookie value; ORIGIN is the request origin."
  (let* ((ts (number-to-string (truncate (float-time))))
         (digest (secure-hash 'sha1 (format "%s %s %s" ts sapisid origin))))
    (format "SAPISIDHASH %s_%s" ts digest)))

(defun youtube-music--youtubei-post (endpoint body callback &optional extra-query)
  "POST BODY (an alist) to ENDPOINT under `youtube-music--api-base'.
Calls CALLBACK with the parsed response plist (or nil on error).
EXTRA-QUERY, if non-nil, is appended to the URL query string."
  (youtube-music--auth-load)
  (unless youtube-music--cookie
    (user-error "Not logged in; run `M-x youtube-music-login' first"))
  (let* ((url (concat youtube-music--api-base "/" endpoint
                      "?prettyPrint=false"
                      (if extra-query (concat "&" extra-query) "")))
         (full-body
          (cons `(context . ((client . ((clientName . "WEB_REMIX")
                                         (clientVersion . ,youtube-music-client-version)
                                         (hl . "en")
                                         (gl . "US")))))
                body))
         (json-body (json-encode full-body))
         (auth (youtube-music--sapisid-hash
                youtube-music--sapisid
                youtube-music--api-origin))
         (url-request-method "POST")
         (url-request-extra-headers
          `(("User-Agent" . ,youtube-music-user-agent)
            ("Cookie" . ,youtube-music--cookie)
            ("Authorization" . ,auth)
            ("X-Origin" . ,youtube-music--api-origin)
            ("X-Goog-AuthUser" . "0")
            ("Origin" . ,youtube-music--api-origin)
            ("Content-Type" . "application/json; charset=UTF-8")
            ("Accept" . "*/*")))
         (url-request-data (encode-coding-string json-body 'utf-8)))
    (url-retrieve url
                  (lambda (status)
                    (condition-case nil
                        (funcall callback
                                 (youtube-music--read-response status))
                      (quit nil)))
                  nil t t)))

(defun youtube-music--read-response (status)
  "Extract and parse the JSON body from the current `url-retrieve' buffer.
STATUS is the plist passed by `url-retrieve' to its callback."
  (let ((buf (current-buffer))
        body data)
    (when (plist-get status :error)
      (message "youtube-music: HTTP error: %S" (plist-get status :error)))
    (goto-char (point-min))
    (when (re-search-forward "\r?\n\r?\n" nil t)
      (setq body (buffer-substring-no-properties (point) (point-max))))
    (kill-buffer buf)
    (when (and body (> (length (string-trim body)) 0))
      (condition-case err
          (setq data (json-parse-string body :object-type 'plist :null-object nil))
        (error (message "youtube-music: parse error: %S" err))))
    data))

;;;; API response parsers

(defun youtube-music--get-in (obj path)
  "Walk PATH (a vector of keys/indices) into OBJ; return nil on miss.
Symbol/keyword keys go through `plist-get'; integer keys index vectors."
  (let ((cur obj))
    (cl-loop for key across path
             while cur
             do (setq cur
                      (cond
                       ((and (vectorp cur) (numberp key) (< key (length cur)))
                        (aref cur key))
                       ((listp cur) (plist-get cur key))
                       (t nil))))
    cur))

(defun youtube-music--flex-text (col)
  "Concatenate text from each run in a flex COL of `musicResponsiveListItem'."
  (let ((runs (youtube-music--get-in
               col [:musicResponsiveListItemFlexColumnRenderer :text :runs])))
    (when runs
      (mapconcat (lambda (r) (or (plist-get r :text) "")) runs ""))))

(defun youtube-music--parse-list-item (item)
  "Parse a `musicResponsiveListItemRenderer' ITEM into a result plist.
Returns plist with :title, :subtitle, :video-id, or nil on miss."
  (when-let ((mrli (plist-get item :musicResponsiveListItemRenderer)))
    (let* ((flex (plist-get mrli :flexColumns))
           (title (when (and flex (> (length flex) 0))
                    (youtube-music--flex-text (aref flex 0))))
           (subtitle (when (and flex (> (length flex) 1))
                       (youtube-music--flex-text (aref flex 1))))
           (video-id
            (or (youtube-music--get-in mrli [:playlistItemData :videoId])
                (and flex (> (length flex) 0)
                     (let ((runs (youtube-music--get-in
                                  (aref flex 0)
                                  [:musicResponsiveListItemFlexColumnRenderer
                                   :text :runs])))
                       (when (and runs (> (length runs) 0))
                         (youtube-music--get-in
                          (aref runs 0)
                          [:navigationEndpoint :watchEndpoint :videoId])))))))
      (when (and title video-id)
        (list :title title :subtitle (or subtitle "") :video-id video-id)))))

(defun youtube-music--parse-search-results (response)
  "Extract a list of song result plists from search RESPONSE."
  (let ((tabs (youtube-music--get-in
               response [:contents :tabbedSearchResultsRenderer :tabs])))
    (when (and tabs (> (length tabs) 0))
      (let* ((tab (aref tabs 0))
             (sections (youtube-music--get-in
                        tab [:tabRenderer :content
                             :sectionListRenderer :contents]))
             results)
        (when sections
          (cl-loop
           for section across sections
           for shelf = (plist-get section :musicShelfRenderer)
           when shelf
           do (cl-loop
               for entry across (plist-get shelf :contents)
               for parsed = (youtube-music--parse-list-item entry)
               when parsed do (push parsed results))))
        (nreverse results)))))

;;;; Search command

(defconst youtube-music--search-songs-params
  "EgWKAQIIAWoMEA4QChADEAQQCRAF"
  "Search-params blob restricting results to songs.")

(defun youtube-music--prompt-and-act (entries enqueue)
  "Prompt the user to pick from ENTRIES and play (or ENQUEUE) the chosen.
When ENQUEUE is non-nil the chosen track is appended to mpv's
playlist; otherwise it replaces it."
  (let* ((labels (mapcar (lambda (e)
                           (cons (format "%s — %s"
                                         (plist-get e :title)
                                         (plist-get e :subtitle))
                                 e))
                         entries))
         (prompt (if enqueue "Enqueue: " "Play: "))
         (choice (completing-read prompt labels nil t))
         (entry (cdr (assoc choice labels))))
    (when entry
      (youtube-music--remember-tracks (list entry))
      (let ((url (format "https://music.youtube.com/watch?v=%s"
                         (plist-get entry :video-id))))
        (if enqueue
            (youtube-music-enqueue-url url)
          (youtube-music-play-url url))))))

;;;###autoload
(defun youtube-music-search (query &optional enqueue)
  "Search YouTube Music for QUERY and offer to play a result.
With a prefix argument, ENQUEUE the chosen result instead of
replacing the current playlist."
  (interactive (list (read-string "Search YouTube Music: ")
                     current-prefix-arg))
  (message "youtube-music: searching for %s..." query)
  (youtube-music--youtubei-post
   "search"
   `((query . ,query) (params . ,youtube-music--search-songs-params))
   (lambda (response)
     (let ((results (youtube-music--parse-search-results response)))
       (cond
        ((null results) (message "youtube-music: no results for %s" query))
        (t (youtube-music--prompt-and-act results enqueue)))))))

;;;###autoload
(defun youtube-music-search-enqueue (query)
  "Search YouTube Music for QUERY and append the chosen result to the queue."
  (interactive "sEnqueue from YouTube Music: ")
  (youtube-music-search query t))

;;;; Library browse — parsers

(defun youtube-music--browse-section-list (response)
  "Walk RESPONSE down to its sectionListRenderer.contents vector, or nil."
  (or (youtube-music--get-in
       response [:contents :singleColumnBrowseResultsRenderer
                 :tabs 0 :tabRenderer :content
                 :sectionListRenderer :contents])
      (youtube-music--get-in
       response [:contents :twoColumnBrowseResultsRenderer
                 :tabs 0 :tabRenderer :content
                 :sectionListRenderer :contents])))

(defun youtube-music--parse-track-shelf (response)
  "Extract a list of track plists from a browse RESPONSE.
Handles both `musicPlaylistShelfRenderer' and `musicShelfRenderer'
section content."
  (let ((sections (youtube-music--browse-section-list response))
        results)
    (when sections
      (cl-loop
       for section across sections
       for shelf-contents = (or (youtube-music--get-in
                                 section [:musicPlaylistShelfRenderer :contents])
                                (youtube-music--get-in
                                 section [:musicShelfRenderer :contents]))
       when shelf-contents
       do (cl-loop
           for entry across shelf-contents
           for parsed = (youtube-music--parse-list-item entry)
           when parsed do (push parsed results))))
    (nreverse results)))

(defun youtube-music--shelf-continuation-token (response)
  "Return a continuation token from a browse RESPONSE, or nil.
Looks at `musicPlaylistShelfRenderer' and `musicShelfRenderer'
shelves under the section list."
  (let ((sections (youtube-music--browse-section-list response)))
    (cl-loop
     for section across (or sections [])
     for shelf = (or (plist-get section :musicPlaylistShelfRenderer)
                     (plist-get section :musicShelfRenderer))
     when shelf
     for tok = (youtube-music--get-in
                shelf [:continuations 0 :nextContinuationData :continuation])
     when tok return tok)))

(defun youtube-music--parse-track-continuation (response)
  "Parse a continuation RESPONSE returned by a `?continuation=...' POST.
Returns plist (:tracks LIST :next TOKEN-OR-NIL)."
  (let* ((cc (plist-get response :continuationContents))
         (shelf (or (plist-get cc :musicPlaylistShelfContinuation)
                    (plist-get cc :musicShelfContinuation)))
         (contents (and shelf (plist-get shelf :contents)))
         (next (and shelf (youtube-music--get-in
                           shelf [:continuations 0 :nextContinuationData
                                  :continuation])))
         results)
    (when contents
      (cl-loop for entry across contents
               for parsed = (youtube-music--parse-list-item entry)
               when parsed do (push parsed results)))
    (list :tracks (nreverse results) :next next)))

(defun youtube-music--fetch-all-tracks (endpoint body token tracks-so-far on-done)
  "Recursively follow continuations and gather all tracks.
ENDPOINT and BODY are passed to `youtube-music--youtubei-post'.
TOKEN is the next continuation token, or nil if we are done.
TRACKS-SO-FAR accumulates results; ON-DONE is called once with
the final list."
  (cond
   ((null token) (funcall on-done tracks-so-far))
   (t
    (let ((extra (format "ctoken=%s&continuation=%s&type=next"
                         (url-hexify-string token)
                         (url-hexify-string token))))
      (youtube-music--youtubei-post
       endpoint body
       (lambda (response)
         (let* ((parsed (youtube-music--parse-track-continuation response))
                (more (plist-get parsed :tracks))
                (next (plist-get parsed :next)))
           (youtube-music--fetch-all-tracks
            endpoint body next
            (append tracks-so-far more)
            on-done)))
       extra)))))

(defun youtube-music--parse-playlist-tile (item)
  "Parse a `musicTwoRowItemRenderer' ITEM into (TITLE . BROWSE-ID), or nil."
  (when-let ((tri (plist-get item :musicTwoRowItemRenderer)))
    (let* ((runs (youtube-music--get-in tri [:title :runs]))
           (title (when (and runs (> (length runs) 0))
                    (plist-get (aref runs 0) :text)))
           (browse-id (youtube-music--get-in
                       tri [:navigationEndpoint :browseEndpoint :browseId])))
      (when (and title browse-id)
        (cons title browse-id)))))

(defun youtube-music--parse-playlist-shelf (response)
  "Parse RESPONSE into a list of (TITLE . BROWSE-ID) library playlists."
  (let ((sections (youtube-music--browse-section-list response))
        results)
    (when sections
      (cl-loop
       for section across sections
       for grid = (plist-get section :gridRenderer)
       when grid
       do (cl-loop
           for entry across (plist-get grid :items)
           for parsed = (youtube-music--parse-playlist-tile entry)
           when parsed do (push parsed results))))
    (nreverse results)))

;;;; Library browse — commands

(defun youtube-music--video-id-from-url (url)
  "Return the videoId from a YouTube/YT-Music watch URL, or nil."
  (when (and (stringp url)
             (string-match "[?&]v=\\([A-Za-z0-9_-]+\\)" url))
    (match-string 1 url)))

(defun youtube-music--remember-tracks (tracks)
  "Cache title/subtitle metadata for TRACKS keyed by videoId."
  (dolist (tr tracks)
    (let ((vid (plist-get tr :video-id)))
      (when vid
        (puthash vid
                 (list :title (plist-get tr :title)
                       :subtitle (plist-get tr :subtitle))
                 youtube-music--track-meta)))))

(defun youtube-music--display-title-for (url-or-path mpv-title)
  "Pick the best display string for a track.
URL-OR-PATH is the queued URL; MPV-TITLE is mpv's `media-title'.
Falls back to URL-OR-PATH if neither yields anything useful."
  (let* ((vid (youtube-music--video-id-from-url url-or-path))
         (meta (and vid (gethash vid youtube-music--track-meta))))
    (cond
     (meta (let ((sub (plist-get meta :subtitle)))
             (if (and sub (> (length sub) 0))
                 (format "%s — %s" (plist-get meta :title) sub)
               (plist-get meta :title))))
     ((and mpv-title (> (length mpv-title) 0)
           (not (equal mpv-title url-or-path)))
      mpv-title)
     (t (or url-or-path "")))))

(defun youtube-music--play-tracks (tracks)
  "Replace mpv's playlist with TRACKS (list of result plists)."
  (youtube-music--remember-tracks tracks)
  (setq youtube-music--shuffled-p nil)
  (cl-loop for tr in tracks
           for first = t then nil
           do (youtube-music--send
               `("loadfile"
                 ,(format "https://music.youtube.com/watch?v=%s"
                          (plist-get tr :video-id))
                 ,(if first "replace" "append")))))

(defun youtube-music--play-playlist-by-browse-id (browse-id)
  "Fetch the playlist with BROWSE-ID (paginated) and play its tracks."
  (message "youtube-music: loading playlist...")
  (youtube-music--fetch-all-from-browse-id
   browse-id
   (lambda (tracks)
     (cond
      ((null tracks) (message "youtube-music: empty or unparseable playlist"))
      (t (youtube-music--play-tracks tracks)
         (message "youtube-music: queued %d tracks" (length tracks)))))))

(defun youtube-music--populate-liked-set (tracks)
  "Replace `youtube-music--liked-set' with the videoIds from TRACKS."
  (setq youtube-music--liked-set (make-hash-table :test 'equal))
  (dolist (tr tracks)
    (when-let ((vid (plist-get tr :video-id)))
      (puthash vid t youtube-music--liked-set))))

(defun youtube-music--fetch-all-from-browse-id (browse-id on-done)
  "Fetch every track from BROWSE-ID, following continuations.
Calls ON-DONE with the full list once continuations are exhausted."
  (let ((body `((browseId . ,browse-id))))
    (youtube-music--youtubei-post
     "browse" body
     (lambda (response)
       (let ((tracks (youtube-music--parse-track-shelf response))
             (token  (youtube-music--shelf-continuation-token response)))
         (youtube-music--fetch-all-tracks
          "browse" body token tracks on-done))))))

;;;###autoload
(defun youtube-music-refresh-liked-set ()
  "Fetch the user's liked-songs list (paginated) to refresh the liked set.
This is what powers the thumbs-up indicator on tracks."
  (interactive)
  (message "youtube-music: refreshing liked set...")
  (youtube-music--fetch-all-from-browse-id
   "FEmusic_liked_videos"
   (lambda (tracks)
     (cond
      ((null tracks) (message "youtube-music: no liked songs"))
      (t (youtube-music--populate-liked-set tracks)
         (youtube-music--rerender)
         (message "youtube-music: refreshed liked set (%d entries)"
                  (length tracks)))))))

;;;###autoload
(defun youtube-music-liked ()
  "Play your YouTube Music liked-songs list (all pages)."
  (interactive)
  (message "youtube-music: fetching liked songs...")
  (youtube-music--fetch-all-from-browse-id
   "FEmusic_liked_videos"
   (lambda (tracks)
     (cond
      ((null tracks) (message "youtube-music: no liked songs"))
      (t (youtube-music--populate-liked-set tracks)
         (youtube-music--play-tracks tracks)
         (message "youtube-music: queued %d tracks" (length tracks)))))))

;;;###autoload
(defun youtube-music-library-playlists ()
  "Pick one of your YouTube Music library playlists and play it."
  (interactive)
  (message "youtube-music: fetching your playlists...")
  (youtube-music--youtubei-post
   "browse"
   '((browseId . "FEmusic_liked_playlists"))
   (lambda (response)
     (let ((entries (youtube-music--parse-playlist-shelf response)))
       (cond
        ((null entries) (message "youtube-music: no playlists found"))
        (t (let* ((choice (completing-read "Playlist: " entries nil t))
                  (browse-id (cdr (assoc choice entries))))
             (when browse-id
               (youtube-music--play-playlist-by-browse-id browse-id)))))))))

;;;###autoload (autoload 'youtube-music-library "youtube-music" nil t)
(transient-define-prefix youtube-music-library ()
  "Browse your YouTube Music library."
  ["Library"
   ("l" "Liked songs"          youtube-music-liked)
   ("p" "Playlists"            youtube-music-library-playlists)])

;;;; Like / dislike the current track

(defun youtube-music--current-video-id ()
  "Return the videoId of the track currently loaded in mpv, or nil."
  (let ((path (plist-get youtube-music--state :path)))
    (or (youtube-music--video-id-from-url path)
        (let* ((cur (plist-get youtube-music--state :playlist-pos))
               (items youtube-music--playlist-cache)
               (entry (and cur items (>= cur 0) (< cur (length items))
                           (nth cur items)))
               (filename (and entry (plist-get entry :filename))))
          (and filename (youtube-music--video-id-from-url filename))))))

(defun youtube-music--video-id-at-point-or-current ()
  "Return the videoId DWIM at point, or for the currently playing track.
If point is on a queue entry, return that entry's videoId.
Otherwise, return whatever is currently playing."
  (or (let ((idx (get-text-property (point) 'youtube-music-playlist-index)))
        (when (and idx youtube-music--playlist-cache
                   (>= idx 0) (< idx (length youtube-music--playlist-cache)))
          (youtube-music--video-id-from-url
           (plist-get (nth idx youtube-music--playlist-cache) :filename))))
      (youtube-music--current-video-id)))

(defun youtube-music--display-title-from-vid (vid)
  "Return the cached \"Title — Subtitle\" for VID, or nil."
  (when-let ((meta (gethash vid youtube-music--track-meta)))
    (let ((sub (plist-get meta :subtitle)))
      (if (and sub (not (string-empty-p sub)))
          (format "%s — %s" (plist-get meta :title) sub)
        (plist-get meta :title)))))

(defun youtube-music--update-rating-state (vid new-state)
  "Update liked-set and disliked-set for VID moving to NEW-STATE.
NEW-STATE is one of `like', `dislike', `none'."
  (when youtube-music--liked-set
    (if (eq new-state 'like)
        (puthash vid t youtube-music--liked-set)
      (remhash vid youtube-music--liked-set)))
  (if (eq new-state 'dislike)
      (puthash vid t youtube-music--disliked-set)
    (remhash vid youtube-music--disliked-set)))

(defun youtube-music--rate-track (endpoint verb new-state)
  "POST to ENDPOINT for the DWIM videoId; VERB names the action.
ENDPOINT is e.g. \"like/like\".  VERB is shown in user messages.
NEW-STATE is one of `like', `dislike', `none'.  The target is the
track at point in the queue, or the currently playing track."
  (let ((vid (youtube-music--video-id-at-point-or-current)))
    (cond
     ((null vid) (user-error "No track at point and nothing playing"))
     (t
      (youtube-music--youtubei-post
       endpoint
       `((target . ((videoId . ,vid))))
       (lambda (_response)
         (youtube-music--update-rating-state vid new-state)
         (youtube-music--rerender)
         (message "youtube-music: %sd \"%s\""
                  verb
                  (or (youtube-music--display-title-from-vid vid) vid))))))))

;;;###autoload
(defun youtube-music-like ()
  "Thumbs-up the currently playing track."
  (interactive)
  (youtube-music--rate-track "like/like" "like" 'like))

;;;###autoload
(defun youtube-music-dislike ()
  "Thumbs-down the currently playing track."
  (interactive)
  (youtube-music--rate-track "like/dislike" "dislike" 'dislike))

;;;###autoload
(defun youtube-music-unrate ()
  "Clear thumbs-up/down for the currently playing track."
  (interactive)
  (youtube-music--rate-track "like/removelike" "unrate" 'none))

(defun youtube-music--rating-glyph-for (vid)
  "Return a propertized thumbs-up/down glyph for VID, or nil."
  (cond
   ((null vid) nil)
   ((and youtube-music--liked-set
         (gethash vid youtube-music--liked-set))
    (propertize "👍" 'face 'youtube-music-thumbs-up))
   ((gethash vid youtube-music--disliked-set)
    (propertize "👎" 'face 'youtube-music-thumbs-down))
   (t nil)))

(defun youtube-music--current-rating-glyph ()
  "Return the rating glyph for the currently-playing track, or nil."
  (youtube-music--rating-glyph-for (youtube-music--current-video-id)))

;;;; Status-buffer transient menu

(defun youtube-music--dispatch-header ()
  "Return the dynamic header for `youtube-music-dispatch'."
  (let ((title (plist-get youtube-music--state :title))
        (path  (plist-get youtube-music--state :path))
        (pause (plist-get youtube-music--state :pause))
        (pos   (plist-get youtube-music--state :time-pos))
        (dur   (plist-get youtube-music--state :duration)))
    (propertize
     (cond
      ((or title path)
       (format "%s %s   %s / %s"
               (if pause "⏸" "▶")
               (youtube-music--display-title-for path title)
               (youtube-music--format-time pos)
               (youtube-music--format-time dur)))
      (t "youtube-music — nothing playing"))
     'face 'transient-heading)))

;; No autoload; the only entry point is `?' / `h' inside
;; `youtube-music-mode'.
(transient-define-prefix youtube-music-dispatch ()
  "Show available YouTube Music commands.
This transient is invoked from the status buffer via `?' or `h'."
  :description #'youtube-music--dispatch-header
  ["Browse"
   [("s" "Search (enqueue)" youtube-music-search-enqueue)
    ("S" "Search (replace)" youtube-music-search)
    ("l" "Library"          youtube-music-library)
    ("u" "Play URL"         youtube-music-play-url)
    ("e" "Enqueue URL"      youtube-music-enqueue-url)]
   [("a" "Auth"             youtube-music-auth)
    ("L" "Show mpv log"     youtube-music-show-log)
    ("Q" "Quit (kill mpv)"  youtube-music-quit)]]
  ["Playback"
   [("SPC" "Play / pause"   youtube-music-play-pause   :transient t)
    ("n"   "Next track"     youtube-music-next         :transient t)
    ("p"   "Previous track" youtube-music-prev         :transient t)
    ("x"   "Stop"           youtube-music-stop         :transient t)]
   [("f"   "Seek +5s"       youtube-music-seek-forward  :transient t)
    ("b"   "Seek -5s"       youtube-music-seek-backward :transient t)]
   [("+"   "Like"           youtube-music-like          :transient t)
    ("-"   "Dislike"        youtube-music-dislike       :transient t)
    ("="   "Unrate"         youtube-music-unrate        :transient t)]
   [("z"   "Shuffle"        youtube-music-toggle-shuffle :transient t)
    ("r"   "Repeat (cycle)" youtube-music-cycle-repeat   :transient t)]]
  ["Buffer"
   :if-derived youtube-music-mode
   [("g"        "       Refresh"                youtube-music-refresh)
    ("q"        "       Bury buffer"            quit-window)
    ("<return>" "Play track at point"           youtube-music-play-at-point)
    ("k"        "       Remove / stop at point" youtube-music-remove-at-point)]
   [("C-h m"    "       Show all key bindings"  describe-mode)]])


(provide 'youtube-music)
;;; youtube-music.el ends here
