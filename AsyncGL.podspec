Pod::Spec.new do |spec|
  spec.name         = "AsyncGL"
  spec.version      = "0.0.13"
  spec.summary      = "A framework that allows rendering OpenGL (ES) contents on a GCD dispatch queue."
  spec.homepage     = "https://github.com/levinli303/AsyncGL.git"
  spec.license      = "MIT"
  spec.author             = { "Levin Li" => "lilinfeng303@outlook.com" }

  spec.ios.deployment_target = "8.0"
  spec.osx.deployment_target = "10.9"

  spec.source       = { :git => "https://github.com/levinli303/AsyncGL.git", :tag => "#{spec.version}" }

  spec.source_files = ["AsyncGL/**/*.{h,m}", "GL/**/*.{h,inc}"]
  spec.public_header_files = "AsyncGL/include/*.h"

  spec.xcconfig     = {
    'HEADER_SEARCH_PATHS' => [
      '"$(PODS_TARGET_SRCROOT)/GL"'
    ]
  }
end
