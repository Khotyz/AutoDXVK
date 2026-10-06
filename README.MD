# 🎮 Auto DXVK

**Auto DXVK** is a free, open source graphical installer that puts [**DXVK**](https://github.com/doitsujin/dxvk) into your Windows games with a few clicks. Pick a release, choose the game executable, and the app detects the architecture and DirectX version automatically, then copies the correct DLL files into the game folder. It also keeps a backup of anything it replaces, so reverting is a single step.

---

## 🚀 How to Run

### One-line online (recommended)

Open **PowerShell** and paste:

```powershell
irm https://raw.githubusercontent.com/Khotyz/AutoDXVK/refs/heads/main/AutoDXVK.ps1 | iex
```

This downloads the latest version and the language files to a temporary folder (with automatic fallback to mirror URLs, UTF-8 BOM cleanup and a syntax check before launching), requests administrator privileges through the standard UAC prompt, and starts the interface. Nothing is installed permanently and the temporary files are overwritten on the next run.

### Manual install

* Clone the repository or download the source.
* Open PowerShell in the project folder and run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\AutoDXVK.ps1
```

> **⚠️️ Important:** Games installed in protected folders such as `C:\Program Files` require administrator rights. The script auto elevates when needed.

---

## ❓ Why use it

* No manual extraction, no hunting for the right DLL files.
* Detects whether the game is 32 bit or 64 bit.
* Detects the DirectX version the game actually uses, including Unity and Unreal Engine titles whose main `.exe` is only a launcher.
* Keeps a backup of any DLL it replaces, so reverting is a single step.
* Interface available in English, Portuguese (Brazil), and Spanish.

---

## 🛠️ How to use

1. **Select the DXVK version.** The list shows the five most recent releases from GitHub. The Refresh button reloads the list.
2. **Click Browse** and select the game executable. The app shows the architecture, the detected DirectX version, and the DLL files that will be installed.
3. **Click Install DXVK.** The app downloads the package, extracts it, backs up any existing DLL, and copies the new files into the game folder.

That is all. Restart the game and it will run through DXVK.

---

## ⚙️ What the app does under the hood

* Downloads the selected `.tar.gz` into `Downloads\Auto DXVK\` and extracts it there. The folder is kept after installation so you can inspect or reuse the files.
* If DLL files already exist in the game folder, asks for confirmation before overwriting and saves the originals under `DXVK_Backup`. An existing backup is never overwritten.
* Creates an empty `dxvk.conf` in the game folder if one does not already exist.
* Shows a Windows toast notification when the installation completes, with a standard dialog as a fallback.

---

## 🗂️ Supported DirectX versions

| Detected API | DLL files copied |
| --- | --- |
| **D3D8** | d3d8.dll |
| **D3D9** | d3d9.dll |
| **D3D10 / D3D10.1** | d3d10.dll, d3d10_1.dll, d3d10core.dll, dxgi.dll |
| **D3D11** | d3d11.dll, dxgi.dll |
| **D3D12** | d3d12.dll, dxgi.dll |

*Only the DLL files that exist in the downloaded package are copied. See the limitations below for details on D3D12.*

---

## 🔍 How the API detection works

Detection runs through a chain of methods and stops at the first one that identifies the API. The method used is shown in the **Detected via** field of the interface.

1. **Executable import table:** the PE import and delay-import tables are parsed directly, which gives the exact list of linked libraries.
2. **Library name scan:** the binary is scanned for DLL names in ASCII and UTF-16, which covers libraries loaded dynamically with `LoadLibrary`.
3. **API function signatures:** the binary is scanned for entry points such as `D3D11CreateDevice`, `D3D12CreateDevice`, `D3D10CreateDevice1`, `Direct3DCreate9` and `Direct3DCreate8`.
4. **Related game binaries:** when the selected file is only a launcher, steps 1 to 3 are repeated on `UnityPlayer.dll`, `*-Shipping.exe` files, sibling executables, `Binaries\Win64` and `Binaries\Win32` folders, and renderer or engine style DLLs in the game folder.
5. **Game folder files:** managed wrappers such as `SharpDX.Direct3D11.dll`, `Vortice.*`, `Silk.NET.*` and XNA, existing `d3d*.dll` wrappers, and `d3dx9_*`, `d3dx10_*`, `d3dx11_*` runtime files.
6. **Unity player log:** `Player.log` in `AppData\LocalLow` is read for the graphics device the game actually initialized.
7. **Unreal Engine config:** `DefaultGraphicsRHI` is read from `DefaultEngine.ini` and related files.
8. **Legacy D3DX references:** weak string hints such as `d3dx9_` found inside the binaries.
9. **DXGI only:** if the only evidence is `dxgi.dll` or `CreateDXGIFactory`, D3D11 is assumed.
10. **Running game process:** if the game is currently running, the modules loaded in the process are inspected. This is the last resort because overlays can load extra Direct3D libraries.

When a game references multiple DirectX APIs, D3D11 takes precedence over D3D12. This matches the case of Unity and Unreal Engine titles, which often expose both APIs but render through D3D11 on most configurations.

---

## ✅ Requirements

* Windows 10 (1809 through 22H2) or Windows 11 (all versions)
* Windows PowerShell 5.1, included in the operating system. PowerShell 7 is not required.
* .NET Framework 4.7.2 or later, already included in the versions above
* `tar.exe` from Windows, available since Windows 10 1803
* Internet access for querying the GitHub API and downloading DXVK
* A GPU and driver with Vulkan support

---

## 📁 Project structure

```
AutoDXVK/
├── AutoDXVK.ps1
├── lang/
│   ├── en.json
│   ├── pt-br.json
│   └── es.json
├── .gitignore
└── README.md
```

*The `lang` folder must reside next to `AutoDXVK.ps1`.*

---

## 📦 Packaging as a standalone executable

If you prefer a single `.exe` with no PowerShell window, use PS2EXE:

```powershell
Install-Module ps2exe -Scope CurrentUser
Invoke-PS2EXE .\AutoDXVK.ps1 .\AutoDXVK.exe -noConsole -STA
```

*Keep the `lang` folder next to the generated `.exe`.*

---

## 🎨 Appearance

The interface adapts to the version of Windows and to the current system theme:

* **Windows 11:** Mica backdrop and rounded corners through DWM. On builds earlier than 22621 the app attempts the alternative Mica attribute.
* **Windows 10:** solid light or dark background matching the system theme, without Mica.
* Accent color is read from the system, with a fallback to `#0078D4`.

---

## 🚧 Known limitations

* **Executables that are packed or protected:** DirectX detection reads DLL names inside the file. Executables protected by packers, DRM, or dynamic loading may not reveal the API. In that case the app warns you and does not allow installation.
* **Text based detection:** Games that reference multiple APIs at once may be classified differently from the one actually used at runtime.
* **Direct3D 12:** DXVK does not implement D3D12. That is the role of vkd3d-proton. DXVK packages do not include `d3d12.dll`, so installation for D3D12 games is interrupted with an explanatory message.
* **Direct3D 8:** `d3d8.dll` is only present in recent DXVK releases. On older versions, select a different release.
* **Direct3D 10:** In DXVK 2.x, `d3d10.dll` and `d3d10_1.dll` do not exist, and `d3d10core.dll` depends on `d3d11.dll`. In this case the app also copies `d3d11.dll` from the package.
* **Anti-cheat:** Games with anti-cheat may block or ban DLL modifications. Use at your own risk.
* **GitHub rate limit:** The public API limits unauthenticated requests. When the API fails, the release list falls back to the repository's Atom feed automatically.
* **Reverting changes:** To uninstall, restore the files from `DXVK_Backup` or delete the copied DLL files.

---

## 🔧 Troubleshooting

* **The online command fails:** Make sure the repository is public and that `AutoDXVK.ps1` is saved as UTF-8 without BOM. A BOM breaks `irm | iex` in Windows PowerShell 5.1.
* **The script does not start:** Open PowerShell and run `Get-ExecutionPolicy`. If it returns `Restricted`, use the one-line command in the How to Run section, which sets the policy only for the current process.
* **Language files not found:** Make sure the `lang` folder sits next to `AutoDXVK.ps1` and contains `en.json`, `pt-br.json`, and `es.json`.
* **The app cannot detect the DirectX version:** The executable may be packed or may belong to a launcher. Try selecting the real rendering executable inside the game folder, often under `Binaries\Win64` for Unreal Engine or next to `UnityPlayer.dll` for Unity.
* **Copy fails with an access error:** The game is in a protected folder. Close the game and run PowerShell as administrator, then try again.

---

## 📄 License

Distributed under the MIT License. See the [**DXVK**](https://github.com/doitsujin/dxvk) project for its own license terms.

---

## 🌟 Credits

* [**DXVK**](https://github.com/doitsujin/dxvk) by Philip Rebohle and contributors.
* [**vkd3d-proton**](https://github.com/HansKristian-Work/vkd3d-proton), the recommended option for Direct3D 12 games.
