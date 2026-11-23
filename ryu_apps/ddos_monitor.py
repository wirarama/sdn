"""
ddos_monitor.py - Ryu app (OpenFlow 1.3): L2 learning switch + monitoring flow stats
+ mitigasi DDoS berbasis blocklist.

Variabel lingkungan:
  SDN_DDOS_OUT        folder keluaran CSV (flow_stats.csv, packet_in.csv)
  SDN_STATS_INTERVAL  interval polling flow stats (detik)
  SDN_FLOW_IDLE       idle timeout flow (detik)
  SDN_BLOCKLIST       file JSON blocklist: {"version": 2, "rules": [{"dpid": 3, "in_port": 3, "timeout": 120}]}
"""
import csv
import json
import os
import time

from ryu.base import app_manager
from ryu.controller import ofp_event
from ryu.controller.handler import CONFIG_DISPATCHER, MAIN_DISPATCHER, DEAD_DISPATCHER, set_ev_cls
from ryu.lib import hub
from ryu.lib.packet import packet, ethernet, ipv4, ether_types
from ryu.ofproto import ofproto_v1_3

OUT_DIR = os.environ.get("SDN_DDOS_OUT", "/tmp/sdn_ddos")
STATS_INTERVAL = float(os.environ.get("SDN_STATS_INTERVAL", "2.0"))
FLOW_IDLE = int(os.environ.get("SDN_FLOW_IDLE", "5"))
BLOCKLIST_PATH = os.environ.get("SDN_BLOCKLIST", os.path.join(OUT_DIR, "blocklist.json"))

FLOW_PRIORITY = 10
DROP_PRIORITY = 1000
DROP_COOKIE = 0xDD05
FLOW_COLS = ["ts", "dpid", "in_port", "eth_src", "eth_dst", "ipv4_src", "ipv4_dst", "ip_proto",
             "packet_count", "byte_count", "duration"]


class DDoSMonitor(app_manager.RyuApp):
    OFP_VERSIONS = [ofproto_v1_3.OFP_VERSION]

    def __init__(self, *args, **kwargs):
        super(DDoSMonitor, self).__init__(*args, **kwargs)
        self.mac_to_port = {}
        self.datapaths = {}
        self.pktin = {}
        self.req_ts = {}
        self.block_rules, self.block_mtime, self.block_version = [], None, None
        if not os.path.isdir(OUT_DIR):
            os.makedirs(OUT_DIR)
        self.flow_f, self.flow_w = self._open_csv("flow_stats.csv", FLOW_COLS)
        self.pin_f, self.pin_w = self._open_csv("packet_in.csv", ["ts", "dpid", "packet_in"])
        hub.spawn(self._monitor)
        hub.spawn(self._watch_blocklist)

    def _open_csv(self, name, cols):
        path = os.path.join(OUT_DIR, name)
        is_new = not os.path.exists(path) or os.path.getsize(path) == 0
        f = open(path, "a", newline="")
        w = csv.writer(f)
        if is_new:
            w.writerow(cols)
            f.flush()
        return f, w

    def add_flow(self, dp, priority, match, actions, idle=0, hard=0, cookie=0):
        ofp, parser = dp.ofproto, dp.ofproto_parser
        inst = [parser.OFPInstructionActions(ofp.OFPIT_APPLY_ACTIONS, actions)] if actions else []
        dp.send_msg(parser.OFPFlowMod(datapath=dp, priority=priority, match=match, instructions=inst,
                                      idle_timeout=idle, hard_timeout=hard, cookie=cookie))

    # ------------------------------------------------------------ switch --
    @set_ev_cls(ofp_event.EventOFPSwitchFeatures, CONFIG_DISPATCHER)
    def _switch_features(self, ev):
        dp = ev.msg.datapath
        ofp, parser = dp.ofproto, dp.ofproto_parser
        self.datapaths[dp.id] = dp
        self.add_flow(dp, 0, parser.OFPMatch(), [parser.OFPActionOutput(ofp.OFPP_CONTROLLER, ofp.OFPCML_NO_BUFFER)])
        self.add_flow(dp, 1, parser.OFPMatch(eth_type=ether_types.ETH_TYPE_IPV6), [])   # buang IPv6 (noise ND/RS)
        self._apply_block(dp)
        self.logger.info("switch terhubung dpid=%s", dp.id)

    @set_ev_cls(ofp_event.EventOFPStateChange, [MAIN_DISPATCHER, DEAD_DISPATCHER])
    def _state_change(self, ev):
        if ev.state == DEAD_DISPATCHER and ev.datapath.id is not None:
            self.datapaths.pop(ev.datapath.id, None)

    @set_ev_cls(ofp_event.EventOFPPacketIn, MAIN_DISPATCHER)
    def _packet_in(self, ev):
        msg = ev.msg
        dp = msg.datapath
        ofp, parser = dp.ofproto, dp.ofproto_parser
        in_port = msg.match["in_port"]
        pkt = packet.Packet(msg.data)
        eth = pkt.get_protocol(ethernet.ethernet)
        if eth is None or eth.ethertype in (ether_types.ETH_TYPE_LLDP, ether_types.ETH_TYPE_IPV6):
            return
        self.pktin[dp.id] = self.pktin.get(dp.id, 0) + 1
        table = self.mac_to_port.setdefault(dp.id, {})
        table[eth.src] = in_port
        out_port = table.get(eth.dst, ofp.OFPP_FLOOD)
        actions = [parser.OFPActionOutput(out_port)]
        if out_port != ofp.OFPP_FLOOD:
            ip4 = pkt.get_protocol(ipv4.ipv4)
            if ip4 is not None:
                match = parser.OFPMatch(in_port=in_port, eth_type=ether_types.ETH_TYPE_IP, eth_src=eth.src,
                                        eth_dst=eth.dst, ipv4_src=ip4.src, ipv4_dst=ip4.dst, ip_proto=ip4.proto)
                self.add_flow(dp, FLOW_PRIORITY, match, actions, idle=FLOW_IDLE)
        data = msg.data if msg.buffer_id == ofp.OFP_NO_BUFFER else None
        dp.send_msg(parser.OFPPacketOut(datapath=dp, buffer_id=msg.buffer_id, in_port=in_port,
                                        actions=actions, data=data))

    # -------------------------------------------------------- monitoring --
    def _monitor(self):
        while True:
            now = time.time()
            for dp in list(self.datapaths.values()):
                self.req_ts[dp.id] = now
                dp.send_msg(dp.ofproto_parser.OFPFlowStatsRequest(dp, table_id=0))
                self.pin_w.writerow([round(now, 3), dp.id, self.pktin.get(dp.id, 0)])
                self.pktin[dp.id] = 0
            self.pin_f.flush()
            hub.sleep(STATS_INTERVAL)

    @set_ev_cls(ofp_event.EventOFPFlowStatsReply, MAIN_DISPATCHER)
    def _flow_stats_reply(self, ev):
        dp = ev.msg.datapath
        ts = round(self.req_ts.get(dp.id, time.time()), 3)
        for st in ev.msg.body:
            if st.priority != FLOW_PRIORITY:
                continue
            m = st.match
            self.flow_w.writerow([ts, dp.id, m.get("in_port"), m.get("eth_src"), m.get("eth_dst"),
                                  m.get("ipv4_src"), m.get("ipv4_dst"), m.get("ip_proto"),
                                  st.packet_count, st.byte_count, round(st.duration_sec + st.duration_nsec / 1e9, 3)])
        self.flow_f.flush()

    # --------------------------------------------------------- mitigasi --
    def _watch_blocklist(self):
        while True:
            try:
                mtime = os.path.getmtime(BLOCKLIST_PATH)
            except OSError:
                mtime = None
            if mtime is not None and mtime != self.block_mtime:
                try:
                    with open(BLOCKLIST_PATH) as f:
                        cfg = json.load(f)
                except (OSError, ValueError):
                    cfg = None
                if cfg is not None:
                    self.block_mtime = mtime
                    self.block_rules = cfg.get("rules", [])
                    self.block_version = cfg.get("version")
                    self.logger.info("blocklist v%s: %d aturan", self.block_version, len(self.block_rules))
                    for dp in list(self.datapaths.values()):
                        self._apply_block(dp)
            hub.sleep(0.5)

    def _apply_block(self, dp):
        ofp, parser = dp.ofproto, dp.ofproto_parser
        dp.send_msg(parser.OFPFlowMod(datapath=dp, command=ofp.OFPFC_DELETE, table_id=ofp.OFPTT_ALL,
                                      cookie=DROP_COOKIE, cookie_mask=0xFFFFFFFFFFFFFFFF,
                                      out_port=ofp.OFPP_ANY, out_group=ofp.OFPG_ANY, match=parser.OFPMatch()))
        for r in self.block_rules:
            if r.get("dpid") not in (None, dp.id):
                continue
            fields = {}
            if "in_port" in r:
                fields["in_port"] = int(r["in_port"])
            if "eth_src" in r:
                fields["eth_src"] = r["eth_src"]
            if "ipv4_src" in r:
                fields.update(eth_type=ether_types.ETH_TYPE_IP, ipv4_src=r["ipv4_src"])
            if fields:
                self.add_flow(dp, DROP_PRIORITY, parser.OFPMatch(**fields), [],
                              hard=int(r.get("timeout", 0)), cookie=DROP_COOKIE)
