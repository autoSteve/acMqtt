# acMqtt
CBus Automation Controller integration: Home Assistant, MQTT, Philips Hue and more

Functions:
- Get Home Assistant talking to CBus, with MQTT discovery to eliminate any manual CBus config in HA
- Return to previously set lighting levels when a 'turn on' command is issued in HA
- Optionally include Philips Hue hub devices in CBus scenes, like having 'All Off' from a button or using AC visualisations
- Optionally Panasonic air conditioners via ESPHome
- Optionally ESPHome sensors for temperature and relative humidity (example .yaml files are for this.)
- Optionally Airtopia I/R blasters

The pieces of the puzzle include:
- Home Assistant 'HAOS' running somewhere. Home Assistant 'Core' as a container is not enough, as add-ins are required to get a MQTT broker going (but you could use a separately installed MQTT broker elsewhere on your network and use 'core'). HA Cloud talks to Google Assistant/Alexa, so a subscription is required if you want that.
- Home Assistant plug-ins: 'Mosquitto broker', and file editor is also handy.
- LUA code on a C-Bus Automation Controller (SHAC/NAC/AC2/NAC2).

LUA scripts for the automation controller:
- *MQTT send receive*: resident, zero sleep
- *MQTT*: event-based, execute during ramping, trigger on keyword 'MQTT'
- *AC*: event-based, execute during ramping, trigger on keyword 'AC'
- *AT*: event-based, execute during ramping, trigger on keyword 'AT'
- *HUE send receive*: resident, zero sleep
- *HUE*: event-based, execute during ramping, trigger on keyword 'HUE'
- *HUE final*: event-based, DO NOT execute during ramping, trigger on keyword 'HUE'
- *Heartbeat*: resident, zero sleep (optional ... monitors for failure of 'MQTT send receive' and 'HUE send receive' and re-starts them on failure)

If you don't care for integrating Philips Hue or Airtopia, then don't deploy those scripts. For AC/environmental devices the LUA AC/ENV code can stay there and will just be unused.

**Note**: A change to the discovery behaviour has been made to accommodate a non-breaking change in HA 2023.8, which will become breaking in 2024.2. CBus devices are now created using a blank entity name to end up with a sole entity for each device, in line with the HA naming standards.

~~Note that some of my scripts require automation controller firmware 1.10.0+. Also note that 1.10.0 and 1.11.0 contain a bug where event-based scripts that are set to not execute during ramping actually do, and this has significance for Hue ramping. See issue #10. So if you're on v1.6.0 then these scripts are un-tested.~~ **Note**: A work-around script is provided for HUE final to address a firmware bug. See issue #10.

## Keywords used for Automation Controller objects
Automation controller object keywords are used to tell the scripts which objects to use, publish, and how they should be used. This varies based on circumstance, as described below.

Newly added keywords can be regularly detected by both the 'MQTT send receive' and 'HUE send receive' scripts. This is configurable by setting an option that is near the top of both scripts. If this option is set to false then the scripts must be restarted (disable it, then enable) so that modified keywords are read. The default interval for change checks is thirty seconds, and that is also a configurable variable. Checking for changes adds a low workload to the automation controller, so is recommended.

### CBus (MQTT send receive)
Lighting, measurement, user parameter and trigger control applications are implemented.

Add the keyword 'MQTT' to groups for CBus discovery, plus...

One of light, fan, fan_pct, cover, select, sensor, switch, binary_sensor, bsensor or button, plus...  (default if not specified is 'light')
- sa=     Suggested area
- img=    Image (sensible automated defaults are provided, see below)
- pn=     Preferred name (defaults to CBus group name)
- class=  Device class to use in Home Assistant (User param/sensor only, see https://www.home-assistant.io/integrations/sensor/#device-class)
- dec=    Decimal places (User param/sensor only)
- unit=   Unit of measurement (User param/sensor only)
- scale=  Multiplier / divider (User param/sensor only)
- lvl=    List of applicable levels, separated by "-' (Trigger button and select only)
- on=     Preferred value shown in HA for a 'bsensor' ON value (bsensor only)
- off=    Preferred value shown in HA for a 'bsensor' OFF value (bsensor only)
- Plus the keyword includeunits for measurement application values only, which appends the unit of measurement (for the measurement app the unit is read from CBus, not the unit= keyword). Caution: This will make the sensor value a string, probably breaking any automations in HA that might expect a number, so using measurement app values without includeunits is probably what you want to be doing unless just displaying a value, which should probably use the right class anyway...

Using lvl= for trigger control buttons is highly recommended. This will attempt to publish only certain levels, greatly improving discovery performance. If not specified the script will publish all levels having a tag.

Using lvl= for select is mandatory. This defines the selection name and its corresponding CBus level for the group. There are three options for lvl=:
- Using the format: lvl=Option 1/0-Option 2/255, for any name desired and a level number
- The level numbers: lvl=0-255, which will use the level tag
- The level tags: lvl=Option 1-Option 2, which will look up the level number

And futher for select only, if it is desirable to allow CBus levels other than the specific select levels to be set then alter the selectExact variable in the 'MQTT send receive' script, otherwise that script will force the level to be set to the nearest select level.

For trigger control buttons the preferred name is used as an optional prefix to the trigger level tag to name the button. Button can be used for both lighting and trigger control, with lighting group buttons not getting a prefix. Lighting group buttons operate by pulsing the CBus group for one second, acting as a bell press.

CBus fan controller objects can use either 'fan' or 'fan_pct' keywords. The former will use a preset mode of low/medium/high, while the latter discovers as a raw percentage fan in Home Assistant.

The image keyword img= will default to several different "likely" values based on name or preferred name keywords. If the script gets it wrong, then add a img= keyword, or contact me by raising an issue for cases where it's stupidly wrong. Here's the current logic...

```
  -- Default images for a lighting group
  if img == '' and lighting[tostring(app)] then
    local pnl = pn:lower()
    if contains('heat', pnl) then img = 'mdi:radiator'
    elseif contains('blind', pnl) then img = 'mdi:blinds'
    elseif contains('under floor', pnl) then if contains('enable', pnl) then img = 'mdi:radiator-disabled' else img = 'mdi:radiator' end
    elseif contains('towel rail', pnl) then if contains('enable', pnl) then img = 'mdi:radiator-disabled' else img = 'mdi:radiator' end
    elseif contains('fan', pnl) then if contains('sweep', pnl) then img = 'mdi:ceiling-fan' else img = 'mdi:fan' end
    elseif contains('gate', pnl) then if contains('open', pnl) then img = 'mdi:gate-open' else img = 'mdi:gate' end
    else img = 'mdi:lightbulb'
    end
  end
```

Keyword examples:

- MQTT, light, sa=Outside, pn=Outside Laundry Door Light, img=mdi:lightbulb, 
- MQTT, switch, sa=Bathroom 1, img=mdi:radiator, 
- MQTT, fan, sa=Hutch, img=mdi:ceiling-fan, 
- MQTT, cover, sa=Bathroom 2, img=mdi:blinds, 
- MQTT, select, sa=Bathroom 2, img=mdi:blinds, lvl=0-137-255, 
- MQTT, select, sa=Bathroom 2, img=mdi:blinds, lvl=Closed-Half open-Open, 
- MQTT, select, sa=Bathroom 2, img=mdi:blinds, lvl=Closed/0-Half open/137-Open/255, 
- MQTT, sensor, sa=Pool, pn=Pool Pool Temperature, unit= °C, dec=1, 
- MQTT, sensor, sa=Pool, pn=Pool Level, unit= mm, dec=0, scale=1000, 
- MQTT, button, sa=Entry / Egress, lvl=0-1-2-5-127, pn=Inside      *(a trigger control group with various levels)*
- MQTT, bsensor, sa=Carport, on=Motion detected, off=No motion
- MQTT, button, sa=Outside, img=mdi:gate-open,    *(a lighting group button to open a gate)*

### Philips Hue (HUE send receive)
For Philips Hue devices, bi-directional sync with CBus occurs. I run Home Assistant talking directly to the Hue hub, and also the Automation Controller script via REST API. Add the keyword 'HUE' to CBus objects, plus...
- pn= Preferred name (needs to match exactly the name of the Hue device.)

Keyword examples:

- HUE, pn=Steve's bedside light
- HUE, pn=Steve's electric blanket

A useful result is that Philips Hue devices can then be added to CBus scenes, like an 'All off' function.

The CBus groups for Hue devices are usually not used for any purpose other than controlling their Hue device. Turning on/off one of these groups will result in the Philips Hue hub turning the loads on/off. It is possible that these CBus Hue groups could also be used to control CBus loads, giving them dual purpose.

Note: This script only handles on/off as well as levels for dimmable Hue devices, but not colours/colour temperature, as that's not a CBus thing. Colour details will return to previously set values done in the Hue app.

### Panasonic Air Conditioners (MQTT send receive)
For Panasonic air conditioners connected to MQTT via ESPHome (see example .yaml file), add the keyword 'AC' to user parameters plus...

- dev=   ESPHome device name, required, and one of:
- func=  Function (mode, target_temperature, fan_mode, swing_mode, which results in {dev}/climate/panasonic/{func}/#)

... or
- sel=   Select (vertical_swing_mode, horizontal_swing_mode, which results in {dev}/select/{sel}/#)

... or
- sense= A read only sensor like current_temperature, plus topic= (e.g. climate or sensor) with sensor as default

Mode strings = ("off", "heat", "cool", "heat_cool", "dry", "fan_only")
Horizontal swing mode strings = ("auto", "left", "left_center", "center", "right_center", "right")
Vertical swing mode strings = ("auto", "up", "up_center", "center", "down_center", "down")

Note: target_temperature and sensors are an integer user parameter, while all others are strings.
Note: Set all device names to 'Panasonic' in the 'climate' section of the ESPHome configuration .yaml, and make 'esphome' name unique to identify the devices (this corresponds to the 'dev' keyword' applied in the automation controller).

Panasonic keyword examples:

- AC, dev=storeac, func=mode, 
- AC, dev=storeac, func=target_temperature
- AC, dev=storeac, func=fan_mode, 
- AC, dev=storeac, func=swing_mode, 
- AC, dev=storeac, sel=vertical_swing_mode
- AC, dev=storeac, sel=horizontal_swing_mode, 
- AC, dev=storeac, sense=current_temperature, topic=climate
- AC, dev=storeac, sense=outside_temperature

See https://github.com/DomiStyle/esphome-panasonic-ac for ESP32 hardware/wiring hints.

### Airtopia Air Conditioner Controllers (IR blaster)

For Airtopia devices, add the keyword 'AT' to user parameters, plus...

-  dev=   Airtopia device name (you choose, lowercase word, no spaces), required
-  sa=    Suggested area (to at least one of the device user parameters)

And one or more of:
-  func=  Function (power, mode, vert_swing, horiz_swing, target_temperature, fan)

... or
-  sense= A read only sensor like current_temperature, power_consumption

### Environment Monitors (MQTT send receive)
Environment monitors can pass sensor data to CBus (using ESPHome devices, see example .yaml).

Add the 'ENV' keyword, plus...
- dev=  Device (the name of the ESPHome board)
- func= Function (the sensor name configured in ESPHome) defaults to the User Parameter name in lowercase, spaces replaced with underscore

Environment examples:

- ENV, dev=outsideenv

## Getting it running

### Prepare Home Assistant
I don't cover installing Home Assistant here. You probably wouldn't be reading this if you weren't already an avid user, but if you are new then you want 'HAOS' installed somewhere (RPi, NUC, VM, old laptop, etc.), and the Googled how-to guide you want will depend on that 'somewhere'.

Install the official Mosquitto broker. First up, create a HomeAssistant user 'mqtt', and give it a password of 'password' (used in the 'MQTT send receive' script), and probably hide it so it doesn't appear on dashboards (it doesn't need to be admin). Then go to Settings, Add-ons, and from 'official' add-ons install and start Mosquitto. Any HA user can be used to authenticate to this Mosquitto instance, explaining the creation of the user 'mqtt'.

If you don't want HAOS, then simply get an MQTT broker running elsewhere on your network.

The 'HUE send receive' script communicates directly with the bridge via its REST API, and requires nothing more than keywords.

If you want to, go grab MQTT Explorer by Thomas Nordquist at http://mqtt-explorer.com/, which is an excellent tool to gain visibility of what is going on behind the scenes. On second thought, definitely go grab it. After connection the cbus read/homeassistant topics should show all objects having the right keywords.

### Home Assistant configuration.yaml example:
Sets up the MQTT connection, plus includes many domains for Google Home (adjust as needed for Alexa, etc.)
~~~
mqtt:
  client_id: haos
  keepalive: 20

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
~~~