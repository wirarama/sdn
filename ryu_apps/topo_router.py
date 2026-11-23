"""topo_router.py - Ryu OF1.3: penemuan topologi (LLDP) + rute shortest-path (NetworkX)
+ monitoring flow/port stats + REST (topologi, stats, blokir port)."""
import json
import os
import time

import networkx as nx
from ryu.base import app_manager
from ryu.controller import ofp_event
from ryu.controller.handler import CONFIG_DISPATCHER, MAIN_DISPATCHER, DEAD_DISPATCHER, set_ev_cls
from ryu.lib import hub
from ryu.lib.packet import packet, ethernet, ether_types, arp, ipv4
from ryu.ofproto import ofproto_v1_3
from ryu.topology import event as topo_event
from ryu.topology.api import get_switch, get_link
from ryu.app.wsgi import ControllerBase, WSGIApplication, route
from webob import Response

OUT = os.environ.get("SDN_OUT", "/tmp")
INTERVAL = float(os.environ.get("SDN_STATS_INTERVAL", "2.0"))
INSTANCE = "topo_router_app"


class TopoRouter(app_manager.RyuApp):
    OFP_VERSIONS = [ofproto_v1_3.OFP_VERSION]
    _CONTEXTS = {"wsgi": WSGIApplication}

    def __init__(self, *args, **kwargs):
        super(TopoRouter, self).__init__(*args, **kwargs)
        self.dps = {}
        self.net = nx.DiGraph()          # switch-switch (port) + host
        self.host_port = {}              # mac -> (dpid, port)
        self.host_ip = {}                # ip -> mac
        self.flow_rows, self.port_rows = [], []
        self.req_ts = {}
        kwargs["wsgi"].register(RestApi, {INSTANCE: self})
        hub.spawn(self._monitor)

    def add_flow(self, dp, priority, match, actions, idle=0, hard=0, cookie=0):
        ofp, parser = dp.ofproto, dp.ofproto_parser
        inst = [parser.OFPInstructionActions(ofp.OFPIT_APPLY_ACTIONS, actions)] if actions else []
        dp.send_msg(parser.OFPFlowMod(datapath=dp, priority=priority, match=match,
                                      instructions=inst, idle_timeout=idle, hard_timeout=hard, cookie=cookie))

    @set_ev_cls(ofp_event.EventOFPSwitchFeatures, CONFIG_DISPATCHER)
    def features(self, ev):
        dp = ev.msg.datapath
        self.dps[dp.id] = dp
        parser, ofp = dp.ofproto_parser, dp.ofproto
        self.add_flow(dp, 0, parser.OFPMatch(),
                      [parser.OFPActionOutput(ofp.OFPP_CONTROLLER, ofp.OFPCML_NO_BUFFER)])

    @set_ev_cls(topo_event.EventSwitchEnter)
    def _topology(self, ev):
        hub.sleep(0.3)
        switches = [s.dp.id for s in get_switch(self)]
        self.net = nx.DiGraph()
        self.net.add_nodes_from(switches)
        for l in get_link(self):
            self.net.add_edge(l.src.dpid, l.dst.dpid, port=l.src.port_no)
        self.logger.info("topologi: %d switch, %d link", len(switches), self.net.number_of_edges())

    def _route(self, dp, in_port, pkt_eth, ip_src, ip_dst):
        """Pasang rute shortest-path dari switch sekarang menuju switch tempat host tujuan berada."""
        dst_mac = pkt_eth.dst
        if dst_mac not in self.host_port:
            return None
        dst_dpid, dst_port = self.host_port[dst_mac]
        if dp.id == dst_dpid:
            out = dst_port
        else:
            if not self.net.has_node(dp.id) or not self.net.has_node(dst_dpid) \
               or not nx.has_path(self.net, dp.id, dst_dpid):
                return None
            path = nx.shortest_path(self.net, dp.id, dst_dpid)
            out = self.net[dp.id][path[1]]["port"]
        parser = dp.ofproto_parser
        match = parser.OFPMatch(eth_type=ether_types.ETH_TYPE_IP, ipv4_src=ip_src, ipv4_dst=ip_dst)
        self.add_flow(dp, 10, match, [parser.OFPActionOutput(out)], idle=30)
        return out

    @set_ev_cls(ofp_event.EventOFPPacketIn, MAIN_DISPATCHER)
    def packet_in(self, ev):
        msg = ev.msg
        dp = msg.datapath
        ofp, parser = dp.ofproto, dp.ofproto_parser
        in_port = msg.match["in_port"]
        pkt = packet.Packet(msg.data)
        eth = pkt.get_protocol(ethernet.ethernet)
        if eth is None or eth.ethertype in (ether_types.ETH_TYPE_LLDP, ether_types.ETH_TYPE_IPV6):
            return
        # pelajari host dari port tepi (port yang bukan antar-switch)
        switch_ports = {d["port"] for _, _, d in self.net.out_edges(dp.id, data=True)} if self.net.has_node(dp.id) else set()
        if in_port not in switch_ports:
            self.host_port[eth.src] = (dp.id, in_port)
            a = pkt.get_protocol(arp.arp)
            if a:
                self.host_ip[a.src_ip] = eth.src
        out_port = None
        ip4 = pkt.get_protocol(ipv4.ipv4)
        if ip4 is not None:
            out_port = self._route(dp, in_port, eth, ip4.src, ip4.dst)
        if out_port is None:
            # ARP / tujuan belum dikenal: flood hanya ke port tepi (hindari badai pada loop)
            out_port = ofp.OFPP_FLOOD
        actions = [parser.OFPActionOutput(out_port)]
        data = msg.data if msg.buffer_id == ofp.OFP_NO_BUFFER else None
        dp.send_msg(parser.OFPPacketOut(datapath=dp, buffer_id=msg.buffer_id,
                                        in_port=in_port, actions=actions, data=data))

    # ---------------- monitoring ----------------
    def _monitor(self):
        while True:
            now = time.time()
            for dp in list(self.dps.values()):
                self.req_ts[dp.id] = now
                dp.send_msg(dp.ofproto_parser.OFPFlowStatsRequest(dp, table_id=0))
                dp.send_msg(dp.ofproto_parser.OFPPortStatsRequest(dp, 0, dp.ofproto.OFPP_ANY))
            self._flush()
            hub.sleep(INTERVAL)

    def _flush(self):
        if self.flow_rows:
            with open(os.path.join(OUT, "flow_stats.csv"), "a") as f:
                for r in self.flow_rows:
                    f.write(",".join(map(str, r)) + "\n")
            self.flow_rows = []
        if self.port_rows:
            with open(os.path.join(OUT, "port_stats.csv"), "a") as f:
                for r in self.port_rows:
                    f.write(",".join(map(str, r)) + "\n")
            self.port_rows = []

    @set_ev_cls(ofp_event.EventOFPFlowStatsReply, MAIN_DISPATCHER)
    def _flow_reply(self, ev):
        ts = round(self.req_ts.get(ev.msg.datapath.id, time.time()), 3)
        for st in ev.msg.body:
            if st.priority != 10:
                continue
            m = st.match
            self.flow_rows.append([ts, ev.msg.datapath.id, m.get("ipv4_src"), m.get("ipv4_dst"),
                                   st.packet_count, st.byte_count, round(st.duration_sec + st.duration_nsec / 1e9, 3)])

    @set_ev_cls(ofp_event.EventOFPPortStatsReply, MAIN_DISPATCHER)
    def _port_reply(self, ev):
        ts = round(self.req_ts.get(ev.msg.datapath.id, time.time()), 3)
        for st in ev.msg.body:
            if st.port_no <= ev.msg.datapath.ofproto.OFPP_MAX:
                self.port_rows.append([ts, ev.msg.datapath.id, st.port_no, st.rx_packets, st.tx_packets,
                                       st.rx_bytes, st.tx_bytes, st.rx_dropped, st.tx_dropped])

    @set_ev_cls(ofp_event.EventOFPStateChange, [MAIN_DISPATCHER, DEAD_DISPATCHER])
    def _state(self, ev):
        if ev.state == DEAD_DISPATCHER and ev.datapath.id in self.dps:
            del self.dps[ev.datapath.id]

    def block_port(self, dpid, in_port, seconds=0):
        dp = self.dps.get(int(dpid))
        if not dp:
            return False
        parser = dp.ofproto_parser
        self.add_flow(dp, 1000, parser.OFPMatch(in_port=int(in_port)), [], hard=int(seconds), cookie=0xDEAD)
        return True

    def topo_dict(self):
        return {"switches": sorted(self.net.nodes()),
                "links": [{"src": u, "dst": v, "port": d["port"]} for u, v, d in self.net.edges(data=True)],
                "hosts": {ip: {"mac": mac, "dpid": self.host_port.get(mac, (None, None))[0],
                               "port": self.host_port.get(mac, (None, None))[1]}
                          for ip, mac in self.host_ip.items()}}


class RestApi(ControllerBase):
    def __init__(self, req, link, data, **config):
        super(RestApi, self).__init__(req, link, data, **config)
        self.app = data[INSTANCE]

    @route("sdn", "/sdn/topology", methods=["GET"])
    def topology(self, req, **kw):
        return Response(content_type="application/json", body=json.dumps(self.app.topo_dict()))

    @route("sdn", "/sdn/block", methods=["POST"])
    def block(self, req, **kw):
        body = json.loads(req.body or b"{}")
        ok = self.app.block_port(body["dpid"], body["in_port"], body.get("seconds", 0))
        return Response(content_type="application/json", body=json.dumps({"blocked": ok}))
