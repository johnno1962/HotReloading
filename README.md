# Yes, HotReloading for Swift, Objective-C & C++!

Note: While this was once a way of using the InjectionIII.app on real devices
and for its development you would not normally need to use this repo any 
more as you can use the pre-built bundles using the `copy_bundle.sh` 
script. It has also been largely superseded by the newer and simpler 
[InjectionNext](https://github.com/johnno1962/InjectionNext) project.
You should only add the HotReloading product to your main target.

This project is the [InjectionIII](https://github.com/johnno1962/InjectionIII) app
for live code updates available as a Swift Package. i.e.:

![Icon](http://johnholdsworth.com/HotAdding.png)

Then, you can inject function implementations without having to rebuild your app...
![Icon](http://johnholdsworth.com/HotReloading.png)

To try out an example project that is already set-up, clone this fork of
[SwiftUI-Kit](https://github.com/johnno1962/SwiftUI-Kit).

To use on your project, add this repo as a Swift Package and add 
"Other Linker Flags": -Xlinker -interposable. You no longer need
to add a "Run Script" build phase. If want to inject on a device, 
see the notes below on how to configure the InjectionIII app.
Note however, on an M1/M2 Mac this project only works with 
an iOS/tvOS 14 or later simulator. Also, due to a quirk of how
Xcode how enables a DEBUG build of Swift Packages, your 
"configuration" needs to contain the string "Debug".

***Remember not to release your app with this package configured.***

You should see a message that the app is watching for source file 
changes in your home directory. You can change this scope by
adding comma separated list in the environment variable
`INJECTION_DIRECTORIES`.  Should you want to connect to the 
InjectionIII.app when using the simulator, add the environment 
variable `INJECTION_DAEMON` to your scheme.

Consult the README of the [InjectionIII](https://github.com/johnno1962/InjectionIII)
project for more information in particular how to use it to inject `SwiftUI` using the
[HotSwiftUI](https://github.com/johnno1962/HotSwiftUI) protocol extension.

### HotReloading using VSCode

It's possible to use HotReloading from inside the VSCode editor and realise a
form of "VScode Previews". Consult [this project](https://github.com/markst/hotreloading-vscode-ios) for the setup required.

### Device Injection

This version of the HotReloading project and it's dependencies now support
injection on a real iOS or tvOS device. 

Device injection now connects to the [InjectionIII.app](https://github.com/johnno1962/InjectionIII)
([github release](https://github.com/johnno1962/InjectionIII/releases)
4.6.0 or above) and requires you type the following commands into a Terminal 
then restart the app to opt into receiving remote connections from a device:

    $ rm ~/Library/Containers/com.johnholdsworth.InjectionIII/Data/Library/Preferences/com.johnholdsworth.InjectionIII.plist
    $ defaults write com.johnholdsworth.InjectionIII deviceUnlock any
    
Note, if you've used the App Store version of InjectionIII in the past,
the binary releases have a different preferences file and the two can
get confused and prevent writing this preference from taking effect.
This is why the first `rm` command above can be necessary. If your
device doesn't connect check the app is listening on port `8899`:

```
% netstat -an | grep LIST | grep 88
tcp4       0      0  127.0.0.1.8898         *.*                    LISTEN
tcp4       0      0  *.8899                 *.*                    LISTEN
```
If your device still doesn't connect either add an `INJECTION_HOST`
environment variable to your scheme containg the WiFi IP address of
the host you're running the InjectionIII.app on or clone this project and 
code your mac's IP address into the  `hostname` variable in Package.swift.
Then, drag the clone onto your project to have it take the place of the
configured Swift Package as outlined in [these instructions](https://developer.apple.com/documentation/xcode/editing-a-package-dependency-as-a-local-package).

Note: as the HotReloading package needs to connect a network
socket to your Mac to receive commands and new versions of code, expect
a message the first time you run your app after adding the package
asking you to "Trust" that your app should be allowed to do this.
Likewise, at the Mac end (as the InjectionIII app needs to open
a network port to accept this connection) you may be prompted for
permission if you have the macOS firewall turned on.

For `SwiftUI` you can force screen updates by following the conventions 
outlined in the [HotSwiftUI](https://github.com/johnno1962/HotSwiftUI) 
project then you can experience something like "Xcode Previews", except 
for a fully functional app on an actual device!

### Vapor injection

To use injection with Vapor web server,  it is now possible to just
download the [InjectionIII.app](https://github.com/johnno1962/InjectionIII)
and add the following line to be called as the server configures
(when running Vapor from inside Xcode): 

```
    #if DEBUG && os(macOS)
    Bundle(path: "/Applications/InjectionIII.app/Contents/Resources/macOSInjection.bundle")?.load()
    #endif
```
It will also be necessary to add the following argument to your targets:

 ```
     linkerSettings: [.unsafeFlags(["-Xlinker", "-interposable"],
             .when(platforms: [.macOS], configuration: .debug))]
 ```
As an alternative, you can add this Swift package as a dependency to Vapor's 
Package.swift of the "App" target.

### Thanks to...

The App Tracing functionality uses the [OliverLetterer/imp_implementationForwardingToSelector](https://github.com/OliverLetterer/imp_implementationForwardingToSelector) trampoline implementation
via the [SwiftTrace](https://github.com/johnno1962/SwiftTrace) project under an MIT license.

SwiftTrace uses the very handy [https://github.com/facebook/fishhook](https://github.com/facebook/fishhook)
as an alternative to the dyld_dynamic_interpose dynamic loader private api. See the
 project source and header file included in the framework for licensing details.

The ["Remote"](https://github.com/johnno1962/Remote) server in this project which
allows you to capture videos from your device includes code adapted from
[acj/TimeLapseBuilder-Swift](https://github.com/acj/TimeLapseBuilder-Swift)

This release includes a very slightly modified version of the excellent
[canviz](https://code.google.com/p/canviz/) library to render "dot" files
in an HTML canvas which is subject to an MIT license. The changes are to pass
through the ID of the node to the node label tag (line 212), to reverse
the rendering of nodes and the lines linking them (line 406) and to
store edge paths so they can be coloured (line 66 and 303) in "canviz-0.1/canviz.js".

It also includes [CodeMirror](http://codemirror.net/) JavaScript editor for
the code to be evaluated in the Xprobe browser under an MIT license.

$Date: 2025/08/03 $
