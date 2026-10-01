#!/usr/bin/env python3
"""Offline-first Taiwan traffic snapshot. No geocoder, inferred cameras, or API keys."""
import argparse
import collections
import contextlib
import csv
import datetime as dt
import hashlib
import heapq
import io
import json
import math
import pathlib
import re
import shutil
import sqlite3
import subprocess
import tempfile
import urllib.parse
import xml.etree.ElementTree as ET
import zipfile
from speed_references import load_catalogue, write_catalogue, reference_manifest

ROOT = pathlib.Path(__file__).resolve().parents[1]
CACHE = ROOT / "tools/cache"
OUT = ROOT / "tools/out"
DB = ROOT / "Speedlimit/Resources/tw_traffic.db"
NOW = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
PUBLIC = {
    "freeway_sections": "https://tisvcloud.freeway.gov.tw/history/motc20/Section.xml",
    "freeway_shapes": "https://tisvcloud.freeway.gov.tw/history/motc20/SectionShape.xml",
    "thb_sections": "https://thbapp.thb.gov.tw/opendata/section/sectioninfo/SectionList.xml",
    "thb_shapes": "https://thbapp.thb.gov.tw/opendata/section/sectionshapeinfo/SectionShapeList.xml",
    "thb_cctv": "https://cctv-maintain.thb.gov.tw/opendataCCTVs.xml",
    "freeway_cctv": "https://tisvcloud.freeway.gov.tw/history/motc20/CCTV.xml",
}
CAMERA_IDS = {"7320", "13940", "130111", "173211", "146681", "156415", "109336", "178119"}
SECTION_IDS = {"126156", "178161", "144579", "176559", "172725", "172950", "178412", "178120", "171261", "144355"}
REFERENCE_IDS = {"105021", "169929", "40476", "121671"}


def decode(data):
    for encoding in ("utf-8-sig", "cp950", "big5"):
        try:
            return data.decode(encoding).lstrip("\ufeff")
        except UnicodeError:
            pass
    raise ValueError("Unsupported text encoding")


def rows_from_bytes(data):
    if data.startswith(b"PK"):
        result = []
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            if "xl/workbook.xml" in archive.namelist():
                shared=[]
                if "xl/sharedStrings.xml" in archive.namelist():
                    strings=ET.fromstring(archive.read("xl/sharedStrings.xml"))
                    shared=["".join(n.text or "" for n in s.iter() if n.tag.endswith("}t")) for s in strings]
                for name in sorted(archive.namelist()):
                    if not re.fullmatch(r"xl/worksheets/sheet\d+\.xml",name):continue
                    sheet=ET.fromstring(archive.read(name));table=[]
                    for row in sheet.iter():
                        if not row.tag.endswith("}row"):continue
                        values={}
                        for cell in row:
                            ref=cell.attrib.get("r","A1");letters=re.match(r"[A-Z]+",ref)
                            index=0
                            for letter in (letters[0] if letters else "A"):index=index*26+ord(letter)-64
                            value=child(cell,"v")
                            if cell.attrib.get("t")=="s":value=shared[int(value)] if value else ""
                            elif cell.attrib.get("t")=="inlineStr":value="".join(n.text or "" for n in cell.iter() if n.tag.endswith("}t"))
                            values[index-1]=value
                        if values:table.append([values.get(i,"") for i in range(max(values)+1)])
                    if table:
                        headers=table[0]
                        result.extend({header:row[i] if i<len(row) else "" for i,header in enumerate(headers) if header} for row in table[1:])
                return result
            for name in sorted(archive.namelist()):
                if name.lower().endswith(".csv") and "manifest" not in name.lower():
                    result.extend(rows_from_bytes(archive.read(name)))
        return result
    text = decode(data)
    if text.lstrip().startswith("<"):
        raise ValueError("HTML/XML response instead of a camera CSV/JSON (blocked or unsupported)")
    if text.lstrip().startswith(("[", "{")):
        value = json.loads(text)
        if isinstance(value, dict):
            value = value.get("data", value.get("result", []))
        if not isinstance(value, list):
            raise ValueError("JSON has no record array")
        return [{str(k).strip(): str(v or "").strip() for k, v in r.items()} for r in value if isinstance(r, dict)]
    rows=[{str(k or "").strip().lstrip("\ufeff"): (v or "").strip() for k, v in r.items() if k is not None}
          for r in csv.DictReader(io.StringIO(text))]
    return [r for r in rows if get(r,"Latitude","緯度","座標緯度") not in ("緯度","座標緯度")]


def get(row, *names):
    lowered = {k.lower().replace("_", " "): v for k, v in row.items()}
    for name in names:
        value = lowered.get(name.lower().replace("_", " "), "")
        if value:
            return value
    return ""


def validate_download(data):
    rows = rows_from_bytes(data)
    if not rows:
        raise ValueError("Downloaded resource has no records; retain previous snapshot")
    return rows


def numbers(text):
    return [float(x) for x in re.findall(r"[-+]?\d+(?:\.\d+)?", str(text))]


def speed(text):
    values = set(int(n) for n in numbers(text) if 10 <= n <= 130)
    return next(iter(values)) if len(values) == 1 else None


def coordinate(lat, lon):
    try:
        lat, lon = float(lat), float(lon)
        return (lon, lat) if 21.8 <= lat <= 26.5 and 118 <= lon <= 122.5 else None
    except (TypeError, ValueError):
        return None


def road_ref(text):
    text = text.replace("臺", "台")
    match = re.search(r"國道\s*([一二三四五六七八九十\d]+)(甲|乙)?", text)
    if match:
        num = {"一": "1", "二": "2", "三": "3", "四": "4", "五": "5", "六": "6", "七": "7", "八": "8", "九": "9", "十": "10"}.get(match[1], match[1])
        return "國道" + num + (match[2] or "")
    match = re.search(r"台\s*(\d+)(甲|乙|丙|丁)?", text)
    return "台" + match[1] + (match[2] or "") if match else ""


def direction_bearings(text):
    if text in ("N", "E", "S", "W"):
        return [{"N": 0, "E": 90, "S": 180, "W": 270}[text]]
    if any(w in text for w in ("雙向", "双向")):
        if "南北" in text or "北南" in text:
            return [0, 180]
        if "東西" in text or "西東" in text:
            return [90, 270]
        return []
    target = re.search(r"(?:向|往)(東北|東南|西北|西南|北|東|南|西)", text)
    if target:
        return [{"北": 0, "東北": 45, "東": 90, "東南": 135, "南": 180, "西南": 225, "西": 270, "西北": 315}[target[1]]]
    if "北上" in text: return [0]
    if "南下" in text: return [180]
    return []


def distance(a, b):
    x = (a[0] - b[0]) * 111320 * math.cos(math.radians((a[1] + b[1]) / 2))
    y = (a[1] - b[1]) * 111320
    return math.hypot(x, y)


def projection(p, points):
    best = (float("inf"), 0, 0, points[0])
    cumulative = 0
    scale = math.cos(math.radians(p[1]))
    for i, (a, b) in enumerate(zip(points, points[1:])):
        vx, vy = (b[0]-a[0])*scale, b[1]-a[1]
        wx, wy = (p[0]-a[0])*scale, p[1]-a[1]
        t = max(0, min(1, (wx*vx+wy*vy) / (vx*vx+vy*vy))) if vx*vx+vy*vy else 0
        q = (a[0]+t*(b[0]-a[0]), a[1]+t*(b[1]-a[1]))
        d = distance(p, q)
        length = distance(a, b)
        if d < best[0]: best = (d, cumulative + t*length, i, q)
        cumulative += length
    return best


def simplify(points, tolerance=6):
    if len(points) <= 2: return points
    distances = [projection(p, [points[0], points[-1]])[0] for p in points[1:-1]]
    maximum = max(distances, default=0)
    if maximum <= tolerance: return [points[0], points[-1]]
    index = distances.index(maximum)+1
    return simplify(points[:index+1], tolerance)[:-1]+simplify(points[index:], tolerance)


def parse_wkt(wkt):
    if not wkt.startswith("LINESTRING"): return []
    return [tuple(map(float, pair.split())) for pair in wkt[wkt.index("(")+1:wkt.rindex(")")].split(",")]


def clip_path(points, start_fraction, end_fraction):
    lengths=[distance(a,b) for a,b in zip(points,points[1:])]
    total=sum(lengths)
    low,high=sorted((start_fraction*total,end_fraction*total))
    result=[];along=0
    for a,b,length in zip(points,points[1:],lengths):
        if length and along+length>=low and along<=high:
            for target in (max(low,along),min(high,along+length)):
                t=max(0,min(1,(target-along)/length))
                q=(a[0]+t*(b[0]-a[0]),a[1]+t*(b[1]-a[1]))
                if not result or distance(result[-1],q)>.01:result.append(q)
        along+=length
    return result if start_fraction<=end_fraction else list(reversed(result))


def published_km_range(text):
    match=re.search(r"(\d+(?:\.\d+)?)\s*(?:[kK]|公里)?\s*至\s*(\d+(?:\.\d+)?)\s*(?:[kK]|公里)",text)
    return tuple(map(float,match.groups())) if match else None


def child(element, name):
    for node in element.iter():
        if node.tag.split("}")[-1] == name: return node.text or ""
    return ""


def km(text):
    n = numbers(text)
    return n[0]+(n[1]/1000 if len(n)>1 else 0) if n else None


def uid(*parts):
    return hashlib.sha256("|".join(map(str, parts)).encode()).hexdigest()[:24]


class Builder:
    def __init__(self):
        self.roads, self.cameras, self.zones, self.manifest, self.issues = [], [], [], [], []
        self.by_ref = collections.defaultdict(list)
        self.graphs = {}
        self.stats = collections.Counter()
        self.inventory = {}
        self.refresh_failures = {}
        state=CACHE/"refresh_state.json"
        if state.exists():self.refresh_failures=json.loads(state.read_text()).get("failures",{})
        self.providers={}
        if (CACHE/"catalog.csv").exists():
            with open(CACHE/"catalog.csv",encoding="utf-8-sig") as catalog:
                for row in csv.DictReader(catalog):
                    if row.get("資料集識別碼") in CAMERA_IDS|SECTION_IDS|REFERENCE_IDS:
                        self.providers[row["資料集識別碼"]]=row.get("提供機關","")

    def load_roads(self):
        for prefix, authority in (("freeway", "交通部高速公路局"), ("thb", "交通部公路局")):
            shapes = ET.parse(CACHE / f"{prefix}_shapes.xml").getroot()
            geometries = {child(r, "SectionID"): parse_wkt(child(r, "Geometry")) for r in shapes.iter() if r.tag.endswith("}SectionShape")}
            metadata = ET.parse(CACHE / f"{prefix}_sections.xml").getroot()
            count = 0
            seen_ids = set()
            for row in metadata.iter():
                if not row.tag.endswith("}Section"): continue
                points = geometries.get(child(row, "SectionID"), [])
                if len(points) < 2: continue
                identity = child(row, "SectionID")
                if identity in seen_ids: continue
                seen_ids.add(identity)
                points = simplify(points)
                name = child(row, "RoadName")
                record = dict(id=prefix+":"+child(row, "SectionID"), road_name=name,
                              road_ref=road_ref(name), direction=child(row, "RoadDirection"),
                              speed_limit_kph=speed(child(row, "SpeedLimit")), points=points,
                              start_km=km(child(row, "StartKM")), end_km=km(child(row, "EndKM")),
                              road_level_hint="unknown", source_type="official", source_dataset_id=prefix+"_sections",
                              source_updated_at=child(metadata, "UpdateTime"))
                self.roads.append(record)
                self.by_ref[record["road_ref"]].append(record)
                count += 1
            self.manifest.append(dict(dataset_id=prefix+"_sections", dataset_name=prefix+" official road geometry", authority=authority,
                metadata_updated_at=child(metadata,"UpdateTime"),
                fetch_time_utc=dt.datetime.fromtimestamp((CACHE/f"{prefix}_sections.xml").stat().st_mtime,dt.timezone.utc).isoformat(timespec="seconds"),
                record_count=count, status="stale_cached_snapshot" if prefix+"_sections" in self.refresh_failures or prefix+"_shapes" in self.refresh_failures else "parsed", url=PUBLIC[prefix+"_sections"]))

    def nearest_road(self, p, ref, reported_km=None):
        candidates = []
        for road in self.by_ref.get(ref, []):
            if reported_km is not None and road["start_km"] is not None and road["end_km"] is not None:
                a,b = sorted((road["start_km"], road["end_km"]))
                if not a-.3 <= reported_km <= b+.3: continue
            pts=road["points"]
            if p[0] < min(x[0] for x in pts)-.002 or p[0]>max(x[0] for x in pts)+.002 or p[1]<min(x[1] for x in pts)-.002 or p[1]>max(x[1] for x in pts)+.002: continue
            d = projection(p,pts)[0]
            candidates.append((d,road))
        return min(candidates,key=lambda c:c[0]) if candidates else (float("inf"), None)

    def corridor(self, start, end, ref):
        # Join only surveyed geometry on the named road. Endpoint/ramp uncertainty is retained.
        if ref not in self.graphs:
            graph, coords = collections.defaultdict(dict), {}
            for road in self.by_ref.get(ref, []):
                points=road["points"]
                for a,b in zip(points,points[1:]):
                    ka,kb=tuple(round(v,5) for v in a),tuple(round(v,5) for v in b)
                    coords[ka],coords[kb]=a,b
                    if ka != kb:
                        weight=distance(a,b);oneway=road.get("oneway","")
                        if oneway!="-1":graph[ka][kb]=weight
                        if oneway not in ("yes","true","1"):graph[kb][ka]=weight
            # Adjacent official sections can differ slightly at their shared endpoints.
            grid=collections.defaultdict(list)
            endpoints=set()
            for road in self.by_ref.get(ref,[]):
                endpoints.update(tuple(round(v,5) for v in p) for p in (road["points"][0],road["points"][-1]))
            for key in endpoints:
                cell=(int(key[0]*4000),int(key[1]*4000))
                for dx in (-1,0,1):
                    for dy in (-1,0,1):
                        for other in grid[(cell[0]+dx,cell[1]+dy)]:
                            d=distance(key,other)
                            if d<12: graph[key][other]=graph[other][key]=d
                grid[cell].append(key)
            self.graphs[ref]=(graph,coords)
        base,coords=self.graphs[ref]
        if not coords:return None,"No official road geometry"
        graph={k:dict(v) for k,v in base.items()}
        coords=dict(coords)
        for token,p in (("START",start),("END",end)):
            nearest=[]
            for road in self.by_ref[ref]:
                d,_,i,q=projection(p,road["points"])
                nearest.append((d,road,i,q))
            d,road,i,q=min(nearest,key=lambda r:r[0])
            if d>100:return None,f"Endpoint is {d:.0f}m from named road"
            coords[token]=q
            graph[token]={}
            oneway=road.get("oneway","")
            for index,p2 in enumerate(road["points"][i:i+2]):
                k=tuple(round(v,5) for v in p2)
                forward=oneway in ("yes","true","1");reverse=oneway=="-1"
                if token=="START" and (not (forward or reverse) or index==(0 if reverse else 1)):
                    graph[token][k]=distance(q,p2)
                if token=="END" and (not (forward or reverse) or index==(1 if reverse else 0)):
                    graph.setdefault(k,{})[token]=distance(q,p2)
        queue=[(0,0,"START")];cost={"START":0};previous={};serial=0
        while queue:
            value,_,node=heapq.heappop(queue)
            if node=="END":break
            if value!=cost[node]:continue
            if value>60000:continue
            for target,weight in graph.get(node,{}).items():
                if value+weight<cost.get(target,float("inf")):
                    cost[target]=value+weight;previous[target]=node;serial+=1
                    heapq.heappush(queue,(value+weight,serial,target))
        if "END" not in cost:return None,"Official shapes are not connected at both endpoints"
        path=[];node="END"
        while node in previous:path.append(coords[node]);node=previous[node]
        path.append(coords["START"]);path.reverse()
        return path,None

    def add_camera(self,row,dataset_id,is_section=False):
        road=get(row,"Address","設置地址","設置地點(路口或路段)","location","設置地點","設置地點_範圍","地點","設置路段")
        if dataset_id=="130111":
            principal=get(row,"設置路段");junction=get(row,"設置地點")
            road=principal+(" · "+junction if junction and junction!=principal else "")
        detail=get(row,"功能","取締項目","取締項目(以\"、\"分隔)","item","種類","科技執法種類","型式")
        is_section=is_section or "區間" in detail
        lat=get(row,"Latitude","緯度","座標緯度")
        lon=get(row,"Longitude","經度","座標經度")
        p=coordinate(lat,lon)
        if not p:
            if lat or lon:self.issues.append(dict(dataset_id=dataset_id,road=road,reason="Invalid WGS84 coordinates; excluded, not silently swapped",lat=lat,lon=lon))
            return
        direction=get(row,"direct","拍攝方向","方向")
        bearings=direction_bearings(direction)
        category="section_speed" if is_section else ("multi_violation" if ("闖紅燈" in detail and any(s in detail for s in ("測速","超速"))) or "淨空" in detail or "禮讓" in detail else "red_light" if "闖紅燈" in detail else "speed")
        ref=road_ref(road)
        km_match=re.search(r"(?:向|上|下|線|號)\s*(\d+(?:\.\d+)?)\s*(?:公?里|公里|[kK])",road)
        reported=float(km_match[1]) if km_match else None
        snap,matched=self.nearest_road(p,ref,reported)
        confidence="A" if bearings else "B"
        reason="Official explicit coordinate and direction; road level not surveyed"
        if ref and self.by_ref.get(ref):
            if snap>100:
                confidence="C";reason="Coordinate conflicts with named road/kilometre; excluded from alert set"
                self.issues.append(dict(dataset_id=dataset_id,road=road,reason=reason,snap_meters=round(snap) if math.isfinite(snap) else None,lat=p[1],lon=p[0]))
            elif bearings:reason=f"Explicit official coordinate; named-road check {snap:.0f}m"
        if is_section:confidence="B";reason="Only one section endpoint published; no invented exit/corridor"
        if ref and snap>100 and self.by_ref.get(ref):
            # Misplaced official coordinates must not remain displayed as credible map pins.
            return
        manifest=next((m for m in self.manifest if m["dataset_id"]==dataset_id),{})
        self.cameras.append(dict(id=uid(dataset_id,road,p,category,direction),lat=p[1],lon=p[0],camera_category=category,
            enforcement_type=detail or "測速",road_name=road,road_ref=ref,direction=direction,
            speed_limit_kph=speed(get(row,"limit","速限","速限-速度限制","速限長度")),
            city=get(row,"CityName","cityname","縣市","設置縣市"),district=get(row,"RegionName","regionname","行政區","設置市區鄉鎮","轄區"),
            source_dataset_id=dataset_id,source_authority=manifest.get("authority",""),source_updated_at=manifest.get("metadata_updated_at",""),
            is_live_cctv=0,cctv_endpoint=None,position_source="explicit_official_coordinate",location_confidence=confidence,
            is_alert_enabled=int(confidence=="A"),road_level_hint="unknown",bearings_json=json.dumps(bearings),quality_note=reason,section_id=None))

    def add_ntpc_sections(self,rows):
        cache=CACHE/"osm_section_display_shapes.json"
        display_shapes={r["id"]:r for r in json.loads(cache.read_text())} if cache.exists() else {}
        for row in rows:
            values=[numbers(get(row,name)) for name in ("start longitude","start latitude","end longitude","end latitude")]
            if len({len(v) for v in values})!=1 or not values[0]:
                self.issues.append(dict(dataset_id="126156",road=get(row,"location"),reason="Unequal endpoint arrays"));continue
            lengths=[float(n) for n in re.findall(r"([\d.]+)公尺", get(row,"length"))]
            for index,(slon,slat,elon,elat) in enumerate(zip(*values)):
                start,end=coordinate(slat,slon),coordinate(elat,elon)
                if not start or not end:continue
                road=get(row,"location");ref=road_ref(road)
                path,reason=self.corridor(start,end,ref)
                actual=sum(distance(a,b) for a,b in zip(path,path[1:])) if path else 0
                expected=lengths[index] if index<len(lengths) else None
                if path and expected and abs(actual-expected)>max(150,expected*.12):
                    reason=f"Surveyed path length {actual:.0f}m conflicts with police length {expected:.0f}m"
                    path=None
                confidence="A" if path and expected else "B"
                section_id=uid("126156",road,index)
                if path is None and section_id in display_shapes:
                    shape=display_shapes[section_id]
                    candidate=shape.get("points",[])
                    # Never accept a cached route for changed police endpoints or a detour.
                    if (shape.get("geometry_source")=="osm_road_geometry_display_only" and shape.get("name")==road and expected and shape.get("length_m")==expected and len(candidate)>=2 and
                        distance((shape["start_lon"],shape["start_lat"]),start)<.1 and
                        distance((shape["end_lon"],shape["end_lat"]),end)<.1 and
                        distance(candidate[0],start)<80 and distance(candidate[-1],end)<80 and
                        abs(sum(distance(a,b) for a,b in zip(candidate,candidate[1:]))-expected)<=max(100,expected*.12)):
                        path=candidate
                        reason="Official endpoint pair; OpenStreetMap-derived display geometry, not surveyed; no alerts"
                direction=(get(row,"direct")+f" · 路段 {index+1}")
                if path:
                    self.zones.append(dict(id=section_id,road_name=road,road_ref=ref,direction=direction,
                        speed_limit_kph=speed(get(row,"limit")),points=path,source_dataset_id="126156",location_confidence=confidence,
                        is_alert_enabled=int(confidence=="A"),length_m=expected or actual,start_lat=slat,start_lon=slon,end_lat=elat,end_lon=elon,
                        road_level_hint="unknown",quality_note=reason or "Both police endpoints + official connected road geometry + length check; elevation unknown"))
                else:self.issues.append(dict(dataset_id="126156",road=road,branch=index,reason=reason))
                for endpoint,p in (("entry",start),("exit",end)):
                    source=next(m for m in self.manifest if m["dataset_id"]=="126156")
                    bearing=[]
                    if path:
                        a,b=(path[0],path[min(2,len(path)-1)]) if endpoint=="entry" else (path[max(0,len(path)-3)],path[-1])
                        bearing=[math.degrees(math.atan2((b[0]-a[0])*math.cos(math.radians(a[1])), b[1]-a[1]))%360]
                    self.cameras.append(dict(id=uid(section_id,endpoint),lat=p[1],lon=p[0],camera_category="section_speed",
                        enforcement_type="區間測速 · "+("起點" if endpoint=="entry" else "終點"),road_name=road,road_ref=ref,direction=direction,
                        speed_limit_kph=speed(get(row,"limit")),city=get(row,"cityname"),district=get(row,"regionname"),
                        source_dataset_id="126156",source_authority=source["authority"],source_updated_at=source["metadata_updated_at"],
                        is_live_cctv=0,cctv_endpoint=None,position_source="explicit_official_coordinate",location_confidence=confidence,
                        is_alert_enabled=int(confidence=="A" and endpoint=="entry"),road_level_hint="unknown",bearings_json=json.dumps(bearing),
                        quality_note=reason or "Official start/end coordinates; connected surveyed corridor",section_id=section_id))

        if display_shapes:
            self.manifest.append(dict(dataset_id="section_display_shapes",dataset_name="OpenStreetMap-derived city section display geometry",
                authority="OpenStreetMap contributors; ODbL; police endpoint and length checks",metadata_updated_at=max(r["fetched_at"] for r in display_shapes.values()),
                fetch_time_utc=max(r["fetched_at"] for r in display_shapes.values()),record_count=sum(z["location_confidence"]=="B" for z in self.zones),
                status="display_only_not_surveyed",url="https://www.openstreetmap.org/copyright"))

    def kilometer_corridor(self,ref,start,end,strict_length=True):
        if start==end:return None,"Zero-length kilometre range"
        sign=1 if end>start else -1
        candidates=[]
        for road in self.by_ref.get(ref,[]):
            a,b=road["start_km"],road["end_km"]
            if a is None or b is None or (b-a)*sign<=0:continue
            lo,hi=sorted((a,b));low,high=sorted((start,end))
            if hi<=low or lo>=high:continue
            first=max(lo,low) if sign>0 else min(hi,high)
            last=min(hi,high) if sign>0 else max(lo,low)
            points=clip_path(road["points"],(first-a)/(b-a),(last-a)/(b-a))
            if len(points)>=2:candidates.append((first,last,points))
        position=start;path=[]
        while (end-position)*sign>.00001:
            available=[r for r in candidates if abs(r[0]-position)<.002 and (r[1]-position)*sign>0]
            if not available:return None,"Official kilometre geometry has a gap"
            chosen=min(available,key=lambda r:distance(path[-1],r[2][0]) if path else 0)
            if path and distance(path[-1],chosen[2][0])>25:return None,"Official kilometre shapes disconnected"
            path.extend(chosen[2]);position=chosen[1]
        actual=sum(distance(a,b) for a,b in zip(path,path[1:]));expected=abs(end-start)*1000
        if strict_length and abs(actual-expected)>max(250,expected*.10):return None,"Kilometre geometry length conflict"
        return path,None

    def add_published_range_displays(self):
        for camera in self.cameras:
            if camera["camera_category"]!="section_speed" or camera["section_id"]:continue
            extent=published_km_range(camera["road_name"])
            if not extent:continue
            path,reason=self.kilometer_corridor(camera["road_ref"],*extent)
            if path and projection((camera["lon"],camera["lat"]),path)[0]>120:
                path=None;reason="Published camera coordinate conflicts with kilometre range"
            if path is None and reason in ("Published camera coordinate conflicts with kilometre range","Kilometre geometry length conflict"):
                # Kilometre labels on coarse road shapes are not surveyed camera boundaries.
                # Anchor an explicitly labelled display estimate at the published coordinate.
                a,b=extent;sign=1 if b>a else -1
                broad,_=self.kilometer_corridor(camera["road_ref"],a-sign*1.2,b+sign*1.2,strict_length=False)
                rough,_=self.kilometer_corridor(camera["road_ref"],a,b,strict_length=False)
                if broad and rough:
                    point=(camera["lon"],camera["lat"])
                    snap,along,_,_=projection(point,broad)
                    start=projection(rough[0],broad)[1];end=projection(rough[-1],broad)[1]
                    near_start=abs(along-start)<abs(along-end)
                    # A middle-of-zone/remote coordinate cannot identify either boundary.
                    if snap<=50 and min(abs(along-start),abs(along-end))<=min(750,abs(b-a)*250):
                        length=abs(b-a)*1000
                        match=re.search(r"(?:偵測長度|執法距離)\s*([\d,]+(?:\.\d+)?)\s*公尺",camera["enforcement_type"])
                        if match:length=float(match[1].replace(",",""))
                        low,high=(along,along+length) if near_start else (along-length,along)
                        total=sum(distance(x,y) for x,y in zip(broad,broad[1:]))
                        if low>=0 and high<=total:path=clip_path(broad,low/total,high/total)
            if not path:
                self.issues.append(dict(dataset_id=camera["source_dataset_id"],road=camera["road_name"],reason=reason));continue
            section_id=uid("published_km_display",camera["id"])
            note="Published police kilometre range + official road geometry; approximate boundaries, display only; no alerts"
            camera.update(section_id=section_id,quality_note=note)
            self.zones.append(dict(id=section_id,road_name=camera["road_name"],road_ref=camera["road_ref"],direction=camera["direction"],
                speed_limit_kph=camera["speed_limit_kph"],points=path,source_dataset_id=camera["source_dataset_id"],location_confidence="C",
                is_alert_enabled=0,length_m=sum(distance(a,b) for a,b in zip(path,path[1:])),start_lat=path[0][1],start_lon=path[0][0],
                end_lat=path[-1][1],end_lon=path[-1][0],road_level_hint="unknown",quality_note=note))
            self.stats["published_range_display_corridors"]+=1

    def load_datasets(self):
        for dataset_id in sorted(CAMERA_IDS|SECTION_IDS|REFERENCE_IDS):
            meta_file=CACHE/f"{dataset_id}_metadata.json"
            if not meta_file.exists():
                self.manifest.append(dict(dataset_id=dataset_id,dataset_name=dataset_id,authority="",metadata_updated_at="",fetch_time_utc=NOW,record_count=0,status="unreachable",url=f"https://data.gov.tw/dataset/{dataset_id}"));continue
            raw=json.loads(meta_file.read_text())
            meta=raw.get("result",raw)
            provider=self.providers.get(dataset_id) or meta.get("dataProvider",meta.get("publisher",""))
            if isinstance(provider,dict):provider=provider.get("name",str(provider))
            manifest=dict(dataset_id=dataset_id,dataset_name=meta["title"],authority=str(provider),metadata_updated_at=meta.get("modifiedDate",""),fetch_time_utc=NOW,record_count=0,status="unreachable",url=f"https://data.gov.tw/dataset/{dataset_id}")
            self.manifest.append(manifest)
            rows=[];seen=set();resources=[];fetch_times=[]
            for index,resource in enumerate(meta.get("distribution",[])):
                file=CACHE/f"{dataset_id}_{index}.bin"
                inventory=dict(url=resource.get("resourceDownloadUrl",""),format=resource.get("resourceFormat",""),status="unreachable",bytes=0)
                resources.append(inventory)
                if not file.exists():
                    if resource.get("resourceFormat","").upper() in ("PDF","ODS"):inventory["status"]="manual_review"
                    continue
                try:
                    records=rows_from_bytes(file.read_bytes())
                    fetched=dt.datetime.fromtimestamp(file.stat().st_mtime,dt.timezone.utc).isoformat(timespec="seconds")
                    inventory.update(status="parsed",record_count=len(records),bytes=file.stat().st_size,sha256=hashlib.sha256(file.read_bytes()).hexdigest(),fetch_time_utc=fetched)
                    fetch_times.append(fetched)
                    for r in records:
                        key=json.dumps(r,sort_keys=True,ensure_ascii=False)
                        if key not in seen:seen.add(key);rows.append(r)
                except Exception as e:
                    self.issues.append(dict(dataset_id=dataset_id,resource=index,reason=str(e)))
                    manifest["status"]="blocked_or_unsupported"
                    inventory.update(status="blocked_or_unsupported",reason=str(e),bytes=file.stat().st_size)
            self.inventory[dataset_id]=resources
            if fetch_times:manifest["fetch_time_utc"]=max(fetch_times)
            if not rows:continue
            if dataset_id in REFERENCE_IDS:
                manifest.update(status="reference_only_no_geocodable_speed",record_count=len(rows));continue
            before=len(self.cameras)
            if dataset_id=="126156":self.add_ntpc_sections(rows)
            else:
                for row in rows:self.add_camera(row,dataset_id,dataset_id in SECTION_IDS)
            manifest.update(record_count=len(self.cameras)-before,status="parsed" if len(self.cameras)>before else "no_usable_locations")
            if dataset_id in self.refresh_failures and manifest["record_count"]:
                manifest["status"]="stale_cached_snapshot"
                self.issues.append(dict(dataset_id=dataset_id,reason="Refresh failed; previous cached records retained",errors=self.refresh_failures[dataset_id]))

    def load_cctv(self):
        for prefix,authority in (("freeway","交通部高速公路局"),("thb","交通部公路局")):
            root=ET.parse(CACHE/f"{prefix}_cctv.xml").getroot();count=0
            for row in root.iter():
                if not row.tag.endswith("}CCTV"):continue
                p=coordinate(child(row,"PositionLat"),child(row,"PositionLon"))
                endpoint=child(row,"VideoImageURL") or child(row,"VideoStreamURL")
                stream=child(row,"VideoStreamURL")
                if not p or not endpoint.startswith("https://"):continue
                name=child(row,"SurveillanceDescription") or child(row,"CCTVID")
                self.cameras.append(dict(id=prefix+":"+child(row,"CCTVID"),lat=p[1],lon=p[0],camera_category="cctv",enforcement_type="Traffic observation, not an enforcement camera",
                    road_name=name,road_ref=road_ref(name),direction="",speed_limit_kph=None,city="",district="",source_dataset_id=prefix+"_cctv",source_authority=authority,
                    source_updated_at=child(root,"UpdateTime"),is_live_cctv=1,cctv_endpoint=endpoint,cctv_stream_endpoint=stream if stream.startswith("https://") else None,position_source="explicit_official_coordinate",location_confidence="B",
                    is_alert_enabled=0,road_level_hint="unknown",bearings_json="[]",quality_note="Public official CCTV; video depends on source availability, new connections and snapshots at least 60 seconds apart",section_id=None));count+=1
            self.manifest.append(dict(dataset_id=prefix+"_cctv",dataset_name=authority+" public CCTV",authority=authority,metadata_updated_at=child(root,"UpdateTime"),
                fetch_time_utc=dt.datetime.fromtimestamp((CACHE/f"{prefix}_cctv.xml").stat().st_mtime,dt.timezone.utc).isoformat(timespec="seconds"),
                record_count=count,status="stale_cached_snapshot" if prefix+"_cctv" in self.refresh_failures else "parsed",url=PUBLIC[prefix+"_cctv"]))

    def deduplicate(self):
        groups=collections.defaultdict(list)
        for camera in self.cameras:
            key=(round(camera["lat"],4),round(camera["lon"],4),camera["camera_category"],camera["direction"],camera["road_ref"],camera["section_id"])
            groups[key].append(camera)
        result=[]
        for records in groups.values():
            camera=dict(max(records,key=lambda c:(c["location_confidence"]=="A",c.get("source_updated_at",""),c["source_dataset_id"],c["id"])))
            limits={c["speed_limit_kph"] for c in records if c["speed_limit_kph"] is not None}
            # A third agreeing row must not erase a conflict raised by an earlier pair.
            if len(limits)>1:
                camera.update(is_alert_enabled=0,location_confidence="B",quality_note="Conflicting speed limits between official records")
                camera["speed_limit_kph"]=None
                self.issues.append(dict(dataset_id=camera["source_dataset_id"],road=camera["road_name"],reason=camera["quality_note"]))
            result.append(camera)
        self.stats["duplicates_removed"]=len(self.cameras)-len(result)
        self.cameras=result

    def write(self):
        DB.parent.mkdir(parents=True,exist_ok=True);OUT.mkdir(parents=True,exist_ok=True)
        temporary=DB.with_suffix(".db.new");temporary.unlink(missing_ok=True)
        connection=sqlite3.connect(temporary)
        connection.executescript("""
PRAGMA user_version=1;
CREATE TABLE build_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE source_manifest (dataset_id TEXT PRIMARY KEY,dataset_name TEXT,authority TEXT,metadata_updated_at TEXT,fetch_time_utc TEXT,record_count INTEGER,status TEXT,url TEXT);
CREATE TABLE camera_points (id TEXT PRIMARY KEY,lat REAL NOT NULL,lon REAL NOT NULL,camera_category TEXT NOT NULL,enforcement_type TEXT,road_name TEXT,road_ref TEXT,direction TEXT,speed_limit_kph INTEGER,city TEXT,district TEXT,source_dataset_id TEXT,source_authority TEXT,source_updated_at TEXT,is_live_cctv INTEGER,cctv_endpoint TEXT,position_source TEXT,location_confidence TEXT,is_alert_enabled INTEGER,road_level_hint TEXT,bearings_json TEXT,quality_note TEXT,section_id TEXT,cctv_stream_endpoint TEXT);
CREATE INDEX camera_location ON camera_points(lat,lon);
CREATE VIRTUAL TABLE camera_rtree USING rtree(rowid,min_lon,max_lon,min_lat,max_lat);
CREATE TABLE road_segments (id TEXT PRIMARY KEY,road_name TEXT,road_ref TEXT,direction TEXT,speed_limit_kph INTEGER,geometry_json TEXT,start_km REAL,end_km REAL,road_level_hint TEXT,source_type TEXT,source_dataset_id TEXT,source_updated_at TEXT);
CREATE VIRTUAL TABLE road_rtree USING rtree(rowid,min_lon,max_lon,min_lat,max_lat);
CREATE TABLE section_zones (id TEXT PRIMARY KEY,road_name TEXT,road_ref TEXT,direction TEXT,speed_limit_kph INTEGER,geometry_json TEXT,source_dataset_id TEXT,location_confidence TEXT,is_alert_enabled INTEGER,length_m REAL,start_lat REAL,start_lon REAL,end_lat REAL,end_lon REAL,road_level_hint TEXT,quality_note TEXT);
CREATE VIRTUAL TABLE section_rtree USING rtree(rowid,min_lon,max_lon,min_lat,max_lat);
CREATE VIEW speed_segments AS SELECT *, 'road' AS segment_kind FROM road_segments WHERE speed_limit_kph IS NOT NULL;
""")
        def insert(table,record):
            keys=list(record)
            connection.execute(f"INSERT INTO {table} ({','.join(keys)}) VALUES ({','.join('?' for _ in keys)})",[record[k] for k in keys])
            return connection.execute("SELECT last_insert_rowid()").fetchone()[0]
        references = load_catalogue(CACHE)
        reference_sources = reference_manifest(references)
        by_source = {m["dataset_id"]:m for m in reference_sources}
        for manifest in self.manifest:
            if manifest["dataset_id"] in by_source:
                reference = by_source[manifest["dataset_id"]]
                manifest.update(record_count=reference["record_count"],fetch_time_utc=reference["fetch_time_utc"],
                                status="stale_cached_reference" if manifest["dataset_id"] in self.refresh_failures else reference["status"])
        existing = {m["dataset_id"] for m in self.manifest}
        self.manifest += [m for m in reference_sources if m["dataset_id"] not in existing]
        for m in self.manifest:insert("source_manifest",m)
        write_catalogue(connection, references)
        for c in self.cameras:
            rid=insert("camera_points",c)
            connection.execute("INSERT INTO camera_rtree VALUES (?,?,?,?,?)",(rid,c["lon"],c["lon"],c["lat"],c["lat"]))
        for table,rtree,records in (("road_segments","road_rtree",self.roads),("section_zones","section_rtree",self.zones)):
            for r in records:
                values=dict(r);points=values.pop("points");values["geometry_json"]=json.dumps(points,separators=(",",":"))
                rid=insert(table,values)
                connection.execute(f"INSERT INTO {rtree} VALUES (?,?,?,?,?)",(rid,min(p[0] for p in points),max(p[0] for p in points),min(p[1] for p in points),max(p[1] for p in points)))
        report=dict(built_at=NOW,speed_reference_count=len(references),camera_count=len(self.cameras),enforcement_count=sum(c["camera_category"]!="cctv" for c in self.cameras),
            cctv_count=sum(c["camera_category"]=="cctv" for c in self.cameras),alert_eligible_count=sum(c["is_alert_enabled"] for c in self.cameras),
            road_segments=len(self.roads),official_speed_segments=sum(r["speed_limit_kph"] is not None for r in self.roads),section_corridors=len(self.zones),
            quality_tiers=dict(collections.Counter(c["location_confidence"] for c in self.cameras)),stats=dict(self.stats),sources=self.manifest,issues=self.issues,
            limitations=["No nationwide authoritative city-road geometry/speed table", "No verified road elevations: suppress ambiguous stacked-road matches, do not infer from absolute GPS altitude", "Blue limited section displays are approximate road-following extents, never surveyed camera coordinates or alert eligible", "Unresolved single-endpoint sections remain pins without invented exits", "OSM fallback unavailable this run (upstream 406/504); Unknown is not a speed estimate", "Not a guarantee of complete camera coverage; posted signs override this app"])
        report["section_coverage"]=dict(verified_corridors=sum(z["location_confidence"]=="A" for z in self.zones),
            estimated_display_corridors=sum(z["location_confidence"]!="A" for z in self.zones),
            endpoint_only_records=sum(c["camera_category"]=="section_speed" and not c["section_id"] for c in self.cameras))
        for key,value in (("built_at",NOW),("report",json.dumps(report,ensure_ascii=False))):insert("build_metadata",dict(key=key,value=value))
        connection.commit();connection.execute("VACUUM");assert connection.execute("PRAGMA integrity_check").fetchone()[0]=="ok";connection.close()
        temporary.replace(DB)
        (OUT/"traffic_build_report.json").write_text(json.dumps(report,ensure_ascii=False,indent=2))
        inventory=[dict(m,resources=self.inventory.get(m["dataset_id"],[])) for m in self.manifest]
        (OUT/"research_source_inventory.json").write_text(json.dumps(inventory,ensure_ascii=False,indent=2))
        checks={ref:dict(camera_count=sum(c["road_ref"]==ref for c in self.cameras),verified_corridors=sum(z["road_ref"]==ref and z["location_confidence"]=="A" for z in self.zones),
                       limited_display_corridors=sum(z["road_ref"]==ref and z["location_confidence"]!="A" for z in self.zones),
                       road_segments=len(self.by_ref[ref]),issues=[i for i in self.issues if road_ref(i.get("road",""))==ref]) for ref in ("台61","台64","國道1")}
        (OUT/"research_route_checks.json").write_text(json.dumps(checks,ensure_ascii=False,indent=2))
        coverage=[]
        for c in self.cameras:
            if c["camera_category"]!="section_speed":continue
            zone=next((z for z in self.zones if z["id"]==c["section_id"]),None)
            coverage.append(dict(camera_id=c["id"],road=c["road_name"],official_coordinate=[c["lon"],c["lat"]],source_dataset_id=c["source_dataset_id"],
                section_id=c["section_id"],span_status="verified" if zone and zone["location_confidence"]=="A" else "estimated_display_only" if zone else "endpoint_only",
                quality_note=zone["quality_note"] if zone else c["quality_note"]))
        (OUT/"section_span_inventory.json").write_text(json.dumps(dict(built_at=NOW,summary=report["section_coverage"],records=coverage),ensure_ascii=False,indent=2))
        lines=["# Taiwan traffic source audit", "", f"Fetched/build time: {NOW}","", "## Research gate", "Official data parsed, with gaps explicitly retained. The strict nationwide endpoint-pair gate is NOT met: 台61 current agency files publish only one coordinate. Those locations remain limited and never receive automatic section alerts. Their published ranges may be shown as labelled display-only estimates along official road geometry. 台64 has explicit endpoint pairs and surveyed corridors, subject to length checks.","", "## Section display coverage",json.dumps(report["section_coverage"]),"", "A = police endpoints + surveyed geometry and length checks. B display = police endpoints + openly licensed OSM road path and length check. C display = published kilometre range + approximate road-following extent. B/C are optional, never alert eligible, and never create camera coordinates. See section_span_inventory.json for every endpoint.","", "## Sources"]
        lines.extend(f"- {m['dataset_id']}: {m['dataset_name']} / {m['status']} / {m['record_count']} records / metadata {m['metadata_updated_at']} / {m['url']}" for m in self.manifest)
        lines.extend(["","## Limits",*['- '+l for l in report["limitations"]],"","## Exclusions and conflicts",*['- '+json.dumps(i,ensure_ascii=False) for i in self.issues]])
        (OUT/"research_quality_report.md").write_text("\n".join(lines)+"\n")
        print(json.dumps({k:v for k,v in report.items() if k not in ("sources","issues")},ensure_ascii=False,indent=2))


def refresh():
    from fetch_sources import download
    failures=collections.defaultdict(list)
    try:download("https://data.gov.tw/datasets/export/csv",CACHE/"catalog.csv")
    except Exception as error:failures["catalog"].append(str(error))
    for dataset_id in sorted(CAMERA_IDS|SECTION_IDS|REFERENCE_IDS):
        try:
            meta_path=CACHE/f"{dataset_id}_metadata.json"
            candidate=meta_path.with_suffix(".candidate")
            download(f"https://data.gov.tw/api/v2/rest/dataset/{dataset_id}",candidate)
            raw=json.loads(candidate.read_text());meta=raw.get("result",raw)
            if not meta.get("distribution"):raise ValueError("No metadata resources")
            candidate.replace(meta_path)
            for index,resource in enumerate(meta["distribution"]):
                if resource.get("resourceFormat","").upper() not in ("CSV","JSON","ZIP","XLSX"):continue
                target=CACHE/f"{dataset_id}_{index}.bin";candidate=target.with_suffix(".candidate")
                try:
                    download(resource["resourceDownloadUrl"],candidate)
                    validate_download(candidate.read_bytes())
                    candidate.replace(target)
                except Exception as error:
                    candidate.unlink(missing_ok=True);failures[dataset_id].append(str(error));print(f"STALE/UNREACHABLE {dataset_id}:{index}: {error}")
        except Exception as error:failures[dataset_id].append(str(error));print(f"STALE/UNREACHABLE {dataset_id}: {error}")
    for name,url in PUBLIC.items():
        target=CACHE/f"{name}.xml";candidate=target.with_suffix(".candidate")
        try:
            download(url,candidate);ET.parse(candidate);candidate.replace(target)
        except Exception as error:
            candidate.unlink(missing_ok=True);failures[name].append(str(error));print(f"STALE/UNREACHABLE {name}: {error}")
    (CACHE/"refresh_state.json").write_text(json.dumps(dict(at=NOW,failures=failures),ensure_ascii=False,indent=2))


def augment_cctv_streams(database=DB, cache=CACHE):
    """Add published streams to the existing snapshot without rebuilding any location or geometry."""
    report=dict(matched=0,missing_or_changed=0,invalid_urls=0,sources={})
    with tempfile.TemporaryDirectory(prefix="cctv-streams-",dir=cache) as directory:
        staged=pathlib.Path(directory)/"traffic.db"
        with contextlib.closing(sqlite3.connect(f"file:{database}?mode=ro",uri=True)) as original, contextlib.closing(sqlite3.connect(staged)) as target:
            original.backup(target)
            columns=[r[1] for r in target.execute("PRAGMA table_info(camera_points)")]
            if "cctv_stream_endpoint" not in columns:
                target.execute("ALTER TABLE camera_points ADD COLUMN cctv_stream_endpoint TEXT")
            for prefix in ("freeway","thb"):
                root=ET.parse(cache/f"{prefix}_cctv.xml").getroot()
                report["sources"][prefix]=dict(updated=child(root,"UpdateTime"),inventory_sha256=hashlib.sha256((cache/f"{prefix}_cctv.xml").read_bytes()).hexdigest())
                for row in root.iter():
                    if not row.tag.endswith("}CCTV"):continue
                    stream=child(row,"VideoStreamURL")
                    parsed=urllib.parse.urlparse(stream)
                    if parsed.scheme!="https" or not (parsed.hostname or "").endswith(".gov.tw") or parsed.username or parsed.password:
                        report["invalid_urls"]+=1;continue
                    identifier=prefix+":"+child(row,"CCTVID")
                    point=coordinate(child(row,"PositionLat"),child(row,"PositionLon"))
                    existing=target.execute("SELECT lat,lon FROM camera_points WHERE id=? AND camera_category='cctv'",(identifier,)).fetchone()
                    if not point or not existing or abs(existing[0]-point[1])>1e-7 or abs(existing[1]-point[0])>1e-7:
                        report["missing_or_changed"]+=1;continue
                    target.execute("UPDATE camera_points SET cctv_stream_endpoint=? WHERE id=?",(stream,identifier))
                    report["matched"]+=1
            target.commit()
            assert target.execute("PRAGMA integrity_check").fetchone()[0]=="ok"
        # Only this additive column is edited; staged DB work and downloads stay in the cache volume.
        sibling=database.with_suffix(".streams-staged.db")
        try:
            shutil.copyfile(staged,sibling);sibling.replace(database)
        finally:sibling.unlink(missing_ok=True)
    return report


if __name__=="__main__":
    parser=argparse.ArgumentParser();parser.add_argument("--refresh",action="store_true");parser.add_argument("--cctv-streams-only",action="store_true");args=parser.parse_args()
    if args.cctv_streams_only:
        if args.refresh:parser.error("Stream-only augmentation uses the matching cached inventory; run a full refresh to change source snapshots.")
        print(json.dumps(augment_cctv_streams(),ensure_ascii=False,indent=2));raise SystemExit(0)
    if args.refresh:refresh()
    builder=Builder();builder.load_roads();builder.load_datasets();builder.load_cctv();builder.deduplicate();builder.add_published_range_displays();builder.write()
