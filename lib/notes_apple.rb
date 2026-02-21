# frozen_string_literal: true

require 'open3'
require 'json'

# AppleScript-based operations for Apple Notes (create, update, delete)
module NotesApple
  class << self
    # Create a new note
    # Returns { id:, title:, folder: }
    def create_note(title:, body: nil, html: nil, folder: "Notes")
      escaped_title = escape_applescript(title)
      escaped_folder = escape_applescript(folder)

      content = if html
                  html
                elsif body
                  text_to_html(body)
                else
                  "<div><br></div>"
                end
      escaped_content = escape_applescript(content)

      script = <<~APPLESCRIPT
        tell application "Notes"
          set targetFolder to folder "#{escaped_folder}"
          set newNote to make new note at targetFolder with properties {name:"#{escaped_title}", body:"#{escaped_content}"}
          set noteId to id of newNote
          set noteName to name of newNote
          set noteDate to modification date of newNote
          return noteId & "\\t" & noteName
        end tell
      APPLESCRIPT

      stdout = run_applescript(script)
      parts = stdout.strip.split("\t", 2)

      id_num = parse_id_from_uri(parts[0])
      {
        id: id_num,
        uri: parts[0],
        title: parts[1] || title,
        folder: folder
      }
    end

    # Update a note's body (replace entirely)
    def update_body(uri:, html: nil, body: nil)
      content = if html
                  html
                elsif body
                  text_to_html(body)
                else
                  raise "Either body or html is required for update"
                end
      escaped_content = escape_applescript(content)

      script = <<~APPLESCRIPT
        tell application "Notes"
          set targetNote to note id "#{escape_applescript(uri)}"
          set body of targetNote to "#{escaped_content}"
          return name of targetNote & "\\t" & (modification date of targetNote as string)
        end tell
      APPLESCRIPT

      stdout = run_applescript(script)
      parts = stdout.strip.split("\t", 2)
      { title: parts[0], modified: parts[1] }
    end

    # Update a note's name
    def update_name(uri:, name:)
      script = <<~APPLESCRIPT
        tell application "Notes"
          set targetNote to note id "#{escape_applescript(uri)}"
          set name of targetNote to "#{escape_applescript(name)}"
          return name of targetNote
        end tell
      APPLESCRIPT

      stdout = run_applescript(script)
      { title: stdout.strip }
    end

    # Append text to a note's existing body
    def append_body(uri:, html: nil, body: nil)
      content = if html
                  html
                elsif body
                  text_to_html(body)
                else
                  raise "Either body or html is required for append"
                end

      escaped_uri = escape_applescript(uri)
      escaped_content = escape_applescript(content)

      script = <<~APPLESCRIPT
        tell application "Notes"
          set targetNote to note id "#{escaped_uri}"
          set currentBody to body of targetNote
          set body of targetNote to currentBody & "#{escaped_content}"
          return name of targetNote & "\\t" & (modification date of targetNote as string)
        end tell
      APPLESCRIPT

      stdout = run_applescript(script)
      parts = stdout.strip.split("\t", 2)
      { title: parts[0], modified: parts[1] }
    end

    # Get note body as HTML via AppleScript (more accurate than SQLite protobuf extraction)
    def get_html(uri:)
      script = <<~APPLESCRIPT
        tell application "Notes"
          set targetNote to note id "#{escape_applescript(uri)}"
          return body of targetNote
        end tell
      APPLESCRIPT

      run_applescript(script).strip
    end

    # Get note body as plaintext via AppleScript
    def get_plaintext(uri:)
      script = <<~APPLESCRIPT
        tell application "Notes"
          set targetNote to note id "#{escape_applescript(uri)}"
          return plaintext of targetNote
        end tell
      APPLESCRIPT

      run_applescript(script)
    end

    # Delete a note (moves to Recently Deleted)
    def delete_note(uri:)
      script = <<~APPLESCRIPT
        tell application "Notes"
          set targetNote to note id "#{escape_applescript(uri)}"
          set noteName to name of targetNote
          delete targetNote
          return noteName
        end tell
      APPLESCRIPT

      stdout = run_applescript(script)
      { deleted: true, title: stdout.strip }
    end

    private

    def run_applescript(script)
      stdout, stderr, status = Open3.capture3('osascript', '-e', script)
      unless status.success?
        raise "AppleScript error: #{stderr.strip}"
      end
      stdout
    end

    def escape_applescript(str)
      str.to_s.gsub('\\', '\\\\\\\\').gsub('"', '\\"')
    end

    def text_to_html(text)
      # Convert plain text to basic HTML
      lines = text.split("\n")
      lines.map { |line| "<div>#{line.empty? ? '<br>' : escape_html(line)}</div>" }.join("\n")
    end

    def escape_html(text)
      text.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
    end

    def parse_id_from_uri(uri)
      if uri =~ /ICNote\/p(\d+)/
        $1.to_i
      else
        nil
      end
    end
  end
end
