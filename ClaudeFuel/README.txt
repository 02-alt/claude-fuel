TOKEN FUEL — Claude usage as a fuel gauge
=========================================

A tiny menu-bar app that shows how much of your Claude token budget is left,
styled like a real pager/beeper. It reads your local Claude usage from ~/.claude.

INSTALL
-------
1. Unzip this file.
2. Drag "ClaudeFuel.app" into your Applications folder.

FIRST LAUNCH (important — it's not from the App Store)
------------------------------------------------------
macOS will block it the first time because it isn't notarized. To open it:

  • Right-click (or Control-click) ClaudeFuel.app  ->  Open  ->  Open.

If macOS still refuses ("can't be verified"):

  • Open System Settings -> Privacy & Security, scroll down, and click
    "Open Anyway" next to ClaudeFuel, then launch it again.

If macOS says the app is "DAMAGED and can't be opened":
That's just the download quarantine on an app that isn't notarized — it is NOT
actually damaged. Fix it in one line: open Terminal and run (adjust the path if
you didn't move it to Applications):

  xattr -dr com.apple.quarantine /Applications/ClaudeFuel.app

Then open it normally. You only have to do this once.

USING IT
--------
• It lives in the menu bar (no Dock icon). Click the icon to open the gauge.
• Buttons: STATS, SETTINGS, and POP OUT (a floating mini window you can keep on
  top; close it with the small x in its top-right corner).
• Tap the screen to toggle large-print mode.
• SETTINGS -> THEME cycles the looks (Pager, Noir, OP-1, PS2, Xbox, clear cases,
  and a high-contrast Clarity theme).

REQUIREMENTS
------------
• Apple Silicon Mac (arm64).
• Uses Claude's local usage files in ~/.claude; live percentages need you to be
  signed in to Claude on this Mac.


-----------------------------------------------------------------------

Thanks for giving it a spin. Really -- it means a lot. <3

Built with care by buildtoberemembered.

And a quiet thank you to my friends and my brothers -- the ones who
helped me get through life.

And hey -- if you make something, remix it, or just want to share
whatever you're building, come find us on the Discord. We'd love to
see it.

-- buildtoberemembered
