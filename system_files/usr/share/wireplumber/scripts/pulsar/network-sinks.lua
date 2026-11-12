-- Pulsar: a speaker on the network is used only when someone picks it.
--
-- PipeWire marks every sink it reaches over the network (AirPlay, PulseAudio
-- tunnels, ROC, RTP, Snapcast) with node.network = true. WirePlumber ranks
-- them like local outputs, so on a machine with no local output the first
-- speaker discovered becomes the default and the fallback target, and every
-- desktop sound plays there. An AirPlay soundbar then drops the TV it was
-- playing for a notification blip, and does not switch back.
--
-- These hooks leave network sinks out of the automatic choices only:
--   * the default node, unless the user configured it or it is in the
--     user's stored history (those hooks run first and select it);
--   * the fallback target for a stream with nowhere else to go.
-- A stream that names its target, or follows a default the user chose,
-- still reaches the speaker.

cutils = require ("common-utils")
log = Log.open_topic ("s-pulsar-network-sinks")

local function is_network (props)
  return props ~= nil and cutils.parseBool (props ["node.network"])
end

SimpleEventHook {
  name = "pulsar/default-nodes/skip-network-nodes",
  after = { "default-nodes/find-selected-default-node",
            "default-nodes/find-stored-default-node" },
  before = "default-nodes/find-best-default-node",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "select-default-node" },
    },
  },
  execute = function (event)
    local available = event:get_data ("available-nodes")
    available = available and available:parse ()
    if not available then
      return
    end

    -- Only find-best-default-node reads what is left. A node the user chose
    -- was selected by the hooks before this one, above the priority at which
    -- find-best-default-node keeps the selection without ranking anything.
    local kept = {}

    for _, props in ipairs (available) do
      if is_network (props) then
        log:info ("not choosing network node " .. tostring (props ["node.name"]) ..
            " as default on its own")
      else
        table.insert (kept, Json.Object (props))
      end
    end

    event:set_data ("available-nodes", Json.Array (kept))
  end
}:register ()

-- Marks a stream that reached the fallback search with no target yet.
SimpleEventHook {
  name = "pulsar/linking/mark-fallback-target",
  after = { "linking/find-defined-target",
            "linking/find-filter-target",
            "linking/find-media-role-target",
            "linking/find-media-role-sink-target",
            "linking/find-audio-group-target",
            "linking/find-default-target" },
  before = "linking/find-best-target",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "select-target" },
    },
  },
  execute = function (event)
    if event:get_data ("target") == nil then
      event:set_data ("pulsar.fallback-target", true)
    end
  end
}:register ()

SimpleEventHook {
  name = "pulsar/linking/skip-network-fallback-target",
  after = "linking/find-best-target",
  before = { "linking/get-filter-from-target", "linking/prepare-link" },
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "select-target" },
    },
  },
  execute = function (event)
    local target = event:get_data ("target")
    if target == nil or not event:get_data ("pulsar.fallback-target") then
      return
    end

    local node = target:get_associated_proxy ("node")
    local props = node and node.properties or target.properties
    if is_network (props) then
      log:info (event:get_subject (), "not sending to network node " ..
          tostring (props ["node.name"]) .. " as a fallback")
      event:set_data ("target", nil)
    end
  end
}:register ()

-- WirePlumber loads this script after its own default-nodes and linking
-- hooks, so a speaker PipeWire found before then may already have been
-- chosen without these hooks. Choose again now that they are in place.
local source = Plugin.find ("standard-event-source")
if source then
  source:call ("schedule-rescan", "default-nodes")
  source:call ("schedule-rescan", "linking")
end
