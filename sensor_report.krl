ruleset sensor_report {
  meta {
    use module temperature_store
  }

  global {

  }

  rule temperature_report {
    select when temperature_report get_temperatures
    pre {
      temperatures = temperature_store:temperatures()
      correlationId = event:attr("correlationId")
      rx = event:attr("Rx")
      tx = event:attr("Tx")
    }
    event:send({
          "eci": rx, "eid": "get_temperatures",
          "domain": "temperature_report", "type": "catch",
          "attrs": { "correlationId": correlationId, "temperatures": temperatures, "Tx": tx }
        });
  }
}
