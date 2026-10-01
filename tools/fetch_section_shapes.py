#!/usr/bin/env python3
"""Build openly licensed city-road display spans. No Apple map data is retained."""
import argparse
import datetime as dt
import json
import re
import xml.etree.ElementTree as ET
import build_tw_traffic_db as traffic
from fetch_sources import download

AREAS={"環河路":("huanhe","121.526,24.960,121.539,24.974"),
       "壽山路":("shoushan","121.395,25.037,121.410,25.046")}

def build(refresh=False):
    graphs={};sources=[]
    for name,(slug,bbox) in AREAS.items():
        path=traffic.CACHE/f"osm_{slug}.xml"
        url=f"https://api.openstreetmap.org/api/0.6/map?bbox={bbox}"
        if refresh:download(url,path)
        root=ET.parse(path).getroot()
        nodes={n.attrib["id"]:(float(n.attrib["lon"]),float(n.attrib["lat"])) for n in root.findall("node")}
        builder=traffic.Builder();ways=[]
        for way in root.findall("way"):
            tags={t.attrib["k"]:t.attrib["v"] for t in way.findall("tag")}
            if name not in tags.get("name","") or tags.get("highway") not in {"trunk","trunk_link","primary","secondary","tertiary","unclassified","residential"}:continue
            points=[nodes[n.attrib["ref"]] for n in way.findall("nd") if n.attrib["ref"] in nodes]
            if len(points)<2:continue
            builder.by_ref[name].append(dict(points=points,oneway=tags.get("oneway","")))
            ways.append(way.attrib["id"])
        graphs[name]=builder
        sources.append(dict(name=name,url=url,osm_way_ids=ways,downloaded_at=dt.datetime.fromtimestamp(path.stat().st_mtime,dt.timezone.utc).isoformat()))
    rows=traffic.rows_from_bytes((traffic.CACHE/"126156_0.bin").read_bytes());result=[]
    for row in rows:
        road=traffic.get(row,"location")
        name=next((n for n in AREAS if n in road),None)
        if name is None:continue
        values=[traffic.numbers(traffic.get(row,n)) for n in ("start longitude","start latitude","end longitude","end latitude")]
        lengths=[float(n) for n in re.findall(r"([\d.]+)公尺",traffic.get(row,"length"))]
        for index,(slon,slat,elon,elat) in enumerate(zip(*values)):
            expected=lengths[index]
            path,reason=graphs[name].corridor((slon,slat),(elon,elat),name)
            actual=sum(traffic.distance(a,b) for a,b in zip(path,path[1:])) if path else 0
            if not path or abs(actual-expected)>max(100,expected*.12):
                print("REJECT",road,index,reason,actual,"police",expected);continue
            identity=traffic.uid("126156",road,index)
            result.append(dict(id=identity,name=road,start_lon=slon,start_lat=slat,end_lon=elon,end_lat=elat,length_m=expected,
                points=path,geometry_source="osm_road_geometry_display_only",fetched_at=next(s["downloaded_at"] for s in sources if s["name"]==name),
                license="ODbL-1.0",attribution="OpenStreetMap contributors",license_url="https://www.openstreetmap.org/copyright"))
            print("DISPLAY ONLY",identity,"OSM",round(actual,1),"m; police",expected,"m")
    traffic.OUT.mkdir(exist_ok=True)
    (traffic.CACHE/"osm_section_display_shapes.json").write_text(json.dumps(result,ensure_ascii=False,indent=2))
    (traffic.ROOT/"Speedlimit/Resources/osm_section_display_shapes.json").write_text(json.dumps(dict(license="ODbL-1.0",attribution="OpenStreetMap contributors",license_url="https://www.openstreetmap.org/copyright",sources=sources,derived_spans=result),ensure_ascii=False,indent=2))

if __name__=="__main__":
    parser=argparse.ArgumentParser();parser.add_argument("--refresh",action="store_true")
    build(parser.parse_args().refresh)
