# Yes, HotReloading for Swift, Objective-C & C++!

The [InjectionIII](https://github.com/johnno1962/InjectionIII) app
available as a Swift Package. i.e.:

![Icon](http://johnholdsworth.com/HotAdding.png)

Then you can do this ...
![Icon](http://johnholdsworth.com/HotReloading.png)

To try out an example project that is already set-up, clone this fork of
[SwiftUI-Kit](https://github.com/johnno1962/SwiftUI-Kit).

To use on your project, add this repo as a Swift Package to your project and add
the following `"Run Script"`  `"Build Phase`" to run the HotReloading daemon:

```
if [ -d $SYMROOT/../../SourcePackages ]; then
    $SYMROOT/../../SourcePackages/checkouts/HotReloading/start_daemon.sh
elif [ -d "$SYMROOT"/../../../../../SourcePackages ]; then
    "$SYMROOT"/../../../../../SourcePackages/checkouts/HotReloading/fix_previews.sh
fi
```

You should see a message that the app has connected and which
directories it is watching for source file changes. The daemon also
has an icon on the menu bar you can use to access features such as tracing
and remote control. This script also patches your project slightly to add the 
required `"-Xlinker -interposable"` "Other Linker Flags" so you will
have to run the project a second time after adding the `HotReloading`
package and and the script build phase for hot reloading to start working.

Consult the REAME of the [InjectionIII](https://github.com/johnno1962/InjectionIII)
project for more information in paticular how to use it to inject `SwiftUI` using the
[HotSwiftUI](https://github.com/johnno1962/HotSwiftUI) protocol extension. It's
the same code but you no longer need to download or run the app and the project
is selected automatically.

If you want to work on the hot reloading code, clone this repo and drag
its directory into your project in Xcode and it will take the place of the
configured HotReloading Swift Package when you build your app.

### Device Injection

This version of the HotReloading project and it's dependencies now support
injection on a real iOS or tvOS device. It's early days and this version
should be considered very much beta software. The binary framework from
the InjectionScratch repo that makes this possible is time limited for 
now to expire on April 13th 2022 until I find a more reasonable licensing 
solution should people find it useful. If your device doesn't connect, 
clone this project and configure your mac's WiFi IP address into the 
`hostname` variable in Package.swift. Then drag the clone onto your 
project to have it take the place of the configured Swift Package.

As Swift plays its cards pretty close to its chest it's not possible
to initialise type meta data entirely correctly so your milage may vary
more than using HotReloading in the simulator. In particular if injected
code crashes, the debugger will not display the line number but an address
under symbol  "injected_code" instead. If you get stuck, use an 
`@_exported import HotReloading` in a source file and you should be 
able to type `p HotReloading.stack` to at least get a stack trace.

Also note that, as the HotReloading package needs to connect a socket
to your Mac to receive commands and new versions of code, expect a
message the first time you run your app after adding the package
asking you to "Trust" that your app should be allowed to do this.
Likewise, at the Mac end as the HotReloading deamon needs to open
a network port to accept this connection you may be prompted for
permission if you have the macOS firewall turned on.

In testing it's been performing well but one problem I did encounter was 
using SwiftUI where you inject two structs conforming to View in the same 
file which currently crashes. If you avoid this however and use the 
conventions outlined in the [HotSwiftUI](https://github.com/johnno1962/HotSwiftUI) 
project you can experience interactive screen updates something like
"Xcode Previews", except for a fully functional app on an actual device!

### Vapour injection

To use injection with Vapour web server, add this Swift package as a
dependency to its Package.swift and as dependency of the "App" target
then run vapour from inside Xcode. It will ask you to run a script to start
the associated daemon processes which watches for source file changes
from inside project directory. It's not possible to inject closures that have
already been registered with routes but if you delegate their implementation
to the method of a class it can be injected. If you want to delegate to a top
level method or the method of a struct you'll need to add the following to
the executable target to enable "interposing":

```
    , linkerSettings: [
        .unsafeFlags(["-Xlinker", "-interposable"])]
```
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

$Date: 2022/02/10 $
