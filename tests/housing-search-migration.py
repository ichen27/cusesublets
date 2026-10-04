"""Offline fixture proves migration preserves historical references and blocks revival."""
import pathlib, sqlite3, unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
class Migration(unittest.TestCase):
 def test_legacy_rows_and_references(self):
  db=sqlite3.connect(":memory:")
  db.execute("PRAGMA foreign_keys=ON")
  for file in sorted((ROOT/"migrations").glob("000[1-8]_*.sql")):
   db.executescript(file.read_text())
  db.executescript((ROOT/"seeds/demo.sql").read_text())
  db.executescript((ROOT/"tests/housing-search-fixtures.sql").read_text())
  db.execute("INSERT INTO seeker_requests(id,ownerId,status,data,createdAt,updatedAt) VALUES('closed-only','demo-host','closed','{}','2026-09-05','2026-09-05')")
  before=db.execute("SELECT id,requestId FROM conversations WHERE requestId IS NOT NULL").fetchall()
  db.executescript((ROOT/"migrations/0009_profile_search.sql").read_text())
  self.assertEqual(db.execute("SELECT id FROM seeker_requests WHERE ownerId='demo-renter' AND profileSearch=1").fetchall(),[("chosen-active",)])
  self.assertEqual(db.execute("SELECT status FROM seeker_requests WHERE id='closed-only' AND profileSearch=1").fetchone(),("paused",))
  self.assertEqual(db.execute("SELECT status FROM seeker_requests WHERE id='chosen-active'").fetchone(),("paused",))
  self.assertEqual(db.execute("SELECT status FROM seeker_requests WHERE id='removed-only' AND profileSearch=1").fetchone(),("removed",))
  self.assertEqual(db.execute("SELECT id FROM seeker_requests ORDER BY id").fetchall(),[("chosen-active",),("closed-only",),("old-paused",),("old-removed",),("removed-only",)])
  self.assertEqual(db.execute("SELECT id,requestId FROM conversations WHERE requestId IS NOT NULL").fetchall(),before)
  self.assertEqual(db.execute("SELECT requestId FROM request_reports WHERE id='legacy-report'").fetchone(),("old-removed",))
  with self.assertRaises(sqlite3.IntegrityError):
   db.execute("UPDATE seeker_requests SET profileSearch=1 WHERE id='old-paused'")
if __name__=="__main__":unittest.main()
