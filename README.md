# Yes, HotReloading for Swift, Objective-C & C++!

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
injection on a real iOS or tvOS device. It's early days and this version
should still be considered alpha software. If your device doesn't connect, 
clone this project and configure your mac's WiFi IP address into the 
`hostname` variable in Package.swift. Then drag the clone onto your 
project to have it take the place of the configured Swift Package.

Device injection now connects to the [InjectionIII.app](https://github.com/johnno1962/InjectionIII)
([github release](https://github.com/johnno1962/InjectionIII/releases)
4.2.8 or above) and requires you type the following command into a Terminal 
then restart the app to opt into receiving remote connections from a device:

    $ defaults write com.johnholdsworth.InjectionIII deviceUnlock any

As Swift plays its cards pretty close to its chest it's not quite possible
to initialise type meta data entirely correctly so your milage may vary
more than using HotReloading in the simulator. In particular, if injected
code crashes, the debugger will not display the line number but an address
under the symbol  "injected_code" instead. If you get stuck, use an 
`@_exported import HotReloading` in a source file and you should be 
able to type `p HotReloading.stack` to get a stack trace.

Also note that, as the HotReloading package needs to connect a network
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

To use injection with Vapor web server, add this Swift package as a
dependency to its Package.swift and as dependency of the "App" target
then run vapour from inside Xcode. It will ask you to run a script to start
the associated daemon processes which watches for source file changes
from inside project directory. It's not possible to inject closures that have
already been registered with routes however but if you delegate their 
implementation to the method of a class it can be injected.

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

$Date: 2022/08/31 $
