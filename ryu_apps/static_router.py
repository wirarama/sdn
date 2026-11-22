"""
static_router.py - Ryu app (OpenFlow 1.3) untuk routing proaktif dari file JSON.

Format SDN_ROUTE_CONFIG:
  {"version": 3, "label": "QoS-Dijkstra",
   "flows": {"<dpid>": [{"src": "10.0.0.1", "dst": "10.0.0.7", "out_port": 2}, ...]}}

Variabel lingkungan:
  SDN_ROUTE_CONFIG    file konfigurasi routing (dipantau setiap 0.5 s)
  SDN_ROUTE_STATE     file status (versi yang sudah terpasang per switch)
  SDN_PORT_STATS      file CSV statistik port (kosong = nonaktif)
  SDN_STATS_INTERVAL  interval polling statistik port (detik)
"""
import csv
import json
import os
import time

from ryu.base import app_manager
from ryu.controller import ofp_event
from ryu.controller.handler import CONFIG_DISPATCHER, MAIN_DISPATCHER, DEAD_DISPATCHER, set_ev_cls
from ryu.lib import hub
from ryu.ofproto import ofproto_v1_3

CONFIG_PATH = os.environ.get("SDN_ROUTE_CONFIG", "/tmp/sdn_routes.json")
STATE_PATH = os.environ.get("SDN_ROUTE_STATE", CONFIG_PATH + ".state")
PORT_STATS_PATH = os.environ.get("SDN_PORT_STATS", "")
STATS_INTERVAL = float(os.environ.get("SDN_STATS_INTERVAL", "1.0"))
POLL_INTERVAL = 0.5
ROUTE_PRIORITY = 100
PORT_COLS = ["ts", "dpid", "port", "rx_packets", "tx_packets", "rx_bytes", "tx_bytes", "rx_dropped", "tx_dropped"]


class StaticRouter(app_manager.RyuApp):
    OFP_VERSIONS = [ofproto_v1_3.OFP_VERSION]

    def __init__(self, *args, **kwargs):
        super(StaticRouter, self).__init__(*args, **kwargs)
        self.datapaths = {}
        self.config = None
        self.config_mtime = None
        self.applied = {}
        self.pending = {}
        self.stats_writer = None
        if PORT_STATS_PATH:
            is_new = not os.path.exists(PORT_STATS_PATH)
            self.stats_file = open(PORT_STATS_PATH, "a", newline="")
            self.stats_writer = csv.writer(self.stats_file)
            if is_new:
                self.stats_writer.writerow(PORT_COLS)
                self.stats_file.flush()
            hub.spawn(self._stats_loop)
        hub.spawn(self._watch_config)

    # ------------------------------------------------------------ switch --
    @set_ev_cls(ofp_event.EventOFPSwitchFeatures, CONFIG_DISPATCHER)
    def _switch_features(self, ev):
        dp = ev.msg.datapath
        self.datapaths[dp.id] = dp
        self.logger.info("switch terhubung dpid=%s", dp.id)
        if self.config is not None:
            self._install(dp)

    @set_ev_cls(ofp_event.EventOFPStateChange, [MAIN_DISPATCHER, DEAD_DISPATCHER])
    def _state_change(self, ev):
        dp = ev.datapath
        if ev.state == DEAD_DISPATCHER and dp.id is not None:
            self.datapaths.pop(dp.id, None)
            self.applied.pop(dp.id, None)
            self._write_state()

    # ------------------------------------------------------------ config --
    def _read_config(self):
        try:
            mtime = os.path.getmtime(CONFIG_PATH)
        except OSError:
            return False
        if mtime == self.config_mtime:
            return False
        try:
            with open(CONFIG_PATH) as f:
                cfg = json.load(f)
        except (OSError, ValueError):
            return False                      # file sedang ditulis, coba lagi
        self.config_mtime = mtime
        if self.config is not None and cfg.get("version") == self.config.get("version"):
            return False
        self.config = cfg
        return True

    def _watch_config(self):
        while True:
            if self._read_config():
                self.logger.info("konfigurasi routing v%s (%s)", self.config.get("version"), self.config.get("label"))
                for dp in list(self.datapaths.values()):
                    self._install(dp)
            hub.sleep(POLL_INTERVAL)

    def _install(self, dp):
        ofp, parser = dp.ofproto, dp.ofproto_parser
        dp.send_msg(parser.OFPFlowMod(datapath=dp, command=ofp.OFPFC_DELETE, table_id=ofp.OFPTT_ALL,
                                      out_port=ofp.OFPP_ANY, out_group=ofp.OFPG_ANY, match=parser.OFPMatch()))
        rules = self.config.get("flows", {}).get(str(dp.id), [])
        for r in rules:
            match = parser.OFPMatch(eth_type=0x0800, ipv4_src=r["src"], ipv4_dst=r["dst"])
            inst = [parser.OFPInstructionActions(ofp.OFPIT_APPLY_ACTIONS,
                                                 [parser.OFPActionOutput(int(r["out_port"]))])]
            dp.send_msg(parser.OFPFlowMod(datapath=dp, priority=ROUTE_PRIORITY, match=match, instructions=inst))
        req = parser.OFPBarrierRequest(dp)
        dp.set_xid(req)
        self.pending[dp.id] = (req.xid, self.config.get("version"))
        dp.send_msg(req)

    @set_ev_cls(ofp_event.EventOFPBarrierReply, [CONFIG_DISPATCHER, MAIN_DISPATCHER])
    def _barrier_reply(self, ev):
        dp = ev.msg.datapath
        pend = self.pending.get(dp.id)
        if pend and pend[0] == ev.msg.xid:
            self.applied[dp.id] = pend[1]
            del self.pending[dp.id]
            self._write_state()

    def _write_state(self):
        state = {"version": self.config.get("version") if self.config else None,
                 "applied": {str(k): v for k, v in self.applied.items()},
                 "connected": sorted(self.datapaths), "time": time.time()}
        tmp = STATE_PATH + ".tmp"
        with open(tmp, "w") as f:
            json.dump(state, f)
        os.replace(tmp, STATE_PATH)

    # ------------------------------------------------------- port stats --
    def _stats_loop(self):
        while True:
            for dp in list(self.datapaths.values()):
                dp.send_msg(dp.ofproto_parser.OFPPortStatsRequest(dp, 0, dp.ofproto.OFPP_ANY))
            hub.sleep(STATS_INTERVAL)

    @set_ev_cls(ofp_event.EventOFPPortStatsReply, MAIN_DISPATCHER)
    def _port_stats_reply(self, ev):
        dp, now = ev.msg.datapath, time.time()
        for st in ev.msg.body:
            if st.port_no > dp.ofproto.OFPP_MAX:
                continue
            self.stats_writer.writerow([round(now, 3), dp.id, st.port_no, st.rx_packets, st.tx_packets,
                                        st.rx_bytes, st.tx_bytes, st.rx_dropped, st.tx_dropped])
        self.stats_file.flush()
