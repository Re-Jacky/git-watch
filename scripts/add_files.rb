#!/usr/bin/env ruby
# Usage: ruby scripts/add_files.rb path/File1.swift [path/File2.swift ...]
require 'xcodeproj'

project_path = 'git-watch.xcodeproj'
abort "#{project_path} not found" unless File.exist?(project_path)
project = Xcodeproj::Project.open(project_path)

app_target = project.targets.find { |t| t.name == 'git-watch' }
test_target = project.targets.find { |t| t.name == 'git-watchTests' }
main_group = project.main_group.children.find { |g| g.display_name == 'git-watch' }

ARGV.each do |file_path|
  abort "#{file_path} does not exist" unless File.exist?(file_path)
  dir = File.dirname(file_path)
  group = dir == '.' ? main_group : main_group.find_subpath(dir, true)
  next if group.files.any? { |f| f.path == File.basename(file_path) }
  ref = group.new_reference(File.basename(file_path))
  target = dir == 'git-watchTests' ? test_target : app_target
  target.source_build_phase.add_file_reference(ref)
end

project.save
puts "Registered: #{ARGV.join(', ')}"
