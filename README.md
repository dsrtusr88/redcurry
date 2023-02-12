![redcurry](https://i.imgur.com/XIt1iZd.jpg)

# RedCurry

*curry from one gazelle to another.*

- [RedCurry](#redcurry)
  - [Requirements](#requirements)
  - [Install](#install)
  - [Usage](#usage)

**OBLIGATORY DISCLAIMER:** Compliance with upload/tracker rules is your responsibility. As with any spice, apply with care.

## Requirements

Linux or Mac OS, with a reasonably recent version of **Ruby**, and **mktorrent** >= 1.1.

## Install

- Clone the repo from [Gitlab](https://gitlab.com/_mclovin/redcurry)
- From within the folder, install dependencies by typing: `bundle`
- Edit the configuration file, `curry.yaml`, using the included example as a guide.
- Ensure `curry.yaml` resides in the same folder as the script.
- If you are not using an API key, populate the session cookies in the configured locations; take care to follow the following example format for the cookie: **session=89127489129hridfqwfd98r214%D;**, that is, including the `session=` to start and semi-colon at the end.
- Ensure the script is executable, e.g. `chmod +x /path/to/redcurry.rb`

## Usage

Example \#1: `./redcurry.rb "SOURCE_TORRENT_PL" SOURCE TARGET`

Example #2: `./redcurry.rb /path/to/folder/with/.torrent/files SOURCE TARGET`

**Note \#1: The quotes surrounding the permalink in \#1 above are required.**

**Note #2: SOURCE and TARGET above correspond to keys in the configuration YAML file. These can be whatever you want, e.g. gazelle-based trackers, but take care to match what you type on the command line with what is specified in your config file.**

**Example #2 activates a kind of 'batch mode', iterating through all .torrent files in the specified folder, and — for those that correspond to the configured source tracker — couriering from source to target.**
