# acMqtt Frequently asked

I get asked about many things. Hopefully these can help in advance.

## I can't get a device on application XXX with the keywords MQTT, yyy to work. Why?

It may well be that I have not yet considered the eventuality. I consider a lot, but can't consider everything.

Opening an issue at https://github.com/autoSteve/acMqtt and not keep living with the frustration is my suggestion.

Either that or you may have a subtle error/'interesting' thing in the keywords you're using. The script checks for most stuff-ups, but won't be perfect. It's reasonably complex code, and in my experience complex code is rarely perfect. So open an issue, or triple check your keywords against the readme.

## I set up Mosquitto on HA, yet the automation controller won't connect to it. Why?

Is there a default `mqtt:` statement in your configuration.yaml?

Is there any error being reported in the automation controller error or event log? (If so, open a discussion topic if you can't work it out and my little community and I might be able to help.)

## Do I need to deploy all the scripts?

Nope. `MQTT send receive` is the only one. `Heartbeat` is a belt/braces to ensure that `MQTT sed receive` or `HUE send receive` get restarted promptly should they lock up for any reason. (I last saw a lock-up a few years back, and it was my own fault.) `HUE send receive` is for Philips Hue Hub integration only. A better alternative for Hue Hub is a generic Zigbee coordinator, along with Zigbee2MQTT and code at https://github.com/geoffwatts/cbus2zigbee. I contribute to that effort. Or rather wrote most of it...

## Do I need to configure anything for the Heartbeat script?

Nope. Install it as a resident, zero sleep script. Enable it. Job done.

The event log will tell you when it has registered scripts to monitor.

## Does it matter what I call the script names?

Call them Shirley and Bob for all I care. Heartbeat will work out the `MQTT send receive` and `HUE send receive` script names because those scripts register themselves with heartbeat using their configured name. Heartbeat could be called Gavin.

It would probably be more self-documenting if you didn't call them Shirley, Bob and Gavin though.

## I'm going to raise an issue. And the issue reads "Please help me configure this!" Should I?

Please don't. I have GitHub Discussions set up at acMqtt, and this is the perfect placement. Both myself and others who are experienced chip in there. It is highly unusual that you'd be left hanging as I get notified and am usually around, and quite responsive. Unless I'm on a vacation and staring at a volcano in Iceland. Then you'll probably be left hanging...

Reading the readme is the first point of call. I try to cover everything there (but if the readme is deficient, then by all means raise an issue and not a discussion).

## I want to upgrade C-Bus device firmware on my switches, dimmers and relays. How?

Can't be done. At least not by you or I. Clipsal Integrated Systems probably can, but the firmware is rigorously tested to match the device hardware that it's installed on, and where firmware doesn't operate as it should then it's device warranty time. CiS have been known to replace outside of warranty period for serious defects, because they are serious technology developers and expect things like wall switches to be installed in a wall and used for decades, unlike your modern day IOT devices that you get from Harvey Norman or Google.

## I want to upgrade firmware on my Automation Controller. How?

First up, great idea. I do as soon as new code is released, shortly after reading its release notes.

The automation controller is a customised OEM of a device called Logic Machine by Embedded Systems SIA. (They have a forum, and loads of stuff there that is Lua-related is applicable. https://forum.logicmachine.net/.) Unlike a light switch or a dimmer module, firmware for the automation controller can add new capabilities, or fix long-standing problems. The addition of emergency lighting support by Schneider/CiS for the NAC/NAC2 not so long ago is a great example. Fixing an issue with event scripts always executing during ramping is another. Other contributions may be included by Embedded Systems.

Just do it. You can usually downgrade if it doesn't work out, but do have a backup based on the firmware you're downgrading to handy.

Release intervals tend to be at glacial pace compared to modern-day agile development, but that is because the CiS folk try to get things carefully right (because probably installed in a board, configured, and left to happily run without reboot for years).

To upgrade, get the .zip of the new code (for the _correct_ device type), unzip it, _read the release notes_, then head to the automation controller System button, which will open a new browser tab, then select `System | Upgrade firmware`, choose the .img file, okay button, and sit back and relax for a short amount of time.