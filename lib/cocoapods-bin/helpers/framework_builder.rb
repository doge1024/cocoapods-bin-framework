# frozen_string_literal: true

# copy from https://github.com/CocoaPods/cocoapods-packager

require 'cocoapods-bin/helpers/framework.rb'
require 'English'

module CBin
  class Framework
    class Builder
      include Pod

      def initialize(spec, file_accessor, platform, source_dir, use_framework=true)
        @spec = spec
        @source_dir = source_dir
        @file_accessor = file_accessor
        @platform = platform
        @vendored_libraries = (file_accessor.vendored_static_frameworks + file_accessor.vendored_static_libraries).map(&:to_s)
        @use_framework = use_framework
      end

      def build
        UI.section("Building static framework #{@spec}") do
          defines = compile

          build_sim_libraries(defines)

          output = framework.versions_path + Pathname.new(@spec.name)
          if use_framework
            build_static_framework_for_ios(output)
            copy_headers_static
          else
            build_static_library_for_ios(output)
            copy_headers
          end
          copy_license
          copy_resources
          cp_to_source_dir
        end
      end

      private

      def cp_to_source_dir
        target_dir = "#{@source_dir}/#{@spec.name}.framework"
        FileUtils.rm_rf(target_dir) if File.exist?(target_dir)

        `cp -fa #{@platform}/#{@spec.name}.framework #{@source_dir}`
      end

      def build_sim_libraries(defines)
        UI.message 'Building simulator libraries'
        xcodebuild(defines, '-sdk iphonesimulator', 'build-simulator')
      end

      def copy_headers_static
        copy_headers
        
        # 如果有swift库的话, 可能缺少拷贝文件
        build_simulator_headers = Pathname("./build-simulator/#{Pathname.new(@spec.name)}.framework/Headers")
        build_headers = Pathname("./build/#{Pathname.new(@spec.name)}.framework/Headers")
        if build_headers.exist?
          `cp -fRap #{build_simulator_headers}/* #{framework.headers_path}/`
          `cp -fRap #{build_headers}/* #{framework.headers_path}/`
        end
        
        # 拷贝modulemap
        build_simulator_modules = Pathname("./build-simulator/#{Pathname.new(@spec.name)}.framework/Modules")
        build_modules = Pathname("./build/#{Pathname.new(@spec.name)}.framework/Modules")

        if build_modules.exist?
          if framework.module_map_path.exist? == false
            framework.module_map_path.mkpath
          end
          `cp -fRap #{build_simulator_modules}/* #{framework.module_map_path}/`
          `cp -fRap #{build_modules}/* #{framework.module_map_path}/`
        end
      end

      def copy_headers
        public_headers = @file_accessor.public_headers
        UI.message "Copying public headers #{public_headers.map(&:basename).map(&:to_s)}"

        public_headers.each do |h|
          `ditto #{h} #{framework.headers_path}/#{h.basename}`
        end

        # If custom 'module_map' is specified add it to the framework distribution
        # otherwise check if a header exists that is equal to 'spec.name', if so
        # create a default 'module_map' one using it.
        if !@spec.module_map.nil?
          module_map_file = @file_accessor.module_map
          if Pathname(module_map_file).exist?
            module_map = File.read(module_map_file)
         end
        elsif public_headers.map(&:basename).map(&:to_s).include?("#{@spec.name}.h")
          module_map = <<-MAP
          framework module #{@spec.name} {
            umbrella header "#{@spec.name}.h"

            export *
            module * { export * }
          }
          MAP
        end

        unless module_map.nil?
          UI.message "Writing module map #{module_map}"
          unless framework.module_map_path.exist?
            framework.module_map_path.mkpath
         end
          File.write("#{framework.module_map_path}/module.modulemap", module_map)
        end
      end

      def copy_license
        UI.message 'Copying license'
        license_file = @spec.license[:file] || 'LICENSE'
        `cp "#{license_file}" .` if Pathname(license_file).exist?
      end

      def copy_resources
        bundles = Dir.glob('./build/*.bundle')

        bundle_names = [@spec, *@spec.recursive_subspecs].flat_map do |spec|
          consumer = spec.consumer(@platform)
          consumer.resource_bundles.keys +
            consumer.resources.map do |r|
              File.basename(r, '.bundle') if File.extname(r) == 'bundle'
            end
        end.compact.uniq

        bundles.select! do |bundle|
          bundle_name = File.basename(bundle, '.bundle')
          bundle_names.include?(bundle_name)
        end

        if bundles.count > 0
          UI.message "Copying bundle files #{bundles}"
          bundle_files = bundles.join(' ')
          `cp -rp #{bundle_files} #{framework.resources_path} 2>&1`
        end

        resources = [@spec, *@spec.recursive_subspecs].flat_map do |spec|
          expand_paths(spec.consumer(@platform).resources)
        end.compact.uniq

        if resources.count == 0 && bundles.count == 0
          framework.delete_resources
          return
        end
        if resources.count > 0
          UI.message "Copying resources #{resources}"
          `cp -rp #{resources.join(' ')} #{framework.resources_path}`
        end
      end

      def use_framework
        return @use_framework
      end

      def static_libs_in_sandbox(build_dir = 'build')
        if use_framework
          Dir.glob("#{build_dir}/#{Pathname.new(@spec.name)}.framework/#{Pathname.new(@spec.name)}")
        else
          Dir.glob("#{build_dir}/lib#{target_name}.a")
        end
      end

      def build_static_framework_for_ios(output)
        UI.message "Building ios libraries with archs #{ios_architectures}"
        static_libs = static_libs_in_sandbox('build') + static_libs_in_sandbox('build-simulator') + @vendored_libraries

        # 暂时不过滤 arch, 操作的是framework里面的mach-o文件
        libs = static_libs

        `lipo -create -output #{output} #{libs.join(' ')}`

        # `rm -rf #{framework.fwk_path}/*`
        # `cp -fRap ./build/#{target_name}.framework/* #{framework.fwk_path}/`
        # `lipo -create -output #{framework.fwk_path}/#{Pathname.new(@spec.name)} #{libs.join(' ')}`
      end  

      def build_static_library_for_ios(output)
        UI.message "Building ios libraries with archs #{ios_architectures}"
        static_libs = static_libs_in_sandbox('build') + static_libs_in_sandbox('build-simulator') + @vendored_libraries

        libs = ios_architectures.map do |arch|
          library = "build/package-#{arch}.a"
          `libtool -arch_only #{arch} -static -o #{library} #{static_libs.join(' ')}`
          library
        end

        `lipo -create -output #{output} #{libs.join(' ')}`
      end

      def ios_build_options
        "ARCHS=\'#{ios_architectures.join(' ')}\' OTHER_CFLAGS=\'-fembed-bitcode -Qunused-arguments\'"
      end

      def ios_architectures
        archs = %w[x86_64 arm64 armv7 armv7s i386]
        # 默认支持全平台
        # @vendored_libraries.each do |library|
        #   archs = `lipo -info #{library}`.split & archs
        # end
        archs
      end

      def compile
        defines = "GCC_PREPROCESSOR_DEFINITIONS='$(inherited)'"
        defines += ' '
        defines += @spec.consumer(@platform).compiler_flags.join(' ')

        options = ios_build_options
        xcodebuild(defines, options)

        defines
      end

      def target_name
        if @spec.available_platforms.count > 1
          "#{@spec.name}-#{Platform.string_name(@spec.consumer(@platform).platform_name)}"
        else
          @spec.name
        end
      end

      def xcodebuild(defines = '', args = '', build_dir = 'build')
        command = "xcodebuild #{defines} #{args} CONFIGURATION_BUILD_DIR=#{build_dir} clean build -configuration Release -target #{target_name} -project ./Pods.xcodeproj 2>&1"
        output = `#{command}`.lines.to_a

        if $CHILD_STATUS.exitstatus != 0
          raise <<~EOF
            Build command failed: #{command}
            Output:
            #{output.map { |line| "    #{line}" }.join}
          EOF

          Process.exit
        end
      end

      def expand_paths(path_specs)
        path_specs.map do |path_spec|
          Dir.glob(File.join(@source_dir, path_spec))
        end
      end

      def framework
        @framework ||= begin
          framework = Framework.new(@spec.name, @platform.name.to_s)
          framework.make
          framework
        end
      end
    end
  end
end
