var TRUE = 1;
var FALSE = 0;


var find_index = func(val, vec) {
    forindex(var i; vec) if (vec[i] == val) return i;
    return nil;
}


var input = {
    combat:     "/ja37/mode/combat",
    trigger:    "/controls/armament/trigger",
    unsafe:    "/controls/armament/trigger-unsafe",
    mp_msg:     "/payload/armament/msg",
    atc_msg:    "/sim/messages/atc",
};

foreach (var prop; keys(input)) {
    input[prop] = props.globals.getNode(input[prop], 1);
}



### Pylons

# Pylon names
var STATIONS = pylons.STATIONS;
var M75 = 0;

var stations_list = keys(STATIONS);
if (ja37.variant_ja) append(stations_list, M75);


# Pylon lookup functions


### Weapon logic API (abstract class)
#
# Different weapon types should inherit this object and define the methods,
# so as to implement custom firing logic.
var WeaponLogic = {
    init: func(type) {
        me.type = type;
        me.combat = FALSE;
        me.unsafe = FALSE;
    },

    # Select a weapon.
    # Either a specific pylon (if the argument is specified),
    # or this type of weapon in general.
    # Must return TRUE on successful selection, and FALSE if it failed.
    # In the later case, the state of the weapon should be the same as after deselect().
    select: func(pylon=nil) {
        die("Called unimplemented abstract class method");
    },

    # Select the next weapon of this type.
    cycle_selection: func {
        die("Called unimplemented abstract class method");
    },

    # Deselect this weapon type.
    deselect: func {
        die("Called unimplemented abstract class method");
    },

    # Called when entering/leaving combat mode while this weapon type is selected.
    set_combat: func(combat) {
        me.combat = combat;
        if (!combat) me.set_unsafe(FALSE);
    },

    update_combat: func {
        me.set_combat(input.combat.getBoolValue());
    },

    # Called when the trigger safety changes position while this weapon type is selected.
    set_unsafe: func(unsafe) {
        if (!me.combat) unsafe = FALSE;
        me.unsafe = unsafe;
        if (!me.unsafe) me.set_trigger(FALSE);
    },

    armed: func {
        return me.combat and me.unsafe;
    },

    # Called when the trigger is pressed/released while this weapon type is selected.
    set_trigger: func(trigger) {
        die("Called unimplemented abstract class method");
    },

    uncage_IR_seeker: func {},
    reset_IR_seeker: func {},

    weapon_ready: func { return FALSE; },

    get_ammo: func { return 0; },

    # Return the active weapon (object from missile.nas), when it makes sense.
    get_weapon: func { return nil; },

    get_selected_pylons: func { return []; },
};


# Generic missile weapons, based on missiles.nas
var Missile = {
    parents: [WeaponLogic],

    # Selection order.
    pylons_priority: [STATIONS.R7V, STATIONS.R7H, STATIONS.V7V, STATIONS.V7H, STATIONS.S7V, STATIONS.S7H],

    new: func(type) {
        var w = { parents: [Missile], };
        w.init(type);
        w.selected = nil;
        w.station = nil;
        w.weapon = nil;
        w.fired = FALSE;
        return w;
    },

    # Internal function. pylon must be correct (loaded with correct type...)
    _select: func(pylon) {
        # First reset state
        me.deselect();

        me.selected = pylon;
        me.station = pylons.station_by_id(me.selected);
        me.weapon = me.station.getWeapons()[0];
        me.fired = FALSE;
        setprop("controls/armament/station-select-custom", pylon);

        me.update_combat();
    },

    deselect: func {
        me.set_unsafe(FALSE);
        me.set_combat(FALSE);
        me.selected = nil;
        me.station = nil;
        me.weapon = nil;
        me.fired = FALSE;
        setprop("controls/armament/station-select-custom", -1);
    },

    select: func(pylon=nil) {
        if (pylon == nil) {
            # Pylon not given as argument. Find a matching one.
            pylon = pylons.find_pylon_by_type(me.type, me.pylons_priority);
        } else {
            # Pylon given as argument. Check that it matches.
            if (!pylons.is_loaded_with(pylon, me.type)) pylon = nil;
        }

        # If pylon is nil at this point, selection failed.
        if (pylon == nil) {
            me.deselect();
            return FALSE;
        } else {
            me._select(pylon);
            return TRUE;
        }
    },

    cycle_selection: func {
        # Cycling is only possible when trigger is safed.
        if (me.unsafe) return !me.fired;

        var first = 0;
        if (me.selected != nil) {
            first = find_index(me.selected, me.pylons_priority)+1;
            if (first >= size(me.pylons_priority)) first = 0;
        }

        pylon = pylons.find_pylon_by_type(me.type, me.pylons_priority, first);
        if (pylon == nil) {
            me.deselect();
            return FALSE;
        } else {
            me._select(pylon);
            return TRUE;
        }
    },

    set_unsafe: func(unsafe) {
        # Call parent method
        call(WeaponLogic.set_unsafe, [unsafe], me);

        if (me.weapon != nil) {
            if (me.unsafe) {
                # Setup weapon
                me.weapon.start();

                # IR weapons parameters. For AJS, locked on bore.
                # I'm not sure about the JA, keeping it simple to use for now.
                if (!ja37.variant_ja and me.weapon.guidance == "heat") {
                    me.weapon.setAutoUncage(FALSE);
                    me.weapon.setCaged(TRUE);
                    me.weapon.setBore(TRUE);
                }
            } else {
                me.weapon.stop();
            }
        }

        # Select next weapon when safing after firing.
        if (me.fired and !me.unsafe) {
            me.fired = FALSE;
            me.cycle_selection();
        }
    },

    set_trigger: func(trigger) {
        if (!me.armed() or !trigger or me.weapon == nil) return;

        if (me.weapon.status != armament.MISSILE_LOCK) return;

        var callsign = me.weapon.callsign;
        var brevity = me.weapon.brevity;
        var phrase = brevity~" at: "~callsign;
        if (input.mp_msg.getBoolValue()) {
            armament.defeatSpamFilter(phrase);
        } else {
            input.atc_msg.setValue(phrase);
        }
        events.fireLog.push("Self: "~phrase);

        me.station.fireWeapon(0);

        me.weapon = nil;
        me.fired = TRUE;
    },

    uncage_IR_seeker: func {
        if (ja37.variant_ja or me.weapon == nil or me.weapon.status != armament.MISSILE_LOCK
            or (me.weapon.type != "RB-24J" and me.weapon.type != "RB-74")) return;

        me.weapon.setAutoUncage(TRUE);
        me.weapon.setBore(FALSE);
    },

    reset_IR_seeker: func {
        if (ja37.variant_ja or me.weapon == nil or (me.weapon.type != "RB-24J" and me.weapon.type != "RB-74")) return;

        me.weapon.stop();
        me.weapon.start();
        me.weapon.setAutoUncage(FALSE);
        me.weapon.setCaged(TRUE);
        me.weapon.setBore(TRUE);
    },

    get_weapon: func { return me.weapon; },

    weapon_ready: func { return me.weapon != nil; },

    get_ammo: func { return pylons.get_ammo(me.type); },

    get_selected_pylons: func { return [me.selected]; },
};


var SubModelWeapon = {
    parents: [WeaponLogic],

    new: func(type) {
        var w = { parents: [SubModelWeapon], };
        w.init(type);
        w.selected = [];
        w.stations = [];
        w.weapons = [];
        return w;
    },

    # Argument ignored. Always select all weapons of this type.
    select: func (pylon=nil) {
        me.selected = pylons.find_all_pylons_by_type(me.type);

        if (size(me.selected) == 0) {
            me.deselect();
            return FALSE;
        }

        setsize(me.stations, size(me.selected));
        setsize(me.weapons, size(me.selected));
        forindex(var i; me.selected) {
            me.stations[i] = pylons.station_by_id(me.selected[i]);
            me.weapons[i] = me.stations[i].getWeapons()[0];
        }

        if (!me.weapon_ready()) {
            # no ammo
            me.deselect();
            return FALSE;
        }

        setprop("controls/armament/station-select-custom", size(me.selected) > 0 ? me.selected[0] : -1);

        me.update_combat();

        return TRUE;
    },

    deselect: func (pylon=nil) {
        me.set_unsafe(FALSE);
        me.set_combat(FALSE);
        me.selected = [];
        me.stations = [];
        me.weapons = [];
        setprop("controls/armament/station-select-custom", -1);
    },

    cycle_selection: func {},

    set_unsafe: func(unsafe) {
        # Call parent method
        call(WeaponLogic.set_unsafe, [unsafe], me);

        foreach(var weapon; me.weapons) {
            if (me.unsafe) weapon.start();
            else weapon.stop();
        }
    },

    set_trigger: func(trigger) {
        if (!me.armed()) trigger = FALSE;

        foreach(var weapon; me.weapons) {
            weapon.trigger.setBoolValue(trigger and weapon.operableFunction());
        }
    },

    get_ammo: func {
        var count = 0;
        foreach(var weapon; me.weapons) {
            count += weapon.getAmmo();
        }
        return count;
    },

    weapon_ready: func {
        return me.get_ammo() > 0;
    },

    get_selected_pylons: func {
        return me.selected;
    },
};


### Selected weapon type.
if (ja37.variant_ja) {
    var weapons = [
        Missile.new("RB-74"),
        Missile.new("RB-99"),
        Missile.new("RB-71"),
        Missile.new("RB-24J"),
        SubModelWeapon.new("M70 ARAK"),
    ];

    # Indices in the previous array
    var IRRB = [0, 3];

    var internal_gun = SubModelWeapon.new("M75 AKAN");
} else {
    var weapons = [
        Missile.new("RB-74"),
        Missile.new("RB-24J"),
        Missile.new("RB-24"),
        SubModelWeapon.new("M55 AKAN"),
        SubModelWeapon.new("M70 ARAK"),
        Missile.new("RB-15F"),
        Missile.new("RB-04E"),
        Missile.new("RB-75"),
        Missile.new("RB-05A"),
        Missile.new("M90"),
    ];

    var IRRB = [0, 1, 2];
}

var selected_index = -2;
var selected = nil;

# Internal function.
var _set_selected_index = func(index) {
    selected_index = index;
    if (index >= 0) selected = weapons[index];
    elsif (index == -1 and ja37.variant_ja) selected = internal_gun;
    else selected = nil;
}

var get_weapon = func {
    if (selected == nil) return nil;
    else return selected.get_weapon();
}

var get_current_ammo = func {
    if (selected == nil) return -1;
    else return selected.get_ammo();
}

var get_selected_pylons = func {
    if (selected == nil) return [];
    else return selected.get_selected_pylons();
}

### Controls
## Weapon selection.

var _deselect_current = func {
    if (selected != nil) selected.deselect();
}

var cycle_weapon_type = func {
    _deselect_current();

    # Cycle through weapons, starting from the previous one.
    var prev = selected_index;
    if (prev < 0) prev = 0;
    var i = prev;
    i += 1;
    if (i >= size(weapons)) i = 0;

    while (i != prev) {
        if (weapons[i].select()) {
            _set_selected_index(i);
            return
        }
        i += 1;
        if (i >= size(weapons)) i = 0;
    }
    # We are back to the first weapon. Last try
    if (weapons[i].select()) {
        _set_selected_index(i);
    } else {
        # Nothing found
        _set_selected_index(-2);
    }
}

var select_cannon = func {
    _deselect_current();
    internal_gun.select();
    _set_selected_index(-1);
}

var select_IRRB = func {
    _deselect_current();
    foreach(var i; IRRB) {
        if (weapons[i].select()) {
            _set_selected_index(i);
            return;
        }
    }
    # Not found
    _set_selected_index(-2);
}

var cycle_weapon = func {
    if (selected != nil) selected.cycle_selection();
}

var deselect_weapon = func {
    _deselect_current();
    _set_selected_index(-2);
}

var select_pylon = func(pylon) {
    _deselect_current();

    var type = pylons.station_by_id(pylon).singleName;
    forindex(var i; weapons) {
        # Find matching weapon type.
        if (weapons[i].type == type) {
            # Attempt to load this pylon.
            if (weapons[i].select(pylon)) {
                _set_selected_index(i);
            } else {
                _set_selected_index(-2);
            }
            return;
        }
    }
}


## Others
var toggle_trigger_safe = func {
    var unsafe = !input.unsafe.getBoolValue();
    input.unsafe.setBoolValue(unsafe);

    if (unsafe) {
        screen.log.write("Trigger unsafed", 1, 0, 0);
    } else {
        screen.log.write("Trigger safed", 0, 0, 1);
    }
}


# IR seeker release button
var uncageIR = func {
    if (selected != nil) selected.uncage_IR_seeker();
}

var resetIR = func {
    if (selected != nil) selected.reset_IR_seeker();
}

# Pressing the button uncages, holding it resets
var uncageIRButtonTimer = maketimer(1, resetIR);
uncageIRButtonTimer.singleShot = TRUE;
uncageIRButtonTimer.simulatedTime = TRUE;

var uncageIRButton = func (pushed) {
    if (pushed) {
        uncageIR();
        uncageIRButtonTimer.start();
    } else {
        uncageIRButtonTimer.stop();
    }
}



var trigger_listener = func (node) {
    if (selected != nil) selected.set_trigger(node.getBoolValue());
}

var unsafe_listener = func (node) {
    if (selected != nil) selected.set_unsafe(node.getBoolValue());
}

var combat_listener = func (node) {
    if (selected != nil) selected.set_combat(node.getBoolValue());
}

setlistener(input.combat, combat_listener, 0, 0);
setlistener(input.unsafe, unsafe_listener, 0, 0);
setlistener(input.trigger, trigger_listener, 0, 0);