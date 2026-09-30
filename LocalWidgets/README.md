# Local widgets build

These are the UI changes from `claude/combined-branch-merge-04k37p` as local widgets, so they run on
official Zero-K releases (online games, replays, spectating) without a modified game.

What's included:
- **Global Build Command v2**: the worker AI, Global Build List, eco/balanced/army presets, and terraform/height/wall jobs.
- **Energy grid**: queue a pylon/solar/wind grid, and the spot reach flags.
- **Missile Command Center**: missile launch commands and the Launch tab.
- **Unit Overlay GL4**: GPU health/status/reload bars, unit state icons, and the new radar icons for Zenith, Disco Rave Party, the missile silo and each silo missile.

## Install

1. Copy everything in this folder **except `tools/` and this README** into your Zero-K data
   directory, merging with what is there. You should end up with `<data dir>/LuaUI/Widgets/...`,
   `<data dir>/LuaUI/Configs/...`, `<data dir>/LuaUI/Images/...` and `<data dir>/icons/...`.
2. In game, open the local widgets config (Settings → Misc → Local Widget Config, or `/luaui localwidgetsconfig`) and enable
   both **Use local widgets** and **Use local widgets first**. Several files here replace stock
   files with the same name, and "first" is what makes the local copies win.
3. Restart LuaUI (`/luaui reload`) or the game.
4. If you had the stock **Health Bars** widget (`unit_healthbars.lua`) enabled, turn it off in the
   widget list (F11). The overlay replaces it. The local copy only changes its default, and a
   saved "enabled" setting still wins.

Games with the `disable_local_widgets` mod option block all local widgets while you're playing.
Spectating and replays still load them.

## Differences from the combined branch

That branch also changed gadgets, unit definitions and one engine shader. None of those can be
shipped as local widgets, so this build handles them like this:

| Branch change | Here |
|---|---|
| New unit/weapon `customParams` (`icon`, `overlay_icon_size`, `health_bar_height`, `energy_grid`, `teleporter_is_beacon`) | `LuaUI/Configs/widgets_only_defs.lua` holds the values. `Widgets/Include/widgets_only_defs.lua` writes them into `UnitDefs`/`WeaponDefs` `customParams` at load, filling in only keys a release hasn't defined. |
| New `iconType`s (Zenith, Disco Rave Party, missile silo, silo missiles) | The same include registers the icons with `Spring.AddUnitIcon`/`SetUnitDefIcon`. Widgets that draw radar icons look them up through `WG.WidgetsOnlyIconType(ud)`. |
| New command IDs in `LuaRules/Configs/customcmds.lua` (GBC presets, missiles) | `LuaUI/Configs/widgets_only_cmds.lua` registers them. The widgets handle these commands themselves; no gadget uses them. |
| `cus_gl4` gadget + shader moved unit height from uniform float 11 to 15 | The stock gadget still uses float 11, so the overlay's 5th ability slot moves from float 11 to the free float 3. The overlay now writes only floats 1-10 (`gl_uniform_channels.lua`, `unit_gl_uniform_updater.lua`, `gui_unit_overlay_gl4.lua`). |
| `unit_morph` gadget sends the morph `increment` | The updater reads `increment` from the morph def that `MorphStart` already passes. For a morph that was already running when LuaUI loaded, it estimates the rate from progress updates. |
| New `unit_healthbars_widget_forwarding` gadget | Not needed: the overlay's handlers for its events are empty stubs. |
| `zk_keys.lua` drops the old share-menu Tab binding | Not shipped, because `LuaUI/Configs/zk_keys.lua` in your data directory is your own keybind file. The share menu and COFC overview hotkeys moved off plain Tab in their widgets, which are included. |
| `epicmenu_conf.lua` menu icon for "Missile Launcher" | Not shipped (cosmetic). The menu entry just shows without an icon. |

## Keeping up with releases

Many files here are modified copies of stock widgets and configs. They include
`gui_chili_integral_menu`, `gui_chili_core_selector`, `gui_chili_selections_and_cursortip`,
`unit_icons`, `unit_state_icons`, `cmd_mex_placement`, `icontypes.lua`, `customCmdTypes.lua` and
`integral_menu_config.lua`. With "local widgets first" on, they hide whatever a new release changes
in those files. If something breaks after an update, merge the release's changes into these copies.

If the source branch's unit/weapon defs change, regenerate the def table from the repo root:

    python3 LocalWidgets/tools/gen_widgets_only_defs.py [source-ref] [base-ref]
