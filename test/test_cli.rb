#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'minitest/autorun'
require 'json'
require 'open3'

# End-to-end tests for the apple-notes CLI executable
class TestCLI < Minitest::Test
  BIN = File.expand_path('../apple-notes', __dir__)

  def run_cli(*args)
    stdout, stderr, status = Open3.capture3(BIN, *args)
    [JSON.parse(stdout, symbolize_names: true), status]
  rescue JSON::ParserError
    [{ raw: stdout, stderr: stderr }, status]
  end

  def setup
    @created_ids = []
  end

  def teardown
    @created_ids.each do |id|
      run_cli('delete', id.to_s) rescue nil
    end
  end

  # --- help ---

  def test_help
    stdout, _, status = Open3.capture3(BIN, 'help')
    assert status.success?
    assert_includes stdout, 'apple-notes'
    assert_includes stdout, 'folders'
  end

  def test_no_args_shows_help
    stdout, _, status = Open3.capture3(BIN)
    assert status.success?
    assert_includes stdout, 'apple-notes'
  end

  def test_unknown_command
    result, status = run_cli('bogus')
    refute result[:ok]
    assert_equal 'USAGE', result[:code]
  end

  # --- folders ---

  def test_folders
    result, status = run_cli('folders')
    assert status.success?
    assert result[:ok]
    assert result[:data][:folders].is_a?(Array)
    names = result[:data][:folders].map { |f| f[:name] }
    assert_includes names, 'Notes'
  end

  # --- list ---

  def test_list
    result, status = run_cli('list', '--limit', '3')
    assert status.success?
    assert result[:ok]
    assert result[:data][:notes].is_a?(Array)
    assert result[:data][:notes].length <= 3
  end

  def test_list_with_folder
    result, status = run_cli('list', '--limit', '3', '--folder', 'Notes')
    assert status.success?
    assert result[:ok]
    result[:data][:notes].each do |note|
      assert_equal 'Notes', note[:folder]
    end
  end

  def test_list_invalid_folder
    result, status = run_cli('list', '--folder', 'NonexistentXYZ')
    refute result[:ok]
  end

  # --- show ---

  def test_show
    # Get an existing note ID first
    list_result, _ = run_cli('list', '--limit', '1')
    skip "No notes" unless list_result[:ok] && list_result[:data][:notes].length > 0
    note_id = list_result[:data][:notes].first[:id].to_s

    result, status = run_cli('show', note_id)
    assert status.success?
    assert result[:ok]
    assert_equal note_id.to_i, result[:data][:id]
    assert result[:data][:title]
    assert result[:data][:body]
  end

  def test_show_not_found
    result, status = run_cli('show', '999999')
    refute result[:ok]
  end

  def test_show_no_id
    result, status = run_cli('show')
    refute result[:ok]
    assert_equal 'USAGE', result[:code]
  end

  # --- search ---

  def test_search
    result, status = run_cli('search', 'the', '--limit', '3')
    assert status.success?
    assert result[:ok]
    assert result[:data][:notes].is_a?(Array)
    assert_equal 'the', result[:data][:query]
  end

  def test_search_no_results
    result, status = run_cli('search', 'xyzzy_impossible_98765')
    assert status.success?
    assert result[:ok]
    assert_empty result[:data][:notes]
  end

  def test_search_no_query
    result, status = run_cli('search')
    refute result[:ok]
    assert_equal 'USAGE', result[:code]
  end

  # --- CRUD lifecycle ---

  def test_create_show_update_delete
    # Create
    title = "CLI Test #{Time.now.to_i}"
    create_result, status = run_cli('create', title, '--body', 'Test body content')
    assert status.success?, "Create failed: #{create_result}"
    assert create_result[:ok], "Create not ok: #{create_result}"
    note_id = create_result[:data][:id].to_s
    @created_ids << note_id

    # Show (via SQLite - may need a moment to sync)
    # Use AppleScript show (--html) which is always up to date
    show_result, status = run_cli('show', note_id, '--html')
    assert status.success?
    assert show_result[:ok]
    assert_includes show_result[:data][:html].downcase, 'test body content'

    # Update body
    update_result, status = run_cli('update', note_id, '--body', 'Updated body')
    assert status.success?
    assert update_result[:ok]

    # Verify update
    show_result2, _ = run_cli('show', note_id, '--html')
    assert_includes show_result2[:data][:html].downcase, 'updated body'

    # Update name
    new_title = "Renamed #{Time.now.to_i}"
    rename_result, status = run_cli('update', note_id, '--name', new_title)
    assert status.success?
    assert_equal new_title, rename_result[:data][:title]

    # Append
    append_result, status = run_cli('update', note_id, '--append', 'Appended text')
    assert status.success?
    show_result3, _ = run_cli('show', note_id, '--html')
    assert_includes show_result3[:data][:html].downcase, 'updated body'
    assert_includes show_result3[:data][:html].downcase, 'appended text'

    # Delete
    delete_result, status = run_cli('delete', note_id)
    assert status.success?
    assert delete_result[:ok]
    assert delete_result[:data][:deleted]
    @created_ids.delete(note_id) # Already deleted
  end

  def test_create_in_folder
    title = "Folder Test #{Time.now.to_i}"
    result, status = run_cli('create', title, '--body', 'In notes folder', '--folder', 'Notes')
    assert status.success?
    assert result[:ok]
    @created_ids << result[:data][:id].to_s
    assert_equal 'Notes', result[:data][:folder]
  end

  def test_update_no_flags
    list_result, _ = run_cli('list', '--limit', '1')
    skip "No notes" unless list_result[:ok] && list_result[:data][:notes].length > 0
    note_id = list_result[:data][:notes].first[:id].to_s

    result, status = run_cli('update', note_id)
    refute result[:ok]
    assert_equal 'USAGE', result[:code]
  end
end
