# acMqtt
CBus Automation Controller integration: Home Assistant, MQTT, Philips Hue and more

Functions:
* Get Home Assistant talking to CBus, with MQTT discovery to eliminate any manual CBus config in HA
* Optionally return to previously set lighting levels when a 'turn on' command is issued (supports very old versions of HA)
* Optionally include Philips Hue hub devices in CBus scenes, like having 'All Off' from a button or using AC visualisations
* Optionally Panasonic air conditioners via ESPHome
* Optionally ESPHome sensors for temperature and relative humidity (example .yaml files are for this.)
* Optionally Airtopia I/R blasters

> [!NOTE]
> If you're using a 'generic' zigbee coordinator instead of Philips Hue then check out https://github.com/geoffwatts/cbus2zigbee. I'm contributing to his brilliant effort to make that the 'go to' for zigbee/C-Bus AC integration. Hue hub is dead to me.

The pieces of the puzzle include:
* Home Assistant 'HAOS' running somewhere. Home Assistant 'Core' as a container is not enough, as add-ins are required to get a MQTT broker going (but you could use a separately installed MQTT broker elsewhere on your network and use 'core'). HA Cloud talks to Google Assistant/Alexa, so a subscription is required if you want that.
* Home Assistant plug-ins: 'Mosquitto broker', and file editor is also handy.
* Lua code on a C-Bus Automation Controller (SHAC/NAC/AC2/NAC2).
* Keywords added to Automation Controller objects.

The Lua scripts for the automation controller (all scripts do NOT have to be called these names):
* *MQTT send receive*: resident, zero sleep suggested, but higher will just mean slower restart speed on failure
* *HUE send receive*: (for Philips Hue) resident, zero sleep suggested, but higher will just mean slower restart speed on failure
* *Heartbeat*: (optional) resident, zero sleep ... monitors for failure of *MQTT send receive* and *HUE send receive* and re-starts them when unresponsive (stuck in loop, lock-up, etc.)

> [!NOTE]
> Carefully examine the environment specific variable comments at the top of *MQTT send receive* and set as appropriate to your needs.
>
> To enable support for ESPHome environment sensors, Panasonic A/C, or Airtopia A/C alter the variables *environmentSupport*, *panasonicSupport* or *airtopiaSupport* as appropriate.
>
> If implemented, legacy event scripts *MQTT final* or *MQTT* (which aren't used any more) will be disabled on start of *MQTT send receive*.

## About errors

If you get errors in the log (error or event log), then feel free to raise an issue and I'll try to help.

Warnings are also thrown for obvious code defects that are encountered. If you get something like 'Warning: Read undeclared global variable "someVariableName"' then *definitely* raise an issue.

## Keywords used for Automation Controller objects
Automation controller object keywords are used to tell the scripts which objects to use, publish, and how they should be used. This varies based on circumstance, as described below.

Newly added keywords can be regularly detected by both the *MQTT send receive* and 'HUE send receive' scripts. This is configurable by setting the option `checkForChanges` that is near the top of both scripts. If this option is set to false then the scripts must be restarted (disable it, then enable) so that modified keywords are read. The default interval for change checks is thirty seconds, and that is also a configurable variable.

Checking for changes adds a low workload to the automation controller, so is recommended. I run ten seconds these days without any significant load impact, mostly because my NAC is a crash test dummy for you. Five seconds or less would be a bit too aggresive in my opinion, but again it seems to not add significant load. Maybe do a shorter check interval while setting things up, and then back it off or disable it entirely when your config is stable, adding zero extra load.

### CBus (*MQTT send receive*)
Lighting, measurement, user parameter, unit parameter and trigger control applications are implemented. (Unit parameter as a sensor only.)

> [!NOTE]
> All keywords are case sensitive.

#### TL>DR examples

* `MQTT, light, sa=Outside, pn=Outside Laundry Door Light,`
* `MQTT, switch, sa=Bathroom 1, img=mdi:radiator,`
* `MQTT, fan_pct, preset, sa=Hutch, img=mdi:ceiling-fan,`      *(a L5501RFCP sweep fan controller group)*
* `MQTT, fan, sa=Hutch, img=mdi:ceiling-fan,`
* `MQTT, cover, sa=Bathroom 2, img=mdi:blinds, rate=15.9/16.0,`
* `MQTT, cover, sa=Bathroom 2, img=mdi:blinds, noleveltranslate,`
* `MQTT, select, sa=Bathroom 2, lvl=0/137/255,`
* `MQTT, select, sa=Bathroom 2, lvl=Closed/Half open/Open,`
* `MQTT, select, sa=Bathroom 2, lvl=Closed:0/Half open:137/Open:255,`
* `MQTT, sensor, sa=Pool, pn=Pool Pool Temperature, unit= °C, dec=1,`
* `MQTT, sensor, sa=Pool, pn=Pool Level, unit= mm, dec=0, scale=1000,`
* `MQTT, button, sa=Entry / Egress, lvl=0/1/2/5/127, pn=Inside,`      *(a trigger control group with various levels)*
* `MQTT, button, sa=Outside, img=mdi:gate-open,`      *(a lighting group button to open a gate)*
* `MQTT, bsensor, sa=Carport, on=Motion detected, off=No motion,`
* `MQTT, sensor, sa=Family room, pn=Alarm state, lvl=Disarmed:0/Armed:1,`       *(a lighting group sensor to display alarm state)*

For the bsensor example of a carport motion sensor, set up a CBus group address on the PIR unit to trigger on movement with a short timer like 5s in a block entry and then add the MQTT keywords to that group.

For some PIR sensors, like the 5753PEIRL the light level may be broadcast periodically to a group address. Getting this into HomeAssistant as a percentage is then trivial with keywords like these:

* `MQTT, sensor, sa=Carport, pn=Carport Light Level, unit=%, dec=0, scale=0.390625,`

#### The details

Add the keyword 'MQTT' to groups for CBus discovery, plus...

A type of `light`, `fan`, `fan_pct` (or `fanpct`), `cover`, `select`, `sensor`, `switch`, `binary_sensor` (or `binarysensor`), `bsensor`, `isensor` or `button` (default if not specified is `light`).
* `light`, `cover`, `select`, `sensor`, `switch`, `binary_sensor` and `button` are self-explanatory, being the Home Assistant equivalents.
* Using `cover` by default assumes that a L5501RBCP blind relay is in "level translation mode". Using a select would also work well, with predictable level presets for open, closed, and part open at half way. See the cover notes below for more.
* The `fan` keyword is specifically for sweep fan controllers like a L5501RFCP. See the sweep fan notes below. (For simple exhaust fans use `switch`.)
* A `bsensor` is a special-case binary_sensor, where the values are not ON/OFF, but rather configurable, e.g. Motion detected/Motion not detected.
* An `isensor` is an inbound sensor, with values subscribed in MQTT topics. Use an automation in Home Assistant to publish sensor vaules to MQTT.

And in addition to the type...
* `sa=`     Suggested area
* `img=`    Image (sensible automated defaults are provided, see below)
* `pn=`     Preferred name (defaults to CBus group name, however unit parameters have no name, so treat this as mandatory in that special case)
* `class=`  Device class to use in Home Assistant (User param/sensor only, see https://www.home-assistant.io/integrations/sensor/#device-class)
* `state_class=` State class to use in Home Assistant (User param/sensor only)
* `disco=`  Custom discovery parameter to add (see below)
* `dec=`    Decimal places (User param/sensor only)
* `unit=`   Unit of measurement (User param/sensor only)
* `scale=`  Multiplier / divider (User param/sensor only)
* `lvl=`    List of applicable levels, separated by "/" (Trigger button, select and lighting sensors only)
* `on=`     Preferred value shown in HA for a 'bsensor' ON value (bsensor only)
* `off=`    Preferred value shown in HA for a 'bsensor' OFF value (bsensor only)
* `rate=`   Rate of cover open/close for tracking, see below (cover only)
* `delay=`  Delay cover tracking, see below (cover only)
* `topic=`  A MQTT topic to subscribe to (isensor only)
* Plus the keyword `includeunits` for measurement application values only, which appends the unit of measurement (for the measurement app the unit is read from CBus, *not* the `unit=` keyword). Caution: This will make the sensor value a string, probably breaking any automations in HA that might expect a number, so using measurement app values without includeunits is probably what you want to be doing unless just displaying a value, which should probably use the right class anyway...
* Plus the keyword `preset` in conjunction with `fan_pct` if both a percentage slider and a preset option are desired.
* Plus the keyword `noleveltranslate` in conjunction with `cover`, see below

#### On `lvl=`

Using `lvl=` for trigger control buttons is highly recommended. This will attempt to publish only certain levels, greatly improving discovery performance. If not specified the script will publish all levels having a tag.

Using `lvl=` for select is mandatory. This defines the selection name and its corresponding CBus level for the group.

There are three options for `lvl=`:
* Using the format: `lvl=Option 1:0/Option 2:255`, for any name desired and a level number
* The level numbers: `lvl=0/255`, which will use the level tag
* The level tags: `lvl=Option 1/Option 2`, which will look up the level number

And futher for `select` only, if it is desirable to allow CBus levels other than the specific select levels to be set then alter the `selectExact` variable in the *MQTT send receive* script, otherwise that script will force the level to be set to the nearest select level.

A special case exists to use `lvl=` with a lighting group sensor. This is where it is preferred to present the CBus level display text instead of the group level (or any display text by using the format `lvl=State zero:0/State one:1`, which will not look up the level tag).

#### On `disco=`

The keyword `disco=` is used to add arbitrary discovery variables to the MQTT discovery topic. Example:

* `disco=state_class:measurement/new_ha_parameter:value_x`

This keyword allows for any current and future variable to be set where an existing tested keyword may not exist.

Note that `disco=` discovery topic variables will override any discovery variable set by another means (example, set `state_class=total, disco=state_class:measurement,` and the resulting `state_class` will be `measurement`).

#### Cover notes

There are three modes of operation for cover devices.

1. Simple slider, with no level translation mode set in the CBus shutter relay unit configuration
2. Level translation mode on, where a slider, plus open/close/stop can be utilised, but having limited Home Assistant state reporting
3. Level translation mode on with tracking, allowing near real-time level tracking in Home Assistant

Option one may be configured by specifying `MQTT, cover, noleveltranslate,`. This is the simplest mode of operation, usually employed for use with just a slider, where level translation mode may not be desired.

Option two is configured by simply specifying `MQTT, cover,`. In this mode *MQTT send receive* uses open (level 255), close (level 0) and stop (level 5). Level translation mode must be set in the shutter relay global options. For status, when 'open' is selected any slider visible will move to 100% open, and should 'stop' be pressed during travel then the slider will move to 50%, and the reverse of this status for 'close'. This is because there is no position status feedback from a CBus shutter relay, which is where option three comes in.

Option three is configured by specifying `MQTT, cover, rate=x(/x), (delay=x.x),`. In this mode, *MQTT send receive* will utilise a timed approximation of cover travel to update status in Home Assistant. It *must* be calibrated.

The calibration process is quite simple, and the more accurate the calibration the better the result (within the limits of the shutter - this isn't perfect, but is usually really good). Steps:

1. Time how long it takes the cover to close.
2. Time how long it takes to open. You do not need to be super accurate yet.
3. Add these numbers in seconds to a `rate=up/down keyword`. An example for one of my Somfy blinds is `rate=16/16`. You can also just specify one rate value (e.g. `rate=16`) and the same will be used for open and close. (After calibration the final values ended at `rate=15.91/15.85`)
4. Test and tweak. Start fully open, then close using HA to  almost the bottom but not quite. The blind will then jerk either upwards or downwards a little bit, telling you the timing was not quite right. Adjust the rate, and rinse/repeat, doing the same for opening on the other way up. On closing, if it jerks up on stop, it means the rate value is too low, and if it jerks down the opposite, so adjust slightly. On opening, if it jerks up after stop then the rate is too high, and if it jerks down too low. If it's not just jerking but moving significantly, then go back to the start because the rough timing is not right.
5. If after calibration the slight tweak on stop is not desired then set a variable near the top of the script to false (setCoverLevelAtStop). The approximation of level from timing will always be a little bit off, but going fully open or closed, or to a specific level with a slider will always be 100% accurate.

The current position of the blind is not initially set in storage for tracking mode, but will be once the `rate=` keyword is added and a full open or close is done, or a slider is set to any open level.

A keyword `delay=` is also available. If there is a small delay before a cover begins its travel then this can delay tracking for a period. 1/10th of a second resolution.

Status update smoothness in Home Assistant is dependent on *MQTT send receive* not being interrupted significantly during a tracked transition. Check for keyword changes is usually the reason, especially for large deployments where checking can take 100-300ms, and this makes the status jump a little. If it bothers you then set `checkForChanges` to false at the top of the script, and simply restart *MQTT send receive* should any keywords change. Personally I like the convenience of change checks, and I have it set at quite a frequent interval for development, and not thirty seconds.

> [!NOTE]
> Movement of the cover is assumed to be linear, however if this is not the case for your particular cover then feel free to open an issue and we can discuss whether there's a way to track it better.

#### Button notes

For trigger control buttons the preferred name is used as an optional prefix to the trigger level tag to name the button. Button can be used for both lighting and trigger control, with lighting group buttons not getting a prefix. Lighting group buttons operate by pulsing the CBus group for one second, acting as a bell press.

#### Sweep fan notes

CBus fan controller objects can use either `fan` or `fan_pct` keywords. The former will use a preset mode of low/medium/high, while the latter discovers as a slider fan in Home Assistant.

If needed, the best of both can also be had by specifying the keyword `preset` in conjunction with `fan_pct`.

#### Isensor notes

An automation is used to publish Home Assistant values to MQTT so that an `isensor` can get updates from the `topic=` published value. An example in automations.yaml:

```
- id: '1714042033410'
  alias: State of charge to MQTT
  description: ''
  trigger:
  - platform: state
    entity_id:
    - sensor.powerwall_charge_actual
  condition: []
  action:
  - service: mqtt.publish
    metadata: {}
    data:
      qos: '2'
      retain: true
      topic: powerwall/soc
      payload_template: '{{ trigger.to_state.state }}'
  mode: single
```

And the keywords: `MQTT, isensor, topic=powerwall/soc,`

#### Image defaults

The image keyword `img=` will default to several different "likely" values based on name or preferred name keywords. If the script gets it wrong, then add an `img=` keyword, or contact me by raising an issue for cases where it's stupidly wrong or where other defaults would be handy. Default is `mdi:lightbulb` for lighting groups, and `mdi:eye` for measurement application/user/unit parameter. Here's the current set...

```
local imgDefault = { -- Defaults for images - Simple image name, or a table of 'also contains' keywords (which must include an #else entry)
  heat            = 'mdi:radiator',
  blind           = 'mdi:blinds',
  ['under floor'] = {enable = 'mdi:radiator-disabled', ['#else'] = 'mdi:radiator'},
  ['towel rail']  = {enable = 'mdi:radiator-disabled', ['#else'] = 'mdi:radiator'},
  fan             = {sweep = 'mdi:ceiling-fan', ['#else'] = 'mdi:fan'},
  exhaust         = 'mdi:fan',
  gate            = {open = 'mdi:gate-open', ['#else'] = 'mdi:gate'},
  pir             = 'mdi:motion-sensor',
  temperature     = 'mdi:thermometer',
}
```

#### Variables at the top of the script
Aside from the obvious local broker, change checking, and Airtopia, Panasonic and ESPhome support variables at the stop of the script, there are three script behaviour modifying variables. These can be important to select individual preferences.

The first is `entityIdAsIdentifier`. This is important to choose how the entity ID is presented to Home Assistant. If it is set to `true`, then entity IDs will be created using the object identifier (e.g. `light.bathroom_1_fan`), and if false by using C-Bus numbering (e.g. `light.cbus_mqtt_254_56_10`). Choosing `true` may make writing automations, and selecting dashboard items much easier and readable. I recommend it. Entity IDs must be unique, so if `entityIdAsIdentifier=true` then make sure all `sa=`/`pn=` selections are unique. The script currently does not check this, so if there are duplicates they will be revealed in the Home Assistant error log.

The second is `forceChangeId`. If `entityIdAsIdentifier` is changed, then entity IDs, by default will not change when a discovery entity ID change occurs. This is by design in Home Assistant. If this variable is set to `true`, then the entities will be recreated on script start where there is an entity ID change, so **will** use the new ID. **Excercise great caution**, as this will almost certainly break dashboards and existing automations that reference the old entity IDs. The change may well be worth it, though, and I also recommend it. Things should have been like this since the birth of acMqtt. If you do change `entityIdAsIdentifier` with `forceChangeId` set and change your mind, then setting `entityIdAsIdentifier` back again and restarting will restore dashboard/automation goodness.

The third is `removeSaFromStartOfPn`. By default this is `true`, and I prefer this, but some do not. The script will remove the 'suggested area' from the start of any 'preferred name' entries if present (or from the default C-Bus object name). For example, with a `sa=Bedroom 1`, the `pn=Bedroom 1 Light` would become simply 'Light' in Home Assistant. When this variable is set to `false`, the exact perferred name would be used instead, being 'Bedroom 1 Light'. Including the keyword `exactpn` with `removeSaFromStartOfPn=true` will create an exception for an individual object, allowing the best of both worlds.

### Philips Hue (HUE send receive)
For Philips Hue devices, bi-directional sync with CBus occurs. I run Home Assistant talking directly to the Hue hub, and also the Automation Controller script via REST API. Add the keyword `HUE` to CBus objects, plus...
- `pn=` Preferred name (needs to match exactly the name of the Hue device.)

Keyword examples:

* `HUE, pn=Steve's bedside light,`
* `HUE, pn=Steve's electric blanket,`

A useful result is that Philips Hue devices can then be added to CBus scenes, like an 'All off' function.

The CBus groups for Hue devices are usually not used for any purpose other than controlling their Hue device. Turning on/off one of these groups will result in the Philips Hue hub turning the loads on/off. It is possible that these CBus Hue groups could also be used to control CBus loads, giving them dual purpose.

> [!NOTE]
> This script only handles on/off as well as levels for dimmable Hue devices, but not colours/colour temperature, as that's not a CBus thing. Colour details will return to previously set values done in the Hue app.

### Panasonic Air Conditioners (*MQTT send receive*)
For Panasonic air conditioners connected to MQTT via ESPHome (see example .yaml file), add the keyword `AC` to user parameters plus...

* `dev=`   ESPHome device name, required, and one of:
* `func=`  Function (`mode`, `target_temperature`, `fan_mode`, `swing_mode`, which results in `{dev}/climate/panasonic/{func}/#`)

... or
* `sel=`   Select (`vertical_swing_mode`, `horizontal_swing_mode`, which results in `{dev}/select/{sel}/#`)

... or
* `sense=` A read only sensor like `current_temperature`, plus `topic=` (e.g. `climate` or `sensor`) with `sensor` as default

Mode strings = (`off`, `heat`, `cool`, `heat_cool`, `dry`, `fan_only`)
Horizontal swing mode strings = (`auto`, `left`, `left_center`, `center`, `right_center`, `right`)
Vertical swing mode strings = (`auto`, `up`, `up_center`, `center`, `down_center`, `down`)

Panasonic keyword examples:

* `AC, dev=storeac, func=mode,`
* `AC, dev=storeac, func=target_temperature,`
* `AC, dev=storeac, func=fan_mode,`
* `AC, dev=storeac, func=swing_mode,`
* `AC, dev=storeac, sel=vertical_swing_mode,`
* `AC, dev=storeac, sel=horizontal_swing_mode,`
* `AC, dev=storeac, sense=current_temperature, topic=climate,`
* `AC, dev=storeac, sense=outside_temperature,`

> [!NOTE]
> The objects `target_temperature`, and the sensors `current_temperature` and `outside_temperature` are integer user parameters, while all others are string user parameters.
>
> Set all device names to 'Panasonic' in the `climate` section of the ESPHome configuration .yaml, and make `esphome` name unique to identify the devices (this corresponds to the `dev=` keyword' applied in the automation controller).

See https://github.com/DomiStyle/esphome-panasonic-ac for ESP32 hardware/wiring hints.

### Airtopia Air Conditioner Controllers (*MQTT send receive*, an ancient IR blaster)

For Airtopia devices, add the keyword `AT` to user parameters, plus...

*  `dev=`  Airtopia device name (you choose, lowercase word, no spaces), required
*  `sa=`   Suggested area (to at least one of the device user parameters)

And one or more of:
*  `func=`  Function (`power`, `mode`, `vert_swing`, `horiz_swing`, `target_temperature`, `fan`)

... or
*  `sense=` A read only sensor like `current_temperature`, `power_consumption`

### Environment Monitors (*MQTT send receive*)
Environment monitors can pass sensor data to CBus (using ESPHome devices, see example .yaml).

Add the `ENV` keyword, plus...
* `dev=`  Device (the name of the ESPHome board)
* `func=` Function (the sensor name configured in ESPHome) defaults to the User Parameter name in lowercase, spaces replaced with underscore

Environment examples:

* `ENV, dev=outsideenv,`

## Getting it running

### Prepare Home Assistant
I don't cover installing Home Assistant here. You probably wouldn't be reading this if you weren't already an avid user, but if you are new then you want 'HAOS' installed somewhere (RPi, NUC, VM, old laptop, etc.), and the Googled how-to guide you want will depend on that 'somewhere'.

Install the official Mosquitto broker. First up, create a HomeAssistant user 'mqtt', and give it a password of 'password' (used in the *MQTT send receive* script), and probably hide it so it doesn't appear on dashboards (it doesn't need to be admin). Then go to Settings, Add-ons, and from 'official' add-ons install and start Mosquitto. Any HA user can be used to authenticate to this Mosquitto instance, explaining the creation of the user 'mqtt'.

If you don't want HAOS, then simply get an MQTT broker running elsewhere on your network.

The 'HUE send receive' script communicates directly with the bridge via its REST API, and requires nothing more than keywords.

If you want to, go grab MQTT Explorer by Thomas Nordquist at http://mqtt-explorer.com/, which is an excellent tool to gain visibility of what is going on behind the scenes. On second thought, definitely go grab it. After connection the cbus read/homeassistant topics should show all objects having the right keywords.

### Home Assistant configuration.yaml example:
Sets up the MQTT connection, plus includes many domains for Google Home (adjust as needed for Alexa, etc.). Note that this is for *my* server, on network 192.168.10.0, and I use a reverse proxy. Yours will be different.
```
# Loads default set of integrations. Do not remove.
default_config:

# Text to speech
tts:
  - platform: google_translate

http:
#  server_host: 0.0.0.0
  use_x_forwarded_for: true
  trusted_proxies:
  - 192.168.10.0/24

mqtt:

cloud:
  google_actions:
    filter:
      include_domains:
        - switch
        - binary_sensor
        - camera
        - climate
        - cover
        - fan
        - group
        - input_boolean
        - input_select
        - light
        - lock
        - scene
        - script
        - sensor
        - switch
        - vacuum

automation: !include automations.yaml
script: !include scripts.yaml
scene: !include scenes.yaml
```
