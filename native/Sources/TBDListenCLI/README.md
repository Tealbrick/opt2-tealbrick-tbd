# tbd-listen

Command-line access to TBD Listening: transcribe files, links and podcast episodes, query the
library, manage models, engines, vocabulary, snippets and preferences. It shares the library
(`~/Library/Application Support/com.tealbrick.desktop/Listening`) and the preferences (`com.tealbrick.desktop`) with
the TBD app. Nothing leaves the Mac except: model downloads you ask for (`models download`),
podcast lookups (iTunes Search/Lookup API, the show's RSS feed, the episode audio) and links you
give to `transcribe`.

Environment: `TBD_LISTENING_ROOT` moves the whole Listening folder (tests, tooling);
`TBD_LISTENING_MODELS` moves only the models folder.

## Commands

| Command | What it does |
| --- | --- |
| `transcribe INPUT [--podcast] [--engine ID] [--language XX] [--format txt\|md\|srt\|vtt\|json] [--json] [--no-save] [--keep-audio] [--media-audio-quality app-default\|m4a\|best-available]` | Transcribe a file, an http(s) link (Apple Podcasts links and direct audio files download directly; other pages use `yt-dlp`, which TBD downloads from the official GitHub release, verifies against its SHA2-256SUMS and keeps in Listening/bin, refreshed weekly) or, with `--podcast`, a podcast search such as `"hard fork 120"`. Uses the app's **final** engine unless `--engine` is given. |
| `search WORDS [--kind file\|url\|meeting\|voiceNote] [--limit N] [--json]` | Full-text search of transcripts. |
| `show ID [--format …]` | Print one transcript (id or unique prefix). |
| `history [--limit N] [--query WORDS] [--json]` | Recent dictations. |
| `meetings [--limit N] [--json]` | Recorded meetings. |
| `export ID [--format …] [-o FILE\|DIR]` | Write a transcript to a file (a directory gets `<title>.<format>`) or stdout. Formats: txt, md, srt, vtt, json, dapt; with `-o` also docx and pdf. |
| `delete ID --yes [--dictation] [--json]` | Delete a transcript (or dictation) and its audio inside the Listening folder. Your own source files are never deleted. |
| `stats [--json]` | Dictation and library statistics, storage use. |
| `engines list [--json]` | Engines with capabilities, download state and which one is live/final. |
| `models list\|status [--json]` | Models with size and state; routes and readiness. Never downloads. |
| `models download ID [--json]` | Download a model now. |
| `models delete ID --yes [--json]` | Delete a model's files. |
| `vocabulary list\|add WORD [--replacement TEXT]\|remove WORD-OR-ID [--json]` | Custom words applied to every transcript. |
| `snippets list\|add TRIGGER EXPANSION\|remove TRIGGER-OR-ID [--json]` | Dictation snippets. |
| `podcasts search WORDS [--limit N] [--json]` | Search shows in the Apple Podcasts directory. |
| `podcasts resolve LINK-OR-WORDS [--json]` | Show which episode a link or search resolves to, without downloading. |
| `config show\|get KEY\|set KEY VALUE [--json]` | Listening preferences shared with the app. |

Engine ids: `parakeet-v3` (default), `parakeet-v2`, `parakeet-unified`, `nemotron-multilingual`,
`nemotron-english`, `cohere-transcribe`, `whisper-large-v3-turbo`. Model ids are the engine ids plus
`speaker-detection` and `vad`. Short aliases (`parakeet`, `nemotron`, `cohere`, `whisper`) work too.

Config keys: `liveEngine`, `finalEngine` (`default`/`live` = follow the live engine),
`whisperLanguage`, `nemotronLanguage`, `cohereLanguage` (`auto`/`default` clears), `dictationLivePreview`,
`meetingLivePreview`, `keepAudio`, `keepHistory`, `removeFillers`, `dictationCleanup`, `diarize`,
`calendarReminders`, `calendarAutoStart`, `dictationHotkey`, `transformHotkey`, `microphoneUID`,
`youtubeAudioQuality` (`m4a` default, or `best-available`, which needs FFmpeg).
`keepAudio` reflects the per-kind retention policies in Settings (true: no kind removes audio after
transcription); setting it switches those policies and leaves day-based expiry as it is.

Exit status is non-zero on any error; messages go to stderr, results to stdout.

## JSON contract

All `--json` output is pretty-printed with **sorted keys**, ISO 8601 dates, durations and times in
milliseconds, and **nil values present as `null`**. Fields are only ever added; existing keys are
never renamed or removed. Objects that carry `schemaVersion` are at version `1`.

- `transcribe --json` → `{schemaVersion, id, file, text, durationMs, language, engine, speakers, segments, words}`;
  `id` is `null` with `--no-save`; `file` is the path, or the source URL for links and podcasts.
- `transcribe --format json`, `show --format json`, `export --format json` → transcript detail
  `{schemaVersion, id, title, kind, status, createdAt, durationMs, language, engine, sourcePath, sourceURL, text, rawText, cleanText, speakers, segments, words, audioPaths, summaries, error}`.
- `search`, `meetings` → `[{id, title, kind, status, createdAt, durationMs, language, engine, preview}]`.
- `history` → `[{id, createdAt, durationMs, text, rawText, targetApp, wordCount}]`.
- segment `{start, end, speaker, text}`; word `{start, end, speaker, text, confidence}`.
- `engines list` → `[{id, cliID, name, model, summary, languageMode, defaultLanguage, languages, wordTimestamps, streaming, livePreview, diarization, meetingLivePreview, approximateBytes, minimumMemoryBytes, memoryOK, downloaded, live, final}]`.
  `languageMode` is `automatic`, `fixed` or `selectable`; `languages` is `null` when the engine covers too many to list.
- `models list`, `models download`, `models delete` → `{id, model, title, engine, downloaded, bytes, approximateBytes, path}` (a list for `list`).
- `models status` → `{schemaVersion, liveEngine, finalEngine, liveReady, finalReady, vadReady, speakerDetectionReady, totalBytes, modelsPath, models}`.
- `stats` → `{schemaVersion, dictations, dictationWords, dictationDurationMs, dictationsToday, wordsPerMinute, transcriptions, transcriptionsByKind, transcriptionDurationMs, modelsBytes, storageBytes}`.
- `vocabulary …` → `{id, word, replacement, enabled}` (a list for `list`).
- `snippets …` → `{id, trigger, expansion, enabled, useCount}` (a list for `list`).
- `delete` → `{id, kind, deleted, removedFiles}`.
- `podcasts search` → `[{name, feedURL, collectionID}]`; `podcasts resolve` → `{audioURL, title, show, summary, durationSeconds, releaseDate, feedURL}` (absent values omitted).
- `config show` → `{<key>: value}` (string, boolean or `null` for default); `config get|set` → `{key, value}`.

The shapes are pinned by `ListenJSONTests` and `ListenCLITests` in `native/Tests/TBDSpeechTests`.
