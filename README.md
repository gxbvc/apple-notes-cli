# apple-notes

CLI for Apple Notes on macOS. CRUD and search from the command line.

- **Read operations** (list, show, search, folders) use direct SQLite queries for speed (~50ms)
- **Write operations** (create, update, delete) use AppleScript via `osascript`

## Requirements

- macOS with Full Disk Access granted to your terminal (for reading the Notes SQLite database)
- Ruby (via rbenv or system)
- Notes.app (for write operations via AppleScript)

## Setup

```bash
cd ~/tools/apple-notes
bundle install
ln -sf ~/tools/apple-notes/apple-notes ~/bin/apple-notes
```

## Usage

### List folders

```bash
apple-notes folders
```

### List recent notes

```bash
apple-notes list                           # 20 most recent notes
apple-notes list --limit 10                # Limit results
apple-notes list --folder "Blog posts"     # Filter by folder
```

### Show a note

```bash
apple-notes show 1214                      # By numeric ID (plaintext body)
apple-notes show 1214 --html               # Get HTML body instead
```

### Search notes

Full-text search across titles and note bodies. Uses SQLite for speed (~60ms for 400+ notes).

```bash
apple-notes search "grocery"               # Search all notes
apple-notes search "grocery" --limit 5     # Limit results
apple-notes search "trip" --folder "Notes"  # Search within a folder
```

### Create a note

```bash
apple-notes create "My Title"                                  # Empty note
apple-notes create "My Title" --body "Some text content"       # With plain text body
apple-notes create "My Title" --html "<div><b>Rich</b></div>"  # With HTML body
apple-notes create "My Title" --body "Text" --folder "Blog posts"  # In a specific folder
```

### Update a note

```bash
apple-notes update 1214 --body "Replaced body"         # Replace body (plain text)
apple-notes update 1214 --html "<div>New HTML</div>"    # Replace body (HTML)
apple-notes update 1214 --append "More text at the end" # Append to existing body
apple-notes update 1214 --name "New Title"              # Rename
apple-notes update 1214 --name "New" --append "More"    # Combine operations
```

### Delete a note

Moves the note to Recently Deleted (same as deleting in Notes.app).

```bash
apple-notes delete 1214
```

## Note IDs

Notes are identified by their numeric SQLite primary key (e.g., `1214`). You can also use the full CoreData URI:

```
x-coredata://B9669079-92D2-48C1-91ED-8D55A8441D00/ICNote/p1214
```

Both formats are accepted for `show`, `update`, and `delete` commands.

## Output

All commands output JSON to stdout:

```json
{"ok":true,"data":{"notes":[...],"count":3}}
```

Errors:

```json
{"ok":false,"error":"Note 999999 not found","code":"ERROR"}
```

## How it works

- **Reading**: Direct SQLite queries against `~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite` (read-only). Note bodies are gzipped protobufs; the `show` command uses AppleScript `plaintext` for accurate body extraction.
- **Searching**: SQLite for title/snippet matching, with gzip decompression for full-body search (~60ms for 400+ notes).
- **Writing**: AppleScript via `osascript` to Notes.app. Notes.app will briefly activate on write operations.

## Tests

```bash
bundle exec ruby test/test_notes_db.rb      # Unit + SQLite integration tests
bundle exec ruby test/test_notes_apple.rb    # AppleScript integration tests (creates/deletes real notes)
bundle exec ruby test/test_cli.rb            # End-to-end CLI tests
```
