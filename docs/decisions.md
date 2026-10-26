# Decisions

## Native macOS and local-only behavior

- Use Swift and SwiftUI, with AppKit for menu-bar integration and other native APIs. Target macOS 26 and newer; the app shows a Dock icon only while its main window is open.
- The menu-bar panel stays open until the person closes it (×, Esc or the menu-bar icon), so picking files up in Finder doesn't close it. Files can also be dropped on the menu-bar icon.
- Runtime file handling, preferences, learning, metadata and content inspection stay on the Mac. No cloud processing, analytics, or upload of files, names, or contents. GitHub is used only for authorized source, CI, and app releases—not personal files. From 2.5.0 the app also asks GitHub whether a newer version of itself exists (Sparkle); that request carries no file information.
- Apple Intelligence uses only `SystemLanguageModel.default` (on-device). Never Private Cloud Compute or another hosted model, not even as a fallback. Reading inside files (PDF/document text, Vision text recognition and image classification, download source) is on by default and can be turned off; long digit runs are hidden from the model.

## Approval and file safety

- Files the app is sure about are moved automatically into existing favorite folders (setting, on by default): rule matches, macOS screenshots, learned patterns (3+ distinct examples), and Apple Intelligence answers marked high confidence that are backed by contents or download source (or agree with a local hint). Each automatic move is listed in Activity with Undo, and announced by a notification for watched folders.
- Everything else is a suggestion. Renaming files, creating folders, and moving an eligible installer to Trash always require the user's explicit approval.
- Watched folders (Downloads, Desktop, chosen folders): only files that arrive after watching starts and have stopped changing for 20 seconds; partial downloads, hidden files and installers are never moved automatically.
- Never permanently delete files or empty Trash. Trash suggestions are a separate, unchecked review list, restricted to `.dmg` installers in Downloads whose matching `.app` is installed directly in `/Applications`.
- Undo restores moved files. It removes a newly created folder only when the app created it and that folder is empty.

## Suggestions and grouping

- Enforce a user's rule exactly, especially file-type conditions; a rule-constrained folder does not receive unrelated fallback suggestions.
- Prefer specific evidence over broad similarity. Screenshot identification uses macOS screen-capture metadata, with a `Screenshot… .png` filename as backup. Include a short reason for each suggestion; show no destination when confidence is weak.
- Learning needs repeated, distinct examples with a meaningful shared subject; only the person's own moves and approvals are learned, never the model's automatic moves. AI cannot override rules, choose a folder reserved by a rule, or send data off-device; answers that don't name exactly one existing folder are dropped.
- Favorite folders are specific save targets, not broad categories. Apple Intelligence may only choose a folder the person described with a "What goes here" note, must match that note (topic similarity is not enough), and its folder is kept only when it answers with high confidence; guesses are not shown. Folders without a note get files only from drag and drop, rules and the person's own learned moves.
- Suggest new folders only for files about one specific, named thing (a client, trip, class project or event), with a configurable minimum of four related files by default—never broad categories such as school, finance, research or documents, and not generic file types or dates alone. Apple Intelligence's group proposals are off by default and need at least four files. Let the user edit the name and approve before creating the folder.
- In Clean Up, only sure local matches (rules, screenshots, learned patterns) start checked; wording-only matches are shown as unchecked guesses.

## Build and distribution

- Use a standard macOS GitHub Actions runner to run tests, build the native `.app`, validate the exact extracted ZIP, and smoke-launch it. CI output is the source artifact for releases.
- README screenshots are real captures supplied by the maintainer and added in a docs change.
- Attach the tested ZIP and checksum sidecar to a versioned GitHub Release, then verify the public download against the CI checksum. An Actions artifact or successful compile alone is not the final user handoff.

## Name

- The app was called Quick Drop Zone until 2.5.2 and Levant from 2.6.0 to 2.8.0. Since 3.0.0 it is **EchoNyla**, a clean break: new bundle ID (`com.echoapps.echonyla`), Swift modules (`EchoNylaCore`, `EchoNylaApp`), executable, ZIP name, update address and `EchoNyla.*` settings keys. Nothing is carried over from Levant (only one person used it); the old Quick Drop Zone → Levant move was removed. The workflow name "macOS CI" and the check name `Test and package on macOS 26` stay as they were.

## Look and skins

- Skins change colors and the icon only; they never change how files are found, filed or renamed. EchoNyla has Verbyn's six skins with exactly Verbyn's colours: Signature (the default: Echo App Studio's black, charcoal and silver), Sky, Green, Turquoise, Bordeaux and Wisteria, each with a light and a dark version. Light or dark follows the Mac by default, or is always light or always dark.
- The palettes and the choice logic live in `EchoNylaCore` (`Skins.swift`) and are unit-tested, including readable contrast in every skin (Signature at 7:1 or better). The icon is a silver page dropping into a silver tray on Verbyn's black tile, drawn with the skin icons by `Scripts/make-icon-art.py`. Signature is the app's built-in icon; the app puts the skin's icon on itself in Finder and the Dock (`FinderIcon.swift`), and an update brings back the Signature icon until the next launch.
- The Apple Intelligence mark keeps the artwork's loops (`Resources/IntelligenceLoops.png`, cut from `IntelligenceMark.png` by `Scripts/make-intelligence-mask.py`) and draws them in the skin's colours.
- File type icons come from vscode-icons (CC BY-SA 4.0, credited in Acknowledgements). Mac file types (Pages, Numbers, Keynote, Mail, Calendar, Contacts, apps, ICNS, PLIST, aliases) are never copied into the app: they are drawn with macOS's own artwork at run time. Unknown types show their letters on macOS's blank page.
