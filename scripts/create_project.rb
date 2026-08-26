require 'xcodeproj'
require 'fileutils'

project_path = 'git-watch.xcodeproj'
FileUtils.rm_rf(project_path)

project = Xcodeproj::Project.new(project_path)
main_group = project.main_group.new_group('git-watch', '.')

%w[App Managers Views].each do |dir|
  g = main_group.new_group(dir, dir)
  Dir.glob("#{dir}/**/*.swift").sort.each do |f|
    g.new_reference(File.basename(f))
  end
end

updater_group = main_group.new_group('gitwatchUpdater', 'gitwatchUpdater')
Dir.glob('gitwatchUpdater/*.swift').sort.each do |f|
  updater_group.new_reference(File.basename(f))
end

app = project.new_target(:application, 'git-watch', :osx, '14.0')
app.product_name = 'GitWatch'
main_group.groups.find { |g| g.name == 'App' }.files.each do |ref|
  app.add_file_references([ref])
end
main_group.groups.find { |g| g.name == 'Managers' }.files.each do |ref|
  app.add_file_references([ref])
end
main_group.groups.find { |g| g.name == 'Views' }.files.each do |ref|
  app.add_file_references([ref])
end
app.build_configurations.each do |cfg|
  cfg.build_settings.merge!(
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.rejacky.gitwatch',
    'MARKETING_VERSION' => '0.1.0',
    'CURRENT_PROJECT_VERSION' => '1',
    'SWIFT_VERSION' => '5.9',
    'INFOPLIST_FILE' => 'Info.plist',
    'GENERATE_INFOPLIST_FILE' => 'NO',
    'CODE_SIGN_IDENTITY' => '-',
    'CODE_SIGN_STYLE' => 'Automatic',
    'MACOSX_DEPLOYMENT_TARGET' => '14.0',
    'ENABLE_HARDENED_RUNTIME' => 'YES',
    'PRODUCT_NAME' => 'GitWatch'
  )
end

helper = project.new_target(:application, 'GitWatchUpdater', :osx, '14.0')
helper.product_name = 'GitWatchUpdater'
helper.build_configurations.each do |cfg|
  cfg.build_settings.merge!(
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.rejacky.GitWatchUpdater',
    'MARKETING_VERSION' => '0.1.0',
    'CURRENT_PROJECT_VERSION' => '1',
    'SWIFT_VERSION' => '5.9',
    'GENERATE_INFOPLIST_FILE' => 'YES',
    'INFOPLIST_KEY_LSUIElement' => 'YES',
    'CODE_SIGN_IDENTITY' => '-',
    'MACOSX_DEPLOYMENT_TARGET' => '14.0'
  )
end
updater_group.files.each do |ref|
  helper.add_file_references([ref])
end
models_ref = main_group.groups.find { |g| g.name == 'Managers' }.files.find { |f| f.path == 'UpdateModels.swift' }
raise 'UpdateModels.swift reference missing' unless models_ref
helper.add_file_references([models_ref])

embed = app.new_copy_files_build_phase('Embed Helper')
embed.dst_subfolder_spec = '10'
embed.dst_path = '../Helpers'
helper_product_ref = project.products_group.children.find { |p| p.path == 'GitWatchUpdater.app' }
raise 'GitWatchUpdater.app product reference missing' unless helper_product_ref
embed.add_file_reference(helper_product_ref)

tests = project.new_target(:unit_test_bundle, 'git-watchTests', :osx, '14.0')
tests.build_configurations.each do |cfg|
  cfg.build_settings.merge!(
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.rejacky.gitwatchTests',
    'SWIFT_VERSION' => '5.9',
    'TEST_HOST' => '$(BUILT_PRODUCTS_DIR)/GitWatch.app/Contents/MacOS/GitWatch',
    'BUNDLE_LOADER' => '$(TEST_HOST)',
    'GENERATE_INFOPLIST_FILE' => 'YES',
    'MACOSX_DEPLOYMENT_TARGET' => '14.0'
  )
end
tests_group = main_group.new_group('git-watchTests', 'git-watchTests')
tests.add_dependency(app)

project.save
puts "Created #{project_path}"
