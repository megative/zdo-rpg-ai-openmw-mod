# Zdo RPG AI — OpenMW mod

The in-game part of [Zdo RPG AI](https://github.com/megative/zdo-rpg-ai): talk to the people of Morrowind with your own voice. This mod lives inside OpenMW; the client and the server from the [zdo-rpg-ai](https://github.com/megative/zdo-rpg-ai) repository do the listening and the thinking.

Guides for installing, configuring and playing, in English and Russian: [megative.github.io/zdo-rpg-ai](https://megative.github.io/zdo-rpg-ai/) ([по-русски](https://megative.github.io/zdo-rpg-ai/ru/)).

![Screenshot](./doc/screenshot.jpg)

## What the mod does

- Watches the push-to-talk key, shows subtitles and plays the NPCs' voices. The Enter key opens a line to type what to say instead.
- Tells the server about the scene: who is around, what they carry, the time and place, and the quest steps NPCs give in the game's dialogue. Each NPC hears of the player's journal only the quests it takes part in, and of secret factions only its own.
- Carries out what NPCs decide: hands over items and gold, follows, fights, changes disposition, opens trade, training, travel, spell and repair windows, and the game's own dialogue.
- Shows each of those as a notification, and keeps a log you open with a key: your open tasks and the latest events, then, on a second press, who said what. Both are stored in the save.
- Talks to the client through files: the client writes into this folder, and the mod answers through `openmw.log`.

## Installation

Requires OpenMW 0.50 or newer. Add the `zdorpgai` folder to OpenMW and enable its scripts, either in the launcher (**Data Files → Directories**, then tick `zdorpgai.omwscripts` on **Content Files**) or in `openmw.cfg`:

```ini
data="/path/to/zdo-rpg-ai-openmw-mod/zdorpgai"
content=zdorpgai.omwscripts
```

Then run the client and the server from [zdo-rpg-ai](https://github.com/megative/zdo-rpg-ai); the client connects to the mod by itself. Step-by-step guides for [Windows](https://megative.github.io/zdo-rpg-ai/install/windows/), [Linux](https://megative.github.io/zdo-rpg-ai/install/linux/) and [macOS](https://megative.github.io/zdo-rpg-ai/install/macos/) are on the website.

## Tests

The scripts run against stand-ins for OpenMW's API, with Lua 5.4 or newer, from this folder:

```sh
lua tests/mod_test.lua
lua tests/scene_secrets_test.lua
```

## Credits

- [drzdo](https://github.com/drzdo): original author of Zdo RPG AI and its OpenMW mod.
- [waterbobo24](https://github.com/waterbobo24): richer NPC and player context, in-game time, item transfers and per-save memory are ported from their forks [Morrowind-llm-server-client](https://github.com/waterbobo24/Morrowind-llm-server-client) and [Morrowind-llm-mod](https://github.com/waterbobo24/Morrowind-llm-mod).
- [megative](https://github.com/megative) maintains this fork.

## License

[GPL-3.0](LICENSE)
