#!/usr/bin/env ruby
# One-shot: add the SodaliteTests unit-test target to the project and wire it into the shared scheme.
require 'xcodeproj'

project_path = 'Sodalite.xcodeproj'
project = Xcodeproj::Project.open(project_path)

app = project.targets.find { |t| t.name == 'Sodalite' } or abort 'Sodalite app target not found'
abort 'SodaliteTests already exists' if project.targets.any? { |t| t.name == 'SodaliteTests' }

test_target = project.new_target(:unit_test_bundle, 'SodaliteTests', :tvos, '26.0', nil, :swift)

settings = {
  'GENERATE_INFOPLIST_FILE' => 'YES',
  'PRODUCT_BUNDLE_IDENTIFIER' => 'de.superuser404.SodaliteTests',
  'PRODUCT_NAME' => '$(TARGET_NAME)',
  'TEST_HOST' => '$(BUILT_PRODUCTS_DIR)/Sodalite.app/Sodalite',
  'BUNDLE_LOADER' => '$(TEST_HOST)',
  'DEVELOPMENT_TEAM' => '4NY63S72W9',
  'TVOS_DEPLOYMENT_TARGET' => '26.0',
  'TARGETED_DEVICE_FAMILY' => '3',
  'SDKROOT' => 'appletvos',
  'SWIFT_VERSION' => '6.0',
  'SWIFT_DEFAULT_ACTOR_ISOLATION' => 'MainActor',
  'SWIFT_APPROACHABLE_CONCURRENCY' => 'YES',
  'SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY' => 'YES',
  'CODE_SIGN_STYLE' => 'Automatic',
  'CURRENT_PROJECT_VERSION' => '1',
  'MARKETING_VERSION' => '0.12.0',
}
test_target.build_configurations.each do |config|
  settings.each { |k, v| config.build_settings[k] = v }
end

# Build the app (host) before the tests.
test_target.add_dependency(app)

# Add the test sources as explicit references (the SodaliteTests folder is not a synchronized group).
group = project.main_group.new_group('SodaliteTests', 'SodaliteTests')
Dir.glob('SodaliteTests/*.swift').sort.each do |path|
  ref = group.new_reference(File.basename(path))
  test_target.add_file_references([ref])
end

project.save

# Wire the test target into the shared Sodalite scheme's Test + Build actions.
scheme_path = File.join(Xcodeproj::XCScheme.shared_data_dir(project_path), 'Sodalite.xcscheme')
scheme = Xcodeproj::XCScheme.new(scheme_path)
testable = Xcodeproj::XCScheme::TestAction::TestableReference.new(test_target)
scheme.test_action.add_testable(testable)
entry = Xcodeproj::XCScheme::BuildAction::Entry.new(test_target)
entry.build_for_testing = true
entry.build_for_running = false
entry.build_for_profiling = false
entry.build_for_archiving = false
entry.build_for_analyzing = false
scheme.build_action.add_entry(entry)
scheme.save_as(project_path, 'Sodalite', true)

puts "OK: SodaliteTests target + scheme wiring written (#{Dir.glob('SodaliteTests/*.swift').size} test files)."
