#!/usr/bin/env ruby
# frozen_string_literal: true

require 'xcodeproj'

PROJECT_PATH = 'Soramoyou/Soramoyou.xcodeproj'
MAIN_TARGET_NAME = 'Soramoyou'

# Open project
project = Xcodeproj::Project.open(PROJECT_PATH)
main_target = project.targets.find { |t| t.name == MAIN_TARGET_NAME }

unless main_target
  puts "Error: Main target '#{MAIN_TARGET_NAME}' not found"
  exit 1
end

puts "Found main target: #{main_target.name}"

# Get development team from main target
dev_team = main_target.build_configurations.first.build_settings['DEVELOPMENT_TEAM']
puts "Development Team: #{dev_team}"

# === Create Unit Test Target ===
puts "\n=== Creating SoramoyouTests target ==="

unit_test_target = project.targets.find { |t| t.name == 'SoramoyouTests' }
if unit_test_target
  puts "SoramoyouTests target already exists, skipping creation"
else
  unit_test_target = project.new_target(:unit_test_bundle, 'SoramoyouTests', :ios, '15.0')
  puts "Created SoramoyouTests target"

  # Add dependency on main target
  unit_test_target.add_dependency(main_target)
  puts "Added dependency on #{main_target.name}"
end

# Configure unit test target build settings
unit_test_target.build_configurations.each do |config|
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.soramoyou.SoramoyouTests'
  config.build_settings['DEVELOPMENT_TEAM'] = dev_team
  config.build_settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/Soramoyou.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Soramoyou'
  config.build_settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['INFOPLIST_FILE'] = ''
  config.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
end
puts "Configured build settings for SoramoyouTests"

# === Create UI Test Target ===
puts "\n=== Creating SoramoyouUITests target ==="

ui_test_target = project.targets.find { |t| t.name == 'SoramoyouUITests' }
if ui_test_target
  puts "SoramoyouUITests target already exists, skipping creation"
else
  ui_test_target = project.new_target(:ui_test_bundle, 'SoramoyouUITests', :ios, '15.0')
  puts "Created SoramoyouUITests target"

  # Add dependency on main target
  ui_test_target.add_dependency(main_target)
  puts "Added dependency on #{main_target.name}"
end

# Configure UI test target build settings
ui_test_target.build_configurations.each do |config|
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.soramoyou.SoramoyouUITests'
  config.build_settings['DEVELOPMENT_TEAM'] = dev_team
  config.build_settings['TEST_TARGET_NAME'] = 'Soramoyou'
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['INFOPLIST_FILE'] = ''
  config.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
end
puts "Configured build settings for SoramoyouUITests"

# === Add Test Files ===
puts "\n=== Adding test files ==="

# Find or create test groups
tests_group = project.main_group.find_subpath('SoramoyouTests', true)
tests_group.set_source_tree('<group>')
tests_group.set_path('SoramoyouTests')

ui_tests_group = project.main_group.find_subpath('SoramoyouUITests', true)
ui_tests_group.set_source_tree('<group>')
ui_tests_group.set_path('SoramoyouUITests')

# Unit test files
unit_test_files = [
  'AdServiceTests.swift',
  'AuthServiceTests.swift',
  'AuthViewModelTests.swift',
  'EditViewModelTests.swift',
  'FirestoreServiceTests.swift',
  'HomeViewModelTests.swift',
  'ImageServiceTests.swift',
  'IntegrationTests.swift',
  'ProfileViewModelTests.swift',
  'SearchViewModelTests.swift',
  'StorageServiceTests.swift',
  'UserModelTests.swift'
]

unit_test_files.each do |filename|
  file_path = "SoramoyouTests/#{filename}"
  full_path = "Soramoyou/#{file_path}"

  if File.exist?(full_path)
    # Check if file already added
    existing = tests_group.files.find { |f| f.path == filename }
    unless existing
      file_ref = tests_group.new_file(filename)
      unit_test_target.source_build_phase.add_file_reference(file_ref)
      puts "Added #{filename} to SoramoyouTests"
    else
      puts "#{filename} already in SoramoyouTests"
    end
  else
    puts "Warning: #{full_path} not found"
  end
end

# UI test files
ui_test_files = ['SoramoyouUITests.swift']

ui_test_files.each do |filename|
  file_path = "SoramoyouUITests/#{filename}"
  full_path = "Soramoyou/#{file_path}"

  if File.exist?(full_path)
    existing = ui_tests_group.files.find { |f| f.path == filename }
    unless existing
      file_ref = ui_tests_group.new_file(filename)
      ui_test_target.source_build_phase.add_file_reference(file_ref)
      puts "Added #{filename} to SoramoyouUITests"
    else
      puts "#{filename} already in SoramoyouUITests"
    end
  else
    puts "Warning: #{full_path} not found"
  end
end

# === Add Package Dependencies to Test Targets ===
puts "\n=== Adding package dependencies ==="

# Get package references from main target
main_target.package_product_dependencies.each do |dep|
  product_name = dep.product_name

  # Skip some packages that are not needed for tests
  next if ['GoogleMobileAds', 'FirebaseAI'].include?(product_name)

  # Add to unit test target if not already added
  existing = unit_test_target.package_product_dependencies.find { |d| d.product_name == product_name }
  unless existing
    # Create new dependency referencing the same package
    new_dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
    new_dep.product_name = product_name
    new_dep.package = dep.package
    unit_test_target.package_product_dependencies << new_dep
    puts "Added #{product_name} to SoramoyouTests"
  end
end

# Save project
project.save
puts "\n=== Project saved successfully ==="

# === Update Scheme ===
puts "\n=== Checking scheme ==="

scheme_path = "#{PROJECT_PATH}/xcshareddata/xcschemes/Soramoyou.xcscheme"
if File.exist?(scheme_path)
  puts "Found existing scheme at #{scheme_path}"
  # Read scheme and check if tests are configured
  scheme_content = File.read(scheme_path)

  unless scheme_content.include?('SoramoyouTests')
    puts "Scheme does not include test targets - manual scheme update may be needed"
  else
    puts "Scheme already includes test configuration"
  end
else
  puts "No shared scheme found - Xcode will auto-generate one"
end

puts "\n=== Done! ==="
puts "Run 'xcodebuild -list' to verify targets were added"
