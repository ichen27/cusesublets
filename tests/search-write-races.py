"""Exercise the actual Worker SQL after a stale read, using SQLite like local D1."""
import json, pathlib, re, sqlite3, unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
SOURCE=(ROOT/'worker/index.ts').read_text()
def query(prefix):
 return next(q for q in re.findall(r'stmt\(e, "([^"]+)"',SOURCE) if q.startswith(prefix))
class Races(unittest.TestCase):
 def setUp(self):
  self.db=sqlite3.connect(':memory:')
  for file in sorted((ROOT/'migrations').glob('*.sql')): self.db.executescript(file.read_text())
  self.db.executescript((ROOT/'seeds/demo.sql').read_text())
  self.db.execute("INSERT INTO seeker_requests(id,ownerId,status,data,createdAt,updatedAt,profileSearch) VALUES('race-search','demo-renter','active','{}','now','now',1)")
  self.data=self.db.execute("SELECT data FROM listings WHERE id='walnut-sunroom'").fetchone()[0]
  self.contact=query('INSERT INTO conversations(id,listingId,buyerId,sellerId,createdAt,updatedAt,requestId) SELECT')
 def insert(self):
  return self.db.execute(self.contact,('race-thread','walnut-sunroom','demo-renter','demo-host','now','now','race-search','race-search','now','{}','walnut-sunroom',self.data)).rowcount
 def test_current_snapshot_can_contact(self): self.assertEqual(self.insert(),1)
 def test_off_after_read_blocks_contact(self):
  self.db.execute("UPDATE seeker_requests SET status='paused' WHERE id='race-search'")
  self.assertEqual(self.insert(),0)
 def test_criteria_changed_same_timestamp_blocks_contact(self):
  self.db.execute("UPDATE seeker_requests SET data='{\"maxBudget\":100}' WHERE id='race-search'")
  self.assertEqual(self.insert(),0)
 def test_listing_changed_after_read_blocks_contact(self):
  self.db.execute("UPDATE listings SET data=json_set(data,'$.price',1900) WHERE id='walnut-sunroom'")
  self.assertEqual(self.insert(),0)
 def test_suspension_after_read_blocks_contact(self):
  self.db.execute("UPDATE users SET suspended=1 WHERE id='demo-renter'")
  self.assertEqual(self.insert(),0)
 def test_media_and_owner_edits_preserve_each_other(self):
  edit=query('UPDATE listings SET data=json_patch')
  upload=query("UPDATE listings SET data=json_insert(CASE")
  for order in [(edit,upload),(upload,edit)]:
   for sql in order:
    args=(json.dumps({'price':910,'title':'Edited place'}),'walnut-sunroom','demo-host') if sql==edit else ('/media/new-image','walnut-sunroom')
    self.db.execute(sql,args)
   data=json.loads(self.db.execute("SELECT data FROM listings WHERE id='walnut-sunroom'").fetchone()[0])
   self.assertEqual(data['price'],910)
   self.assertIn('/media/new-image',data['images'])
if __name__=='__main__':unittest.main()
