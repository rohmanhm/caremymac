# dmgbuild settings for the CareMyMac disk image: the app beside an Applications link over the background from
# scripts/dmg-background.swift, which is drawn for this window size and these icon positions.
#
#   dmgbuild -s scripts/dmg-settings.py -D app=path/CareMyMac.app -D background=path/background.png \
#       CareMyMac CareMyMac-0.3.0.dmg
import os.path

app = defines["app"]  # noqa: F821 (dmgbuild provides defines)
background = defines["background"]  # noqa: F821
name = os.path.basename(app)

format = "ULFO"
filesystem = "APFS"
files = [app]
symlinks = {"Applications": "/Applications"}
icon_locations = {name: (165, 190), "Applications": (495, 190)}
hide_extensions = [name]
icon = os.path.join(app, "Contents/Resources/AppIcon.icns")

window_rect = ((200, 200), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
