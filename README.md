# Mac Task Manager

A native SwiftUI system monitor inspired by Windows Task Manager. It shows Mac hardware details, live CPU, memory and network usage, one-minute performance graphs, and a searchable list of processes. Select a process to send it a termination signal.

## Build

Requires macOS 14 or later and Xcode command-line tools.

```sh
swift build -c release
```

To create the app bundle and disk image on macOS, run `./package-dmg.sh`.

Process data is read using macOS system APIs. macOS may hide details for protected processes; ending a process may require administrator permissions. Network throughput is measured from interface byte counters.
