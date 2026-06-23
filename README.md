# ariankordi.OpenCvSharp4.iOS

This is a vibe-coded fork that builds OpenCvSharp to target .NET MAUI on iOS. See the  [upstream's README](https://github.com/shimat/opencvsharp) for more details on this library.

If you need Android, that is covered by [sdcb/opencvsharp-mini-runtime](https://github.com/sdcb/opencvsharp-mini-runtime).

**Please note**: this package is a **full replacement** for `OpenCvSharp4` that also includes the native runtime.

This has the downside of not being usable with any packages that transitively include `OpenCvSharp4`. See [Future](#future) for a cleaner approach with any future changes.

## Usage

Because this package replaces `OpenCvSharp4` only for iOS, for cross-platform MAUI apps you will want to configure your csproj like so:

```xml
    <!-- OpenCvSharp4 managed assembly. This is to be excluded on iOS. -->
    <ItemGroup Condition="!$(TargetFramework.Contains('-ios'))">
      <PackageReference Include="OpenCvSharp4" Version="4.13.0.20260602" />
    </ItemGroup>
    <!-- OpenCvSharp iOS package: provides both OpenCvSharp4 and the runtime. -->
    <ItemGroup Condition="$(TargetFramework.Contains('-ios'))">
      <PackageReference Include="ariankordi.OpenCvSharp4.iOS" Version="4.13.0.20260623" />
    </ItemGroup>
    <!-- Other platforms: Use Sdcb mini runtime for Android, then Windows runtime for PC. -->
    <ItemGroup Condition="$(TargetFramework.Contains('-android'))">
      <PackageReference Include="Sdcb.OpenCvSharp4.mini.runtime.android-arm64" Version="4.13.0.45" />
      <PackageReference Include="Sdcb.OpenCvSharp4.mini.runtime.android-x64" Version="4.13.0.45" />
    </ItemGroup>
    <ItemGroup Condition="$(TargetFramework.Contains('-windows'))">
      <PackageReference Include="OpenCvSharp4.runtime.win" Version="4.13.0.20260602" />
    </ItemGroup>
```


## Caveats

* This package targets `net9.0-ios` to reflect an existing project. If this doesn't work for you, it'll have to be fixed.
* Only arm64 iPhone Simulator is supported, so Intel Mac users will need to rebuild.
* This is a **minimal build**. Only essential OpenCV modules are included: `core`, `imgproc`, `imgcodecs`. If you need more, fork this repo and rebuild.

All other modules have been STUBBED and may fail silently. You have been warned!

The build script can be modified here: [src/tools/build-opencvsharp-ios.sh](src/tools/build-opencvsharp-ios.sh)

## Future

I would recommend merging the change required to statically link the library for iOS upstream (changing DllExtern to `__Internal`), and then adding iOS to the CI/CD of [opencvsharp-mini-runtime](https://github.com/sdcb/opencvsharp-mini-runtime).

This repo was just made to unblock progress on a work project, otherwise I would've preferred a cleaner approach.