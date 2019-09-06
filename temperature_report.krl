ruleset temperature_report {
  meta {
    use module manage_sensors
    shares __testing, temperature_reports, final_reports
  }
  global {
    __testing = { "queries": [ { "name": "__testing" },
                               { "name": "temperature_reports" },
                               {"name": "final_reports"}],
              "events": [ { "domain": "temperature_report", "type": "start"},
              {"domain": "clear", "type": "reports"}] };

    get_subscriptions = function() {
      manage_sensors:subscription_sensors()
    }

    get_sensors_length = function() {
      manage_sensors:subscription_sensors().filter(function(val, key) {
        val{"Rx_role"}.match(re#Sensor#)
      }).length()
    }

    get_id = function() {
      ent:id.defaultsTo(1)
    }

    temperature_reports = function() {
      ent:temperature_reports
    }

    final_reports = function() {
      length = ent:final_reports.length();
      length > 5 => ent:final_reports.slice(length - 5, length-1) | ent:final_reports
    }
  }

  rule start_temperature_report {
    select when temperature_report start
      foreach get_subscriptions() setting (subscription, txKey)
      pre {
        current = subscription
        isSensor = subscription{"Rx_role"}.match(re#Sensor#)
        correlationId = get_id()
        eci = txKey.klog("TX")
        rx = subscription{"Rx"}
      }
      if isSensor then
        event:send({
          "eci": eci, "eid": "temperature_report",
          "domain": "temperature_report", "type": "get_temperatures",
          "attrs": {"correlationId": correlationId, "Rx": rx, "Tx": eci }
        });
      always {
        ent:id := (ent:id + 1) on final
      }
  }

  rule catch_temperature_reports {
    select when temperature_report catch
    pre {
      temperatures = event:attr("temperatures")
      correlationId = event:attr("correlationId")
      tx = event:attr("Tx")
      sensor_id = get_subscriptions(){tx}{"sensor_id"}
    }
    always {
      ent:temperature_reports := ent:temperature_reports.defaultsTo({});
      ent:temperature_reports{[correlationId, sensor_id]} :=  temperatures;

      raise temperature_report event "check_status"
        attributes {"correlation_id": correlationId}
    }
  }

  rule check_report_status {
    select when temperature_report check_status
    pre {
      correlation_id = event:attr("correlation_id")
      returned_reports = ent:temperature_reports{correlation_id}
      num_returned = returned_reports.length()
      total = get_sensors_length()
      report = {
        "temperature_sensors": total,
        "responding": num_returned,
        "temperatures": returned_reports
      }
      report_obj = {
        "correlation_id": correlation_id,
        "report": report
      }
    }
    if num_returned == total then noop()
    fired {
      ent:final_reports := ent:final_reports.defaultsTo([]);
      ent:final_reports := ent:final_reports.append(report_obj)
    }
  }

    rule clear_reports {
      select when clear reports
      always {
        ent:temperature_reports := {};
        ent:id := 1;
        ent:final_reports := [];
      }
    }


}
