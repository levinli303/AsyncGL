Pod::Spec.new do |spec|
  spec.name         = "AsyncGL"
  spec.version      = "1.0.8"
  spec.summary      = "A framework that allows rendering OpenGL (ES) contents on an NSThread."
  spec.homepage     = "https://github.com/levinli303/AsyncGL.git"
  spec.license      = "MIT"
  spec.author             = { "Levin Li" => "lilinfeng303@outlook.com" }

  spec.ios.deployment_target = "14.0"
  spec.tvos.deployment_target = "14.0
  spec.osx.deployment_target = "11.0"
  spec.visionos.deployment_target = "1.0"

  spec.source       = { :git => "https://github.com/levinli303/AsyncGL.git", :tag => "#{spec.version}" }

  spec.subspec 'OpenGL' do |subspec|
    subspec.source_files = "AsyncGL/**/*.{h,m}"
    subspec.public_header_files = "AsyncGL/include/*.h"
  end

  spec.subspec 'libGLESv2' do |subspec|
    subspec.vendored_frameworks = "XCFrameworks/libGLESv2.xcframework"
  end

  spec.subspec 'libEGL' do |subspec|
    subspec.vendored_frameworks = "XCFrameworks/libEGL.xcframework"
  end

  spec.subspec 'ANGLE' do |subspec|
    subspec.dependency 'AsyncGL/libGLESv2', "#{spec.version}"
    subspec.dependency 'AsyncGL/libEGL', "#{spec.version}"
    subspec.source_files = "AsyncGL/**/*.{h,m}"
    subspec.public_header_files = "AsyncGL/include/*.h"
  end
end
