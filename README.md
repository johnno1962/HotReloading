# Yes, HotReloading for Swift & Objective-C

The [InjectionIII](https://github.com/johnno1962/InjectionIII) app
available as a Swift Package. i.e.:

![Icon](http://johnholdsworth.com/HotAdding.png)

Then you can do this...
![Icon](http://johnholdsworth.com/HotReloading.png)

To use, add this repo as a Swift Package to your project and add
the following `"Run Script"`  `"Build Phase`":

```
if [ -d $SYMROOT/../../SourcePackages ]; then
    $SYMROOT/../../SourcePackages/checkouts/HotReloading/start_daemon.sh
fi
```

You should see a message that the app has connected and which
directories it is watching for source file changes. This script also
patches your project slightly to add the required `"-Xlinker -interposable"` "Other Linker Flags" so you will
have to run the project a second time after adding `HotReloading`
and the daemon script build phase for hot reloading to start working.

Consult the REAME of the [InjectionIII](https://github.com/johnno1962/InjectionIII)
project for more information in paticular how to use it to inject `SwiftUI` using the
[HotSwiftUI](https://github.com/johnno1962/HotSwiftUI) protocol extension. It's
the same code but you no longer need to download or run the app and the project
is selected automatically.

If you want to work on the hot reloading code, clone this repo and drag
its directory into your project in Xcode and it will take the place of the
configured HotReloading Swift Package when you build your app.

### Thanks to...

The App Tracing functionality uses the [OliverLetterer/imp_implementationForwardingToSelector](https://github.com/OliverLetterer/imp_implementationForwardingToSelector) trampoline implementation
via the [SwiftTrace](https://github.com/johnno1962/SwiftTrace) project under an MIT license.

SwiftTrace uses the very handy [https://github.com/facebook/fishhook](https://github.com/facebook/fishhook)
as an alternative to dyld_dynamic_interpose. See the project source and header
file included in the app bundle for licensing details.

This project includes code for video capture adapted from
[acj/TimeLapseBuilder-Swift](https://github.com/acj/TimeLapseBuilder-Swift)

This release includes a very slightly modified version of the excellent
[canviz](https://code.google.com/p/canviz/) library to render "dot" files
in an HTML canvas which is subject to an MIT license. The changes are to pass
through the ID of the node to the node label tag (line 212), to reverse
the rendering of nodes and the lines linking them (line 406) and to
store edge paths so they can be coloured (line 66 and 303) in "canviz-0.1/canviz.js".

It also includes [CodeMirror](http://codemirror.net/) JavaScript editor for
the code to be evaluated in the Xprobe browser under an MIT license.

$Date: 2021/03/06 $
