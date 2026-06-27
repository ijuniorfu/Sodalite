#!/usr/bin/env ruby
# One-shot: make the Sodalite target Universal (iPhone+iPad+tvOS) and keep the
# TopShelf extension tvOS-only + excluded from iOS builds. Idempotent.
require 'xcodeproj'

project_path = File.join(__dir__, '..', 'Sodalite.xcodeproj')
project = Xcodeproj::Project.open(project_path)

app = project.targets.find { |t| t.name == 'Sodalite' }
raise 'Sodalite target not found' unless app
topshelf = project.targets.find { |t| t.name == 'SodaliteTopShelf' }
raise 'SodaliteTopShelf target not found' unless topshelf

app.build_configurations.each do |c|
  c.build_settings['SUPPORTED_PLATFORMS'] = 'appletvos appletvsimulator iphoneos iphonesimulator'
  c.build_settings['SDKROOT'] = 'auto'
  c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '26.0'
  c.build_settings['TVOS_DEPLOYMENT_TARGET'] = '26.0'
  c.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2,3'
  # Asset catalog: the tvOS Brand Assets ("App Icon & Top Shelf Image") only
  # exists for tvOS. iOS uses a plain AppIcon set and has no brand assets.
  # Unconditional keys stay tvOS; SDK-conditioned keys override for iOS.
  c.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'App Icon & Top Shelf Image'
  c.build_settings['ASSETCATALOG_COMPILER_BRAND_ASSETS_NAME'] = 'App Icon & Top Shelf Image'
  c.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME[sdk=iphone*]'] = 'AppIcon'
  c.build_settings['ASSETCATALOG_COMPILER_BRAND_ASSETS_NAME[sdk=iphone*]'] = ''
end

topshelf.build_configurations.each do |c|
  c.build_settings['SUPPORTED_PLATFORMS'] = 'appletvos appletvsimulator'
end

# Exclude the tvOS-only extension from iOS builds: filter both the dependency
# and the embed (copy-files) build file to tvOS.
app.dependencies.each do |dep|
  dep.platform_filters = ['tvos'] if dep.target&.name == 'SodaliteTopShelf'
end

app.copy_files_build_phases.each do |phase|
  phase.files.each do |bf|
    name = bf.display_name.to_s
    bf.platform_filters = ['tvos'] if name.include?('SodaliteTopShelf')
  end
end

project.save
puts 'Universal build configuration applied.'
