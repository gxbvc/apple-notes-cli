#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'minitest/autorun'
require_relative '../lib/notes_apple'

# These tests create, update, and delete real notes via AppleScript.
# They clean up after themselves.
class TestNotesApple < Minitest::Test
  def setup
    @created_uris = []
  end

  def teardown
    # Clean up any notes we created
    @created_uris.each do |uri|
      NotesApple.delete_note(uri: uri) rescue nil
    end
  end

  # --- create ---

  def test_create_note_with_title_only
    result = NotesApple.create_note(title: "Test Note #{Time.now.to_i}")
    @created_uris << result[:uri]

    assert result[:id], "Should return numeric id"
    assert result[:uri], "Should return CoreData URI"
    assert_match(/ICNote/, result[:uri])
    assert_equal "Notes", result[:folder]
  end

  def test_create_note_with_body
    title = "Test Body Note #{Time.now.to_i}"
    result = NotesApple.create_note(title: title, body: "Hello from test\nLine two")
    @created_uris << result[:uri]

    # Verify body via get_plaintext
    plaintext = NotesApple.get_plaintext(uri: result[:uri])
    assert_includes plaintext, "Hello from test"
    assert_includes plaintext, "Line two"
  end

  def test_create_note_with_html
    title = "Test HTML Note #{Time.now.to_i}"
    result = NotesApple.create_note(title: title, html: "<div><b>Bold text</b></div>")
    @created_uris << result[:uri]

    html = NotesApple.get_html(uri: result[:uri])
    assert_includes html.downcase, "bold text"
  end

  # --- update ---

  def test_update_body
    result = NotesApple.create_note(title: "Update Test #{Time.now.to_i}", body: "Original")
    @created_uris << result[:uri]

    NotesApple.update_body(uri: result[:uri], body: "Replaced content")
    plaintext = NotesApple.get_plaintext(uri: result[:uri])
    assert_includes plaintext, "Replaced content"
    refute_includes plaintext, "Original"
  end

  def test_update_name
    original_title = "Rename Test #{Time.now.to_i}"
    result = NotesApple.create_note(title: original_title, body: "Some content")
    @created_uris << result[:uri]

    new_title = "Renamed #{Time.now.to_i}"
    update_result = NotesApple.update_name(uri: result[:uri], name: new_title)
    assert_equal new_title, update_result[:title]
  end

  def test_append_body
    result = NotesApple.create_note(title: "Append Test #{Time.now.to_i}", body: "First part.")
    @created_uris << result[:uri]

    NotesApple.append_body(uri: result[:uri], body: "Appended part.")
    plaintext = NotesApple.get_plaintext(uri: result[:uri])
    assert_includes plaintext, "First part."
    assert_includes plaintext, "Appended part."
  end

  # --- delete ---

  def test_delete_note
    result = NotesApple.create_note(title: "Delete Test #{Time.now.to_i}", body: "To be deleted")
    uri = result[:uri]

    delete_result = NotesApple.delete_note(uri: uri)
    assert delete_result[:deleted]
    assert delete_result[:title]

    # Note should no longer be accessible (or be in trash)
    # Don't add to @created_uris since we already deleted it
  end

  # --- edge cases ---

  def test_create_with_special_characters
    title = "Test \"quotes\" & <brackets> #{Time.now.to_i}"
    result = NotesApple.create_note(title: title, body: "Body with \"quotes\" & <tags>")
    @created_uris << result[:uri]

    plaintext = NotesApple.get_plaintext(uri: result[:uri])
    assert_includes plaintext, "quotes"
    assert_includes plaintext, "<tags>"
  end
end
