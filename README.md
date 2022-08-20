# acMqtt
CBus Automation Controller: Home Assistant, MQTT, Philips Hue and more

Functions:
- Get Home Assistant talking to CBus, with MQTT discovery to eliminate any manual CBus config in HA
- Return to previously set lighting levels when a 'turn on' command is issued in HA
- Optionally include Philips Hue hub devices in CBus scenes, like having 'All Off' from a button or using AC visualisations
- Optionally Panasonic air conditioners and ESPHome sensors for temperature and relative humidity integrated with the CBus Automation Controller (example .yaml files are for this.)

The pieces of the puzzle include:
- Home Assistant 'HAOS', running as a virtual machine. Home Assistant 'Core' as a container is not enough, as add-ins are required to get a MQTT broker and more going (but you could use a separately installed broker elsewhere on your network). HA Cloud talks to Google Assistant/Alexa.
- Home Assistant plug-ins: The excellent 'Portainer', 'SSH & Web terminal' and 'Mosquitto broker'. File editor is also handy.
- A container created with Portainer to run hue2mqtt.js
- LUA code on a C-Bus Automation Controller (SHAC/NAC/AC2/NAC2). Script names are important for the LUA code, given keep-alive and other re-starts, so adjust as necessary by examining thoroughly if you need to change the names.

LUA scripts for the automation controller:
- *MQTT send/receive*: resident, zero sleep (note: code here is "MQTT send receive", without the slash...)
- *MQTT lastlevel*: event-based, do not execute during ramping. Trigger on keyword 'MQTT'
- *MQTT*: event-based, execute during ramping, trigger on keyword 'MQTT'
- *HUE lastlevel*: event-based, do not execute during ramping. Trigger on keyword 'HUE' (this is simply a duplicate of the MQTT lastlevel script triggered on a different keyword)
- *HUE*: event-based, execute during ramping, trigger on keyword 'HUE'
- *AC*: event-based, execute during ramping, trigger on keyword 'AC'
- *Heartbeat*: resident, zero sleep (optional ... monitors for failure of MQTT send/receive and re-starts it)

If you don't care for integrating Philips Hue/AC/environmental devices with CBus, then ignore Portainer and hue2mqtt.js, and the LUA Hue/AC/ENV code can stay there and will just be unused.

Plus SSH & Web terminal and File Editor is not required, just nice to have.

## Keywords used for Automation Controller objects
Newly added keywords can be regularly detected by the MQTT send/receive script. This is configurable by setting an option that is near the top of the script. If this option is set to false then that script must be restarted (disable it, then enable) so that modified keywords are read. The default interval for change checks is sixty seconds, and that is also a configurable variable.

### CBus
Lighting, measurement, user parameter and trigger control applications are implemented.

Add the keyword 'MQTT' to groups for CBus discovery, plus...

One of  light, fan, cover, sensor, switch, or button, plus...    ('button' is for trigger control only, default if not specified is 'light')
- sa=     Suggested area
- img=    Image
- pn=     Preferred name (defaults to CBus tag)
- dec=    Decimal places (User param only)
- unit=   Unit of measurement (User param only)
- scale=  Multiplier / divider (User param only)
- lvl=    List of applicable levels, separated by "-' (Trigger only, used to publish only certain levels, and improves discovery performance)

For buttons, the preferred name is used as an optional prefix to the trigger level tag to name the button.

Keyword examples:

- MQTT, light, sa=Outside, pn=Outside Laundry Door Light, img=mdi:lightbulb, 
- MQTT, switch, sa=Outside, img=mdi:gate-open, 
- MQTT, fan, sa=Hutch, img=mdi:ceiling-fan, 
- MQTT, cover, sa=Bathroom 2, img=mdi:blinds, 
- MQTT, sensor, sa=Pool, pn=Pool Pool Temperature, unit= °C, dec=1, 
- MQTT, sensor, sa=Pool, pn=Pool Level, unit= mm, dec=0, scale=1000, 
- MQTT, button, lvl=0-1-2-5-127, pn=Inside, 

### Philips Hue
For Philips Hue devices, bi-directional sync with CBus occurs. I run Home Assistant talking directly to the Hue hub, and also the Automation Controller via MQTT. Add the keyword 'HUE' to CBus objects, plus...
- pn= Preferred name (used as the MQTT topic, which needs to match exactly the name of the Hue device.)

Keyword examples:

- HUE, pn=Steve's bedside light
- HUE, pn=Steve's electric blanket

A useful result is that Philips Hue devices can then be added to CBus scenes, like an 'All off' function.

A 'hue2mqtt.js' instance is required, and for Home Assistant this could be run as a container using
Portainer, or run as a separate container / process on another VM. hue2mqtt is used to sync a Hue bridge
with the MQTT broker.

The CBus groups for Hue devices are usually not used for any purpose other than controlling their Hue device.
Turning on/off one of these groups will result in the Philips Hue hub turning the loads on/off. It is possible
that these CBus Hue groups could be used to also control CBus loads, giving them dual purpose.

Note: This script only handles on/off, as well as levels for dimmable Hue devices, but not colours/colour
temperature, as that's not a CBus thing. Colour details will return to previously set values done in the Hue app.

### Panasonic Ar Conditioners
For Panasonic air conditioners connected to MQTT via ESPHome (see example .yaml file), add the keyword 'AC' to user parameters, plus...

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
Note: Set all device names to 'Panasonic' in the 'climate' section, and make the 'esphome' name unique to
identify the devices (this is the 'dev' keyword').

Panasonic keyword examples:

- AC, dev=storeac, func=target_temperature
- AC, dev=storeac, sel=vertical_swing_mode
- AC, dev=storeac, sense=current_temperature, topic=climate
- AC, dev=storeac, sense=outside_temperature

### Environment Monitors
Environment monitors can pass sensor data to CBus (using ESPHome devices, see example .yaml).

Add the 'ENV' keyword, plus...
- dev=  Device (the name of the ESPHome board)
- func= Function (the sensor name configured in ESPHome) defaults to the User Parameter name in lowercase, spaces replaced with underscore

Environment examples:

- ENV, dev=outsideenv

## Getting it running

### Prepare Home Assistant
I don't cover installing Home Assistant here. You probably wouldn't be reading this if you weren't already an avid user, but if you are new then you want 'HAOS' installed somewhere (RPi, NUC, VM, old laptop, etc.), and the Googled how-to guide you want will depend on that 'somewhere'.

Install the official Mosquitto broker. First up, create a HomeAssistant user 'mqtt', and give it a password of 'password' (used below), and probably hide it so it doesn't appear on dashboards (it doesn't need to be admin). Then go to Settings, Add-ons, and from 'official' add-ons install and start Mosquitto. Any HA user can be used to authenticate to this Mosquitto instance, explaining the creation of the user 'mqtt'.

Portainer might be new to you though, and this allows the creation and maintenance of containers other than those intended to be run alongside Home Assistant. In short, you can do pretty well whatever you want, and all from the comfort of a GUI (just don't ask the HA folks for help if you get stuck).

Go to Settings, Add-ons, Store, and using the little three-dot menu at top right, add the repository https://github.com/MikeJMcGuire/HASSAddons. Once you do, you'll be able to install Portainer 2 from Mike's repository. After it's installed, turn off the option 'Protection mode', enable the sidebar entry and start it. That will enable you to configure a new container for hue2mqtt.js.

The first login to Portainer requires setting an admin password, and from there click on 'Volumes' in the blue bar at left, and click 'Add volume'. I created a volume called 'hue2mqtt'. Store it wherever you like. I used local storage. The reason a volume is needed is so that Hue bridge configuration (a.k.a "press the Hue button") only needs to be done once, and will survive re-creation of the hue2mqtt.js container.

Then click 'Containers' in the blue bar, and 'Add container'.

For the image, I used: jkohl/hue2mqtt:latest & always pull.

Under 'Command and logging' tab, for the command, I used: '-b' '192.168.10.15' '-m' 'mqtt://mqtt:password@192.168.10.21' '-i' '1' '--insecure'. See https://github.com/hobbyquaker/hue2mqtt.js/blob/master/README.md for details.

Under 'Volumes' tab, I added a new volume mounted in the container at '/root/.hue2mqtt' pointed at the volume hue2mqtt to allow persistent storage.

For me, 192.168.10.21 is the IP address of my Home Assistant server, which is now running a Mosquitto broker. 192.168.10.15 is my Philips Hue bridge (I set its IP address to fixed on my Unifi router by editing the client device, so DHCP always gives it the same address).

Once the container is running, go press the button on your Hue bridge, then drop to a HAOS terminal and execute 'docker logs hue2mqtt', and it should show 'bridge connected'. (Protection mode needs to be off in the SSH & Web Terminal info tab to be able to do this.) 

It's probaly advisable to configure container restart options in Portainer, so that the hue2mqtt container gets restarted on any error condition. I've encountered this, so don't leave the default setting.

If you want to, go grab MQTT Explorer by Thomas Nordquist at http://mqtt-explorer.com/, which is an excellent tool to gain visibility of what is going on behind the scenes. On second thought, definitely go grab it. If using Hue, then MQTT Explorer should show 'hue' topics after connection.

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
