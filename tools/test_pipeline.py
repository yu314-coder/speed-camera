import io
import json
import pathlib
import sqlite3
import tempfile
import unittest
import zipfile
import build_tw_traffic_db as pipeline
import speed_references as references

REFERENCE_FIXTURES = pathlib.Path(__file__).resolve().parent / "fixtures/speed_references"

class PipelineTests(unittest.TestCase):
    def test_speed_references_preserve_vehicle_curve_and_freeway_exceptions(self):
        data = references.load_catalogue(REFERENCE_FIXTURES)
        self.assertEqual(len(data), 84)
        curve = next(r for r in data if r["road_ref"] == "台64" and "彎道" in r["speed_limit_text"])
        self.assertIsNone(curve["speed_limit_kph"])
        self.assertEqual(curve["speed_limit_text"], "直線段：70、彎道段：60")
        self.assertIn("側車道", curve["conditions"])
        freeway = next(r for r in data if r["road_ref"] == "國道3甲")
        self.assertIn("70", freeway["segment_description"])
        self.assertIn("20公噸", freeway["conditions"])
        city = [r for r in data if r["source_dataset_id"] == "121671"]
        self.assertEqual(len(city), 34)
        self.assertEqual(sum(r["speed_limit_kph"] == 30 for r in city), 3)

    def test_speed_reference_csv_encodings_and_no_generic_note_inference(self):
        for encoding in ("utf-8-sig", "cp950"):
            rows = references.decode_csv("路段,速限,備註\n市民大道,40,條件\n".encode(encoding))
            self.assertEqual(rows[0]["路段"], "市民大道")
        rows = [{"路段":"fixture", "原因":"Unknown", "備註":"一般道路30或40公里"}]
        self.assertEqual(references.csv_references(rows, "121671", "", ""), [])

    def test_speed_reference_augmentation_does_not_change_cameras_or_geometry(self):
        with tempfile.TemporaryDirectory() as directory:
            database = pathlib.Path(directory)/"snapshot.db"
            with sqlite3.connect(pipeline.DB) as source, sqlite3.connect(database) as target:
                source.backup(target)
            before = sqlite3.connect(database)
            snapshot = {table:before.execute(f"SELECT * FROM {table} ORDER BY rowid").fetchall()
                        for table in ("camera_points", "road_segments", "section_zones")}
            built = before.execute("SELECT value FROM build_metadata WHERE key='built_at'").fetchone()
            before.close()
            report = references.augment(database, REFERENCE_FIXTURES)
            self.assertEqual(report["reference_count"], 84)
            with sqlite3.connect(database) as after:
                for table, rows in snapshot.items():
                    self.assertEqual(after.execute(f"SELECT * FROM {table} ORDER BY rowid").fetchall(), rows)
                self.assertEqual(after.execute("SELECT value FROM build_metadata WHERE key='built_at'").fetchone(), built)
                self.assertEqual(after.execute("PRAGMA integrity_check").fetchone()[0], "ok")

    def test_reviewed_reference_snapshot_rejects_non_official_host(self):
        with tempfile.TemporaryDirectory() as directory:
            cache = pathlib.Path(directory)
            (cache/"thb_speed_references.json").write_text(json.dumps(dict(
                status="reviewed_web_snapshot_not_machine_feed", checked_at_utc="2026-10-02",
                rows=[dict(road="台64", segment="test", speed="80", notes="", url="https://www.thb.gov.tw.evil.com/News_ExpresswaySpeedLimit.aspx")])) )
            with self.assertRaises(ValueError): references.load_catalogue(cache)
    def test_stream_augmentation_requires_published_identity_and_same_coordinate(self):
        with tempfile.TemporaryDirectory() as directory:
            cache=pathlib.Path(directory);database=cache/"fixture.db"
            with sqlite3.connect(database) as connection:
                connection.execute("CREATE TABLE camera_points(id TEXT PRIMARY KEY,lat REAL,lon REAL,camera_category TEXT,is_alert_enabled INTEGER)")
                connection.executemany("INSERT INTO camera_points VALUES (?,?,?,?,?)",[("thb:valid",25.04,121.51,"cctv",0),("thb:moved",25.05,121.51,"cctv",0),("police:one",25.04,121.51,"speed",1)])
            def camera(identifier,url,lat="25.04"):
                return f"<CCTV><CCTVID>{identifier}</CCTVID><PositionLat>{lat}</PositionLat><PositionLon>121.51</PositionLon><VideoStreamURL>{url}</VideoStreamURL></CCTV>"
            document='<CCTVList xmlns="http://traffic.transportdata.tw/standard/traffic/schema/"><UpdateTime>2026-09-30</UpdateTime><CCTVs>'
            (cache/"thb_cctv.xml").write_text(document+camera("valid","https://cctv-ss02.thb.gov.tw/T62-9K+020")+camera("moved","https://cctv-ss02.thb.gov.tw/other")+camera("bad","https://example.com/video")+'</CCTVs></CCTVList>')
            (cache/"freeway_cctv.xml").write_text(document+'</CCTVs></CCTVList>')
            report=pipeline.augment_cctv_streams(database,cache)
            self.assertEqual(report["matched"],1);self.assertEqual(report["missing_or_changed"],1);self.assertEqual(report["invalid_urls"],1)
            with sqlite3.connect(database) as connection:
                rows=connection.execute("SELECT id,lat,lon,camera_category,is_alert_enabled,cctv_stream_endpoint FROM camera_points ORDER BY id").fetchall()
            self.assertEqual(rows[0],("police:one",25.04,121.51,"speed",1,None))
            self.assertIsNone(rows[1][-1]);self.assertEqual(rows[2][-1],"https://cctv-ss02.thb.gov.tw/T62-9K+020")
    def test_utf8_bom_and_big5(self):
        for encoding in ("utf-8-sig","big5"):
            self.assertEqual(pipeline.decode("緯度,經度\n25,121\n".encode(encoding)),"緯度,經度\n25,121\n")
    def test_dual_header_is_not_a_location(self):
        rows=pipeline.rows_from_bytes(b"Latitude,Longitude\n\xe7\xb7\xaf\xe5\xba\xa6,\xe7\xb6\x93\xe5\xba\xa6\n25,121\n")
        locations=[pipeline.coordinate(r["Latitude"],r["Longitude"]) for r in rows]
        self.assertEqual([p for p in locations if p],[(121,25)])
    def test_zip_ignores_manifest(self):
        stream=io.BytesIO()
        with zipfile.ZipFile(stream,"w") as archive:
            archive.writestr("manifest.csv","x\nmetadata\n");archive.writestr("locations.csv","lat,lon\n25,121\n")
        self.assertEqual(pipeline.rows_from_bytes(stream.getvalue()),[{"lat":"25","lon":"121"}])
    def test_bad_official_longitude_not_guessed(self):
        self.assertIsNone(pipeline.coordinate("24.4974587","122.6769237"))
        self.assertIsNone(pipeline.coordinate("121","25"))
    def test_ambiguous_speed_not_first_number(self):
        self.assertIsNone(pipeline.speed("50往北60往南"));self.assertIsNone(pipeline.speed("大車80/小車90"))
        self.assertEqual(pipeline.speed("70公里"),70)
    def test_bearings_and_road_ref(self):
        self.assertEqual(pipeline.direction_bearings("北往南"),[180])
        self.assertEqual(pipeline.direction_bearings("南北雙向"),[0,180])
        self.assertEqual(pipeline.road_ref("臺64線快速公路"),"台64")
    def test_empty_refresh_does_not_replace_a_snapshot(self):
        with self.assertRaises(ValueError):pipeline.validate_download(b"Latitude,Longitude\n")
    def duplicate_record(self,identifier,limit,confidence="A",updated="2026-09-30"):
        return dict(id=identifier,lat=25.04,lon=121.51,camera_category="speed",direction="南往北",road_ref="台1",
                    section_id=None,source_dataset_id=identifier,location_confidence=confidence,source_updated_at=updated,
                    is_alert_enabled=int(confidence=="A"),speed_limit_kph=limit,road_name="台1線",quality_note="Fixture")
    def test_three_source_conflict_cannot_reenable_alert(self):
        builder=pipeline.Builder()
        builder.cameras=[self.duplicate_record("one",50),self.duplicate_record("two",60),self.duplicate_record("three",60)]
        builder.deduplicate()
        self.assertEqual(len(builder.cameras),1)
        self.assertEqual(builder.cameras[0]["is_alert_enabled"],0)
        self.assertEqual(builder.cameras[0]["location_confidence"],"B")
        self.assertIsNone(builder.cameras[0]["speed_limit_kph"])
    def test_dedup_prefers_confidence_then_newest_record(self):
        builder=pipeline.Builder()
        builder.cameras=[self.duplicate_record("old",50,updated="2025-01-01"),
                         self.duplicate_record("new",50,updated="2026-09-29"),
                         self.duplicate_record("weak",50,confidence="B")]
        builder.deduplicate()
        self.assertEqual(builder.cameras[0]["id"],"new")
        self.assertEqual(builder.stats["duplicates_removed"],2)
    def test_real_snapshot_integrity_and_quality(self):
        db=sqlite3.connect(pipeline.DB)
        self.assertEqual(db.execute("PRAGMA integrity_check").fetchone()[0],"ok")
        self.assertEqual(db.execute("SELECT COUNT(*) FROM camera_points WHERE is_alert_enabled=1 AND location_confidence!='A'").fetchone()[0],0)
        self.assertEqual(db.execute("SELECT COUNT(*) FROM camera_points WHERE camera_category='cctv' AND is_alert_enabled=1").fetchone()[0],0)
        self.assertGreaterEqual(db.execute("SELECT COUNT(*) FROM section_zones WHERE road_ref='台64' AND is_alert_enabled=1").fetchone()[0],5)
        self.assertEqual(db.execute("SELECT COUNT(*) FROM camera_points").fetchone()[0],db.execute("SELECT COUNT(*) FROM camera_rtree").fetchone()[0])
        db.close()
    def test_source_failures_are_reported(self):
        with sqlite3.connect(pipeline.DB) as db:
            statuses=dict(db.execute("SELECT dataset_id,status FROM source_manifest"))
        self.assertNotEqual(statuses["105021"],"parsed");self.assertNotEqual(statuses["169929"],"parsed")
    def test_clip_path_preserves_bends_and_direction(self):
        points=[(121,25),(121.01,25),(121.01,25.01)]
        path=pipeline.clip_path(points,.1,.9)
        self.assertIn(points[1],path)
        self.assertEqual(path,list(reversed(pipeline.clip_path(points,.9,.1))))
    def test_published_ranges_are_not_confused_with_road_numbers(self):
        self.assertEqual(pipeline.published_km_range("台61線157.8K至151.6K"),(157.8,151.6))
        self.assertEqual(pipeline.published_km_range("台61線177至168.1公里"),(177,168.1))
        self.assertIsNone(pipeline.published_km_range("台64線25.2K匝道"))
    def test_estimated_spans_are_never_alert_eligible_or_fake_camera_coordinates(self):
        shapes=json.loads((pipeline.ROOT/"Speedlimit/Resources/osm_section_display_shapes.json").read_text())
        self.assertEqual(shapes['license'],'ODbL-1.0')
        self.assertEqual(len(shapes['derived_spans']),3)
        self.assertTrue(all(s['geometry_source']=='osm_road_geometry_display_only' for s in shapes['derived_spans']))
        db=sqlite3.connect(pipeline.DB)
        self.assertEqual(db.execute("SELECT COUNT(*) FROM section_zones WHERE location_confidence!='A' AND is_alert_enabled!=0").fetchone()[0],0)
        self.assertEqual(db.execute("SELECT COUNT(*) FROM camera_points WHERE position_source!='explicit_official_coordinate'").fetchone()[0],0)
        self.assertEqual(db.execute("SELECT COUNT(*) FROM section_zones WHERE road_ref='台61' AND location_confidence='C'").fetchone()[0],4)
        self.assertEqual(db.execute("SELECT COUNT(*) FROM camera_points c WHERE c.camera_category='section_speed' AND c.section_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM section_zones s WHERE s.id=c.section_id)").fetchone()[0],0)
        db.close()
    def test_disconnected_geometry_is_rejected(self):
        builder=pipeline.Builder()
        builder.by_ref['fixture']=[dict(start_km=1,end_km=2,points=[(121,25),(121,25.009)]),
            dict(start_km=2,end_km=3,points=[(122,25),(122,25.009)])]
        path,reason=builder.kilometer_corridor('fixture',1,3)
        self.assertIsNone(path);self.assertIn('disconnected',reason)

if __name__=="__main__":unittest.main()
