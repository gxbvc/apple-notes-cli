# frozen_string_literal: true

require 'sqlite3'
require 'zlib'
require 'stringio'
require 'time'

# Read-only access to Apple Notes SQLite database
module NotesDB
  DB_PATH = File.expand_path("~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")

  # Apple CoreData timestamp epoch (2001-01-01 00:00:00 UTC)
  APPLE_EPOCH_OFFSET = 978307200

  # Entity type constants from Z_PRIMARYKEY
  ENT_NOTE = 11
  ENT_FOLDER = 14
  ENT_ACCOUNT = 13

  class << self
    def open_db(path = DB_PATH)
      raise "Notes database not found at #{path}" unless File.exist?(path)
      SQLite3::Database.new(path, results_as_hash: true, readonly: true)
    end

    def apple_to_time(apple_ts)
      return nil if apple_ts.nil? || apple_ts == 0
      Time.at(apple_ts + APPLE_EPOCH_OFFSET).localtime
    end

    def apple_to_iso(apple_ts)
      apple_to_time(apple_ts)&.iso8601
    end

    # Discover the CoreData URI prefix from the database
    def coredata_prefix(db)
      row = db.execute(
        "SELECT ZIDENTIFIER FROM ZICCLOUDSYNCINGOBJECT WHERE Z_ENT = ? AND ZIDENTIFIER IS NOT NULL LIMIT 1",
        [ENT_NOTE]
      ).first
      return nil unless row
      # We need to get the actual prefix from an AppleScript call or construct it
      # The prefix is embedded in note URIs. We'll construct it from the DB UUID.
      nil
    end

    def note_uri(db, z_pk)
      # Get the DB UUID from Z_METADATA
      @db_uuid ||= begin
        # Read from Z_METADATA - it contains a plist with the UUID
        # Alternative: query for any note via AppleScript and extract prefix
        # For now, extract from the sqlite file path's container
        row = db.execute("SELECT Z_UUID FROM Z_METADATA").first
        row && row['Z_UUID']
      rescue
        nil
      end
      if @db_uuid
        "x-coredata://#{@db_uuid}/ICNote/p#{z_pk}"
      else
        "ICNote/p#{z_pk}"
      end
    end

    # List folders
    def folders(db)
      db.execute(<<~SQL).map { |row| format_folder(row) }
        SELECT Z_PK, ZTITLE2, ZPARENT, ZFOLDERTYPE, ZIDENTIFIER
        FROM ZICCLOUDSYNCINGOBJECT
        WHERE Z_ENT = #{ENT_FOLDER}
        ORDER BY Z_PK
      SQL
    end

    # List notes, optionally filtered by folder
    def list_notes(db, limit: 20, folder: nil)
      conditions = ["n.Z_ENT = #{ENT_NOTE}", "n.ZMARKEDFORDELETION = 0"]
      params = []

      if folder
        folder_row = find_folder(db, folder)
        raise "Folder '#{folder}' not found" unless folder_row
        conditions << "n.ZFOLDER = ?"
        params << folder_row['Z_PK']
      end

      where = conditions.join(" AND ")
      params << limit

      db.execute(<<~SQL, params).map { |row| format_note_summary(row) }
        SELECT n.Z_PK, n.ZTITLE1, n.ZSNIPPET, n.ZFOLDER,
               n.ZMODIFICATIONDATE1, n.ZCREATIONDATE3, n.ZIDENTIFIER,
               n.ZISPINNED,
               f.ZTITLE2 as folder_name
        FROM ZICCLOUDSYNCINGOBJECT n
        LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON f.Z_PK = n.ZFOLDER AND f.Z_ENT = #{ENT_FOLDER}
        WHERE #{where}
        ORDER BY n.ZISPINNED DESC, n.ZMODIFICATIONDATE1 DESC
        LIMIT ?
      SQL
    end

    # Show a single note with full body
    def show_note(db, id)
      z_pk = parse_id(id)
      row = db.execute(<<~SQL, [z_pk]).first
        SELECT n.Z_PK, n.ZTITLE1, n.ZSNIPPET, n.ZFOLDER,
               n.ZMODIFICATIONDATE1, n.ZCREATIONDATE3, n.ZIDENTIFIER,
               n.ZISPINNED, n.ZMARKEDFORDELETION,
               f.ZTITLE2 as folder_name,
               nd.ZDATA
        FROM ZICCLOUDSYNCINGOBJECT n
        LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON f.Z_PK = n.ZFOLDER AND f.Z_ENT = #{ENT_FOLDER}
        LEFT JOIN ZICNOTEDATA nd ON nd.ZNOTE = n.Z_PK
        WHERE n.Z_PK = ? AND n.Z_ENT = #{ENT_NOTE}
      SQL
      raise "Note #{id} not found" unless row
      format_note_detail(row, db)
    end

    # Search notes by title and body content
    def search_notes(db, query, limit: 20, folder: nil)
      conditions = ["n.Z_ENT = #{ENT_NOTE}", "n.ZMARKEDFORDELETION = 0"]
      params = []

      if folder
        folder_row = find_folder(db, folder)
        raise "Folder '#{folder}' not found" unless folder_row
        conditions << "n.ZFOLDER = ?"
        params << folder_row['Z_PK']
      end

      where = conditions.join(" AND ")

      rows = db.execute(<<~SQL, params)
        SELECT n.Z_PK, n.ZTITLE1, n.ZSNIPPET, n.ZFOLDER,
               n.ZMODIFICATIONDATE1, n.ZCREATIONDATE3, n.ZIDENTIFIER,
               n.ZISPINNED,
               f.ZTITLE2 as folder_name,
               nd.ZDATA
        FROM ZICCLOUDSYNCINGOBJECT n
        LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON f.Z_PK = n.ZFOLDER AND f.Z_ENT = #{ENT_FOLDER}
        LEFT JOIN ZICNOTEDATA nd ON nd.ZNOTE = n.Z_PK
        WHERE #{where}
        ORDER BY n.ZMODIFICATIONDATE1 DESC
      SQL

      query_lower = query.downcase
      matches = []
      rows.each do |row|
        title = (row['ZTITLE1'] || '').downcase
        snippet = (row['ZSNIPPET'] || '').downcase

        # Check title and snippet first (fast)
        if title.include?(query_lower) || snippet.include?(query_lower)
          matches << format_note_summary(row)
          next
        end

        # Decompress and search full body
        if row['ZDATA']
          body_text = decompress_body(row['ZDATA'])
          if body_text && body_text.downcase.include?(query_lower)
            # Extract context around match
            idx = body_text.downcase.index(query_lower)
            context_start = [0, idx - 80].max
            context_end = [body_text.length, idx + query.length + 80].min
            context = body_text[context_start..context_end].strip
            context = "...#{context}" if context_start > 0
            context = "#{context}..." if context_end < body_text.length

            summary = format_note_summary(row)
            summary[:match_context] = context
            matches << summary
          end
        end

        break if matches.length >= limit
      end

      matches.first(limit)
    end

    # Extract the numeric Z_PK from various ID formats
    def parse_id(id)
      id_str = id.to_s.strip
      if id_str =~ /ICNote\/p(\d+)/
        $1.to_i
      elsif id_str =~ /\A\d+\z/
        id_str.to_i
      else
        raise "Invalid note ID: #{id}. Use a numeric ID or CoreData URI."
      end
    end

    # Decompress gzipped protobuf note body and extract text
    def decompress_body(data)
      return nil if data.nil? || data.empty?
      decompressed = Zlib::GzipReader.new(StringIO.new(data)).read
      extract_text_from_protobuf(decompressed)
    rescue Zlib::GzipFile::Error, Zlib::Error
      nil
    end

    private

    def extract_text_from_protobuf(data)
      # Apple Notes stores body as a protobuf (NSMergableData).
      # The actual note text is typically in the first large UTF-8 string field.
      # We extract runs of valid UTF-8 text, filtering out protobuf structural bytes.
      data.force_encoding('UTF-8')

      # Strategy: find the longest contiguous UTF-8 text block.
      # The note text is typically the first substantial string in the protobuf,
      # preceded by a short header. We look for runs of printable text.
      text_runs = []
      current_run = []
      current_len = 0

      data.each_char.with_index do |ch, i|
        cp = ch.ord rescue nil
        next unless cp

        # Accept: printable ASCII, newlines/tabs, and common Unicode (Latin, Cyrillic, CJK, emoji, etc.)
        if cp == 10 || cp == 13 || cp == 9 || (cp >= 32 && cp < 127) ||
           (cp >= 0x00A0 && cp <= 0x024F) ||  # Latin Extended
           (cp >= 0x0400 && cp <= 0x04FF) ||  # Cyrillic
           (cp >= 0x2000 && cp <= 0x206F) ||  # General Punctuation
           (cp >= 0x2010 && cp <= 0x2BFF) ||  # Various symbols
           (cp >= 0x3000 && cp <= 0x9FFF) ||  # CJK
           (cp >= 0x1F000 && cp <= 0x1FFFF)   # Emoji
          current_run << ch
          current_len += 1
        else
          if current_len >= 4 # Only keep runs of 4+ chars (skip protobuf noise)
            text_runs << current_run.join
          end
          current_run = []
          current_len = 0
        end
      end
      text_runs << current_run.join if current_len >= 4

      # The actual note content is usually the longest run
      # But often the first substantial run IS the content
      # Return all substantial runs joined
      text_runs
        .map(&:strip)
        .reject(&:empty?)
        .join("\n")
    end

    def find_folder(db, name_or_id)
      if name_or_id.to_s =~ /\A\d+\z/
        db.execute(
          "SELECT Z_PK, ZTITLE2 FROM ZICCLOUDSYNCINGOBJECT WHERE Z_PK = ? AND Z_ENT = #{ENT_FOLDER}",
          [name_or_id.to_i]
        ).first
      else
        db.execute(
          "SELECT Z_PK, ZTITLE2 FROM ZICCLOUDSYNCINGOBJECT WHERE ZTITLE2 = ? AND Z_ENT = #{ENT_FOLDER}",
          [name_or_id]
        ).first
      end
    end

    def format_folder(row)
      {
        id: row['Z_PK'],
        name: row['ZTITLE2'],
        parent: row['ZPARENT'],
        type: case row['ZFOLDERTYPE']
              when 0 then 'user'
              when 1 then 'trash'
              when 3 then 'quick_notes'
              else 'unknown'
              end,
        identifier: row['ZIDENTIFIER']
      }
    end

    def format_note_summary(row)
      {
        id: row['Z_PK'],
        title: row['ZTITLE1'],
        snippet: row['ZSNIPPET'],
        folder: row['folder_name'],
        folder_id: row['ZFOLDER'],
        pinned: row['ZISPINNED'] == 1,
        modified: apple_to_iso(row['ZMODIFICATIONDATE1']),
        created: apple_to_iso(row['ZCREATIONDATE3'])
      }
    end

    def format_note_detail(row, db)
      body = nil
      if row['ZDATA']
        body = decompress_body(row['ZDATA'])
      end

      {
        id: row['Z_PK'],
        uri: note_uri(db, row['Z_PK']),
        title: row['ZTITLE1'],
        body: body,
        snippet: row['ZSNIPPET'],
        folder: row['folder_name'],
        folder_id: row['ZFOLDER'],
        pinned: row['ZISPINNED'] == 1,
        deleted: row['ZMARKEDFORDELETION'] == 1,
        modified: apple_to_iso(row['ZMODIFICATIONDATE1']),
        created: apple_to_iso(row['ZCREATIONDATE3']),
        identifier: row['ZIDENTIFIER']
      }
    end
  end
end
