# apple-notes

CLI for Apple Notes on macOS. CRUD and search via SQLite (reads) and AppleScript (writes).

```bash
apple-notes folders                                    # List all folders
apple-notes list [--limit 20] [--folder NAME]          # List recent notes
apple-notes show <ID> [--html]                         # Show full note content
apple-notes search <query> [--limit 20] [--folder NAME]  # Full-text search
apple-notes create "Title" [--body TEXT] [--html HTML] [--folder NAME]
apple-notes update <ID> [--body TEXT] [--html HTML] [--append TEXT] [--name TITLE]
apple-notes delete <ID>                                # Move to Recently Deleted
```

ID is a numeric SQLite primary key (e.g. `1214`) or full CoreData URI. Output is JSON to stdout.
No credentials needed — reads local SQLite DB, writes via AppleScript.
