#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'minitest/autorun'
require 'stringio'
require 'zlib'
require_relative '../lib/notes_db'

class TestNotesDBParsing < Minitest::Test
  # --- apple_to_time / apple_to_iso ---

  def test_apple_to_time_nil
    assert_nil NotesDB.apple_to_time(nil)
  end

  def test_apple_to_time_zero
    assert_nil NotesDB.apple_to_time(0)
  end

  def test_apple_to_time_known_value
    # 793078202.0 Apple timestamp = 2001-01-01 + 793078202 seconds
    # = 2026-02-18 03:30:02 UTC
    t = NotesDB.apple_to_time(793078202.0)
    assert_instance_of Time, t
    assert_equal 2026, t.year
    assert_equal 2, t.month
  end

  def test_apple_to_iso_returns_string
    iso = NotesDB.apple_to_iso(793078202.0)
    assert_match(/\A\d{4}-\d{2}-\d{2}T/, iso)
  end

  def test_apple_to_iso_nil
    assert_nil NotesDB.apple_to_iso(nil)
  end

  # --- parse_id ---

  def test_parse_id_numeric_string
    assert_equal 1214, NotesDB.parse_id("1214")
  end

  def test_parse_id_integer
    assert_equal 42, NotesDB.parse_id(42)
  end

  def test_parse_id_coredata_uri
    uri = "x-coredata://B9669079-92D2-48C1-91ED-8D55A8441D00/ICNote/p1214"
    assert_equal 1214, NotesDB.parse_id(uri)
  end

  def test_parse_id_short_uri
    assert_equal 999, NotesDB.parse_id("ICNote/p999")
  end

  def test_parse_id_invalid_raises
    assert_raises(RuntimeError) { NotesDB.parse_id("not-an-id") }
  end

  def test_parse_id_with_whitespace
    assert_equal 1214, NotesDB.parse_id("  1214  ")
  end

  # --- decompress_body ---

  def test_decompress_body_nil
    assert_nil NotesDB.decompress_body(nil)
  end

  def test_decompress_body_empty
    assert_nil NotesDB.decompress_body("")
  end

  def test_decompress_body_invalid_gzip
    assert_nil NotesDB.decompress_body("not gzip data")
  end

  def test_decompress_body_valid_gzip
    # Create a gzipped string with some text embedded
    text = "Hello world this is a test note"
    sio = StringIO.new
    gz = Zlib::GzipWriter.new(sio)
    gz.write(text)
    gz.close
    gzipped = sio.string

    result = NotesDB.decompress_body(gzipped)
    assert_includes result, "Hello world this is a test note"
  end
end

class TestNotesDBIntegration < Minitest::Test
  def setup
    @db = NotesDB.open_db
  end

  def teardown
    @db.close if @db
  end

  # --- folders ---

  def test_folders_returns_array
    folders = NotesDB.folders(@db)
    assert_instance_of Array, folders
    refute_empty folders
  end

  def test_folders_have_required_keys
    folder = NotesDB.folders(@db).first
    assert folder.key?(:id)
    assert folder.key?(:name)
    assert folder.key?(:type)
  end

  def test_folders_includes_default_notes_folder
    folders = NotesDB.folders(@db)
    names = folders.map { |f| f[:name] }
    assert_includes names, "Notes"
  end

  # --- list_notes ---

  def test_list_notes_returns_array
    notes = NotesDB.list_notes(@db, limit: 5)
    assert_instance_of Array, notes
  end

  def test_list_notes_respects_limit
    notes = NotesDB.list_notes(@db, limit: 3)
    assert notes.length <= 3
  end

  def test_list_notes_have_required_keys
    notes = NotesDB.list_notes(@db, limit: 1)
    skip "No notes in database" if notes.empty?
    note = notes.first
    [:id, :title, :snippet, :folder, :modified, :created].each do |key|
      assert note.key?(key), "Missing key: #{key}"
    end
  end

  def test_list_notes_sorted_by_modification_date_desc
    notes = NotesDB.list_notes(@db, limit: 10)
    skip "Need at least 2 notes" if notes.length < 2
    # Pinned notes come first, then sorted by date
    unpinned = notes.reject { |n| n[:pinned] }
    dates = unpinned.map { |n| n[:modified] }.compact
    assert_equal dates, dates.sort.reverse
  end

  def test_list_notes_filter_by_folder
    notes = NotesDB.list_notes(@db, limit: 5, folder: "Notes")
    notes.each do |note|
      assert_equal "Notes", note[:folder]
    end
  end

  def test_list_notes_invalid_folder_raises
    assert_raises(RuntimeError) { NotesDB.list_notes(@db, folder: "Nonexistent Folder XYZ") }
  end

  # --- show_note ---

  def test_show_note_returns_detail
    notes = NotesDB.list_notes(@db, limit: 1)
    skip "No notes in database" if notes.empty?
    detail = NotesDB.show_note(@db, notes.first[:id])
    assert detail.key?(:id)
    assert detail.key?(:body)
    assert detail.key?(:uri)
    assert detail.key?(:title)
    assert detail.key?(:identifier)
  end

  def test_show_note_body_not_nil
    notes = NotesDB.list_notes(@db, limit: 1)
    skip "No notes in database" if notes.empty?
    detail = NotesDB.show_note(@db, notes.first[:id])
    # Body should be extracted from protobuf
    refute_nil detail[:body], "Body should not be nil for a note with content"
  end

  def test_show_note_not_found_raises
    assert_raises(RuntimeError) { NotesDB.show_note(@db, 999999) }
  end

  def test_show_note_accepts_uri
    notes = NotesDB.list_notes(@db, limit: 1)
    skip "No notes in database" if notes.empty?
    detail = NotesDB.show_note(@db, notes.first[:id])
    # Should also work with the URI
    detail2 = NotesDB.show_note(@db, detail[:uri])
    assert_equal detail[:id], detail2[:id]
  end

  # --- search_notes ---

  def test_search_returns_array
    results = NotesDB.search_notes(@db, "the", limit: 5)
    assert_instance_of Array, results
  end

  def test_search_respects_limit
    results = NotesDB.search_notes(@db, "the", limit: 2)
    assert results.length <= 2
  end

  def test_search_finds_by_title
    notes = NotesDB.list_notes(@db, limit: 1)
    skip "No notes in database" if notes.empty?
    title = notes.first[:title]
    # Search for a word from the title
    word = title.split.first
    skip "Title is empty" if word.nil? || word.empty?
    results = NotesDB.search_notes(@db, word, limit: 10)
    ids = results.map { |r| r[:id] }
    assert_includes ids, notes.first[:id]
  end

  def test_search_no_results
    results = NotesDB.search_notes(@db, "xyzzy_impossiblequery_12345")
    assert_empty results
  end
end
