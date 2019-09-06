ruleset manage_sensors {
  meta {
    use module io.picolabs.wrangler alias wrangler
    use module threshold_violation_manager
    use module io.picolabs.subscription alias Subscriptions
    shares __testing, getChildren, nameFromID, sensors, sensorTemperatures, IDFromName, subscription_sensors
    provides subscription_sensors
  }

  global {
    __testing = { "queries": [ { "name": "__testing" },
                                {"name": "nameFromID", "args": ["sensor_id"]},
                                {"name": "IDFromName", "args": ["name"]},
                                {"name": "getChildren"},
                                {"name": "sensors"},
                                {"name": "sensorTemperatures"},
                                {"name": "subscription_sensors"}],
                "events": [ { "domain": "sensor", "type": "new_sensor",
                            "attrs": [ "sensor_id"] },
                            { "domain": "collection", "type": "empty" },
                            { "domain": "sensor", "type": "unneeded_sensor",
                            "attrs": [ "sensor_id"] }] }

    nameFromID = function(sensor_id) {
      "Sensor " + sensor_id + " Pico"
    }

    IDFromName = function(name) {
      name.extract(re#Sensor (\w+) Pico#)[0]
    }

    getChildren = function() {
      wrangler:children()
    }

    sensors = function() {
      ent:sensors
    }

    subscription_sensors = function() {
      ent:subscription_sensors
    }

    defaultTemperature = function() {
      ent:default_threshold.defaultsTo(74)
    }

    isSensor = function(name) {
      name.match(re#Sensor#)
    }

    sensorTemperatures = function() {
      sensors = ent:subscription_sensors.filter(function(v, k) {
        role = v{"Rx_role"};
        isSensor(role);
      });
      temperatures = sensors.map(function(val, key) {
        wrangler:skyQuery(key, "temperature_store", "temperatures", {})
      });
      temperatures.values();
    }

    get_wellKnown_eci = function(eci) {
      url = meta:host+"/sky/cloud/"+eci+"/io.picolabs.subscription/wellKnown_Rx";
      val = http:get(url.klog("url")){"content"}.decode(){"id"};
      val.klog("wellknown eci");
      val;
    }
  }

  rule sensor_already_exists {
    select when sensor new_sensor
    pre {
      sensor_id = event:attr("sensor_id")
      exists = ent:sensors >< sensor_id
    }
    if exists then
      send_directive("sensor_ready", {"sensor_id": sensor_id})
  }

  rule new_sensor {
    select when sensor new_sensor
    pre {
      sensor_id = event:attr("sensor_id")
      exists = ent:sensors >< sensor_id
    }
    if not exists
    then
      noop()
    fired {
      raise wrangler event "child_creation"
        attributes { "name": nameFromID(sensor_id),
                     "color": "#ffff00",
                     "sensor_id": sensor_id,
                     "rids": ["temperature_store", "wovyn_base", "sensor_profile", "subscription_manager", "sensor_report"] }
    }
  }

  rule store_new_sensor {
    select when wrangler child_initialized
    pre {
      the_sensor = {"id": event:attr("id"), "eci": event:attr("eci")}
      sensor_id = event:attr("rs_attrs"){"sensor_id"}
    }
    if sensor_id.klog("found sensor_id")
    then
      noop()
    fired {
      ent:sensors := ent:sensors.defaultsTo({});
      ent:sensors{[sensor_id]} := the_sensor;
      raise sensor event "initialized"
        attributes {"sensor_id": sensor_id}
    }
  }

    rule initialized_event {
        // install rulesets and subscribe
      select when sensor initialized
      pre {
        sensor_id = event:attr("sensor_id")
        name = nameFromID(sensor_id)
        smsNumber = 8017353755
        location = "logan apartment"
        sensor = ent:sensors{[sensor_id]}
        tempThreshold = defaultTemperature()
      }
      event:send({
        "eci": sensor{"eci"}, "eid": "initialize_profile",
        "domain": "sensor", "type": "profile_updated",
        "attrs": {"name": nameFromID(sensor_id), "location": location, "toPhoneNumber": smsNumber, "tempThreshold": tempThreshold}
      });
      always {
        raise wrangler event "subscription" attributes
         {
           "name" : sensor_id,
           "Rx_role": "Sensor",
           "Tx_role": "Collection",
           "channel_type": "subscription",
           "wellKnown_Tx" : get_wellKnown_eci(sensor{"eci"})
         }
      }
    }

  rule subscription_added {
    // when subscription has been added, store important information in ent:susbscription_sensors
    select when wrangler subscription_added
    pre {
      attributes = event:attrs.klog("ATTRIBUTES")
      sensor_id = event:attr("name")
      tx = event:attr("Tx").klog("SUBSCRIP TX")
      sensor = Subscriptions:established().filter(function(x) {
        x{"Tx"} == tx
      }).head().klog("SENSOR")
      id = sensor{"Id"} //event:attr("Id")
      rx_role = sensor{"Rx_role"}.klog("RXROLE")
      rx = sensor{"Rx"}.klog("SUBSCRIPRX")
      //rx_role = event:attr("Tx_role").klog("RXROLE HERE")
      // rx = event:attr("Rx").klog("SUBSCRIP RX")
      // eci = ent:sensors.get([sensor_id, "eci"])
      // id2 = ent:sensors.get([sensor_id, "id"])
      new_obj = {
        "sensor_id": sensor_id, "Id": id, "Rx_role": rx_role, "Rx": rx
      }
    }
    always {
      ent:subscription_sensors := ent:subscription_sensors.defaultsTo({});
      ent:subscription_sensors{[tx]} := new_obj;
    }
  }

  rule unneeded_sensor {
    select when sensor unneeded_sensor
    pre {
      sensor_id = event:attr("sensor_id")
      //exists = ent:sensors >< sensor_id
      child_to_delete = nameFromID(sensor_id)
      subscription = ent:subscription_sensors.filter(function(val, key) {
        val{"sensor_id"} == sensor_id
      })
      exists = (subscription.values().length() > 0) => true | false
      idToDelete = subscription.values()[0]{"Id"}
      TxToDelete = subscription.keys()[0]
    }
    if exists then
      send_directive("deleting_sensor", {"sensor_id":sensor_id})
    fired {
      raise wrangler event "child_deletion"
        attributes {"name": child_to_delete};
      clear ent:sensors{[sensor_id]};
      clear ent:subscription_sensors{[TxToDelete]};
      raise wrangler event "subscription_cancellation"
        attributes {"Id":idToDelete}
    }
  }

  rule auto_accept {
    select when wrangler inbound_pending_subscription_added
    pre {
      acceptable = (event:attr("Rx_role")=="Sensor"
                && event:attr("Tx_role") == "Collection");
      new_obj = {
         "sensor_id": event:attr("name"), "Id": event:attr("Id"), "Rx_role": event:attr("Tx_role"), "Rx": event:attr("Rx")
      }
      tx = event:attr("Tx")
    }
    if acceptable then noop();
    fired {
      ent:subscription_sensors := ent:subscription_sensors.defaultsTo({});
      ent:subscription_sensors{[tx]} = new_obj;
      raise wrangler event "pending_subscription_approval"
        attributes event:attrs
    } else {
      raise wrangler event "inbound_rejection"
        attributes { "Rx": event:attr("Rx") }
    }
  }

  // rule threshold_violation {
  //   select when wovyn threshold_violation
  //   pre {
  //     temperature = event:attr("temperature")
  //     timestamp = event:attr("timestamp")
  //     message = "Temperature Violation at " + timestamp + ". Temperature is " + temperature + " degrees Farenheit."
  //   }
  //   always {
  //     raise sms event "send_threshold_violation"
  //       attributes {"message": message}
  //   }
  // }

  // rule send_sms {
  //   select when sms send_threshold_violation
  //   pre {
  //     message = event:attr("message")
  //   }
  //   sms_manager:send_sms(message)

  // }


  rule collection_empty {
    select when collection empty
    always {
      ent:sensors := {};
      ent:subscription_sensors := {};
    }
  }

}
