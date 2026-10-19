# Mac Task Manager

A native SwiftUI system monitor inspired by Windows Task Manager. It shows Mac hardware details, live CPU, memory and network usage, one-minute performance graphs, and a searchable list of processes. Select a process to send it a termination signal.

## Build

Requires macOS 14 or later and Xcode command-line tools. The Xcode project includes the WidgetKit extension; use it to build the app with its widget.

```sh
./package-dmg.sh
```

Install the app from the generated disk image and launch it once. The “Mac Task Manager” widget will then be available from the macOS widget gallery. Widget refresh timing is managed by macOS.

Process data is read using macOS system APIs. macOS may hide details for protected processes; ending a process may require administrator permissions. Network throughput is measured from interface byte counters.
