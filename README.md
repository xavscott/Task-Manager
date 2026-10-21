MacTaskManager
<img width="1068" height="791" alt="image" src="https://github.com/user-attachments/assets/afbf6cda-54ba-4b0c-b5be-68b2ec33a95a" />
<img width="1068" height="793" alt="image" src="https://github.com/user-attachments/assets/dcb8e8f4-d6f6-464f-a81a-c88b3624f898" />
<img width="767" height="415" alt="image" src="https://github.com/user-attachments/assets/429d8728-b4da-4e00-ad9b-2bb424e907c1" />
<img width="1070" height="785" alt="image" src="https://github.com/user-attachments/assets/b69162af-7c88-45b5-b4dc-c0d1a219ec3f" />
<img width="646" height="542" alt="image" src="https://github.com/user-attachments/assets/49980f1c-c757-471a-8432-4ecbeb7c3c10" />

A Windows Task Manager–style system monitor for macOS, built entirely in SwiftUI. It combines live performance graphs, a sortable process list, and detailed hardware info in a single fixed-size window styled with Liquid Glass on macOS 26. Its standout feature is a floating performance overlay: a compact, always-on-top glass panel that keeps your CPU, GPU, memory, temperature, and power draw visible while you work, game, or watch fullscreen video. It floats above fullscreen apps, follows you across Spaces, can be dragged anywhere on screen, and has adjustable glass opacity (35% to 100%) so it blends in with whatever is behind it. Beyond the overlay, the app offers real-time 60-second graphs for CPU, memory, disk, network, GPU, energy, and thermals, a searchable process list with an End Task action, system and hardware details, battery levels for connected Apple accessories (including per-bud and case levels for AirPods), startup item and local user listings, and Auto/Light/Dark appearance with selectable accent colors.

Requirements: macOS 14 or later (Liquid Glass requires macOS 26), Xcode 15 or later. Apple Silicon recommended; some sensors may be unavailable on certain Macs.

Build: Open the project in Xcode, select the MacTaskManager scheme, and press ⌘R.

Notes: Thermal readings and some Bluetooth battery data rely on private interfaces and may change between macOS releases. Ending a process sends SIGTERM; protected processes may require administrator privileges.

```sh
./package-dmg.sh
```

The command creates both `Mac Task Manager.dmg` and `Mac Task Manager.pkg`. Use the `.pkg` when you want startup registration to happen automatically after installation; its post-install step starts the app hidden so it can register the background monitor without showing the Task Manager window. A normal click on the app opens the UI. If you use the disk image, launch the copied app once manually. The monitor then starts automatically after subsequent logins and reboots. The “Mac Task Manager” widget will then be available from the macOS widget gallery. Widget refresh timing is managed by macOS.

The installer registers the accessory monitor as a background Login Agent and starts it without opening the Task Manager window. macOS starts and keeps this helper running automatically after subsequent logins and reboots. If it has been disabled, enable “Mac Task Manager Accessory Monitor” under System Settings → General → Login Items. A normal click on the app opens the Task Manager UI.

Process data is read using macOS system APIs. macOS may hide details for protected processes; ending a process may require administrator permissions. Network throughput is measured from interface byte counters.
