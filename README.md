# Yes, HotReloading for Swift & Objective-C

The [InjectionIII](https://github.com/johnno1962/InjectionIII) app
available as a Swift Package.

To use, add this repo as a Swift Package to your project and add
the following `"Run Script"`  `"Build Phase`":

```
$SYMROOT/../../SourcePackages/checkouts/HotReloading/start_daemon.sh
```

You should see a message that the app has connected and which
directories it is watching for source file changes. This script also
patches your project slightly to add the required `"-Xlinker -interposable"` "Other Linker Flags" so you will
have to run the project a second time after adding `HotReloading`
and the daemon script build phase for hot reloading to start working.

Consult the REAME of the [InjectionIII](https://github.com/johnno1962/InjectionIII) project for more information in paticular how to use it to inject `SwiftUI`.
It's the same code but you no longer need to run download or
run the app.

To work on the hot reloading code, clone this repo and drag its 
directory into your project in Xcode and it will take the place of
the Swift Package when you build your app.

$Date: 2021/02/25 $

