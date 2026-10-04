"""Exercise production draft SQL directly in SQLite, including interleaved writes."""
import pathlib,re,sqlite3,unittest,json
ROOT=pathlib.Path(__file__).resolve().parents[1]
SOURCE=(ROOT/"worker/drafts.ts").read_text()
def sql(prefix,source=SOURCE):
 for encoded in re.findall(r'"((?:[^"\\]|\\.)*)"',source):
  statement=json.loads('"'+encoded+'"')
  if statement.startswith(prefix):return statement
 raise AssertionError(prefix)
class DraftWrites(unittest.TestCase):
 def setUp(self):
  self.db=sqlite3.connect(":memory:")
  for migration in sorted((ROOT/"migrations").glob("*.sql")):self.db.executescript(migration.read_text())
  self.db.execute("INSERT INTO users(id,name,email) VALUES('owner','Owner','owner@example.test')")
 def change(self,query,args):
  return int(self.db.execute(query,args).fetchone() is not None)
 def create(self,key="search",kind="search"):
  return self.change(sql("INSERT INTO private_drafts"),("owner",key,kind,1,"{}", "now","owner","owner",kind,1 if kind=="search" else 20))
 def edit(self,revision):
  return self.change(sql("UPDATE private_drafts SET step="),(2,'{"introduction":"new"}',"later","owner","search",revision,"search","owner","owner","search",1))
 def test_two_tabs_cannot_clobber_or_resurrect_deleted_work(self):
  self.assertEqual(self.create(),1)
  self.assertEqual(self.create(),0)
  self.assertEqual(self.edit(1),1)
  self.assertEqual(self.edit(1),0)
  delete=sql("UPDATE private_drafts SET deleted=")
  self.assertEqual(self.change(delete,("later","owner","search",1,"owner")),0)
  self.assertEqual(self.change(delete,("later","owner","search",2,"owner")),1)
  self.assertEqual(self.edit(2),0)
  self.assertEqual(self.create(),0)
  self.assertEqual(self.edit(3),1)
 def test_suspend_between_authentication_and_write(self):
  self.assertEqual(self.create(),1)
  self.db.execute("UPDATE users SET suspended=1 WHERE id='owner'")
  self.assertEqual(self.edit(1),0)
  self.assertEqual(self.create("listing-key","listing"),0)
  self.assertEqual(self.change(sql("UPDATE private_drafts SET deleted="),("later","owner","search",1,"owner")),0)
 def test_update_returns_its_own_revision_even_after_other_tab_writes(self):
  self.create()
  self.db.row_factory=sqlite3.Row
  query=sql("UPDATE private_drafts SET step=")
  returned=self.db.execute(query,(2,'{"introduction":"A"}',"now","owner","search",1,"search","owner","owner","search",1)).fetchone()
  self.assertEqual(returned["revision"],2)
  self.assertEqual(self.edit(2),1)
  self.assertEqual(self.db.execute("SELECT revision FROM private_drafts").fetchone()[0],3)
  self.assertEqual(returned["revision"],2)
  self.assertEqual(json.loads(returned["data"])["introduction"],"A")
 def test_stale_draft_cannot_publish_listing_or_create_or_edit_search(self):
  source=(ROOT/"worker/index.ts").read_text()
  self.create()
  self.edit(1)
  insert=sql("INSERT INTO seeker_requests(id,ownerId,status,data,createdAt,updatedAt,profileSearch) SELECT",source)
  args=("public-search","owner","paused","{}","now","now","owner",1,"owner",1)
  self.assertEqual(self.db.execute(insert,args).rowcount,0)
  self.assertEqual(self.db.execute(insert,(*args[:7],2,"owner",2)).rowcount,1)
  self.edit(2)
  update=sql("UPDATE seeker_requests SET data=?,status=?,updatedAt=?",source)
  self.assertEqual(self.db.execute(update,('{"maxBudget":1}',"active","later","public-search","owner","owner",2,"owner",2)).rowcount,0)
  self.assertEqual(self.db.execute("SELECT data FROM seeker_requests").fetchone()[0],"{}")
  self.create("property-draft","listing")
  self.db.execute("UPDATE private_drafts SET revision=2 WHERE id='property-draft'")
  listing=sql("INSERT INTO listings(id,ownerId,data,status,createdAt,createKey) SELECT",source)
  args=("place","owner","{}","now","property-draft","owner",1,"owner","property-draft",1)
  self.assertEqual(self.db.execute(listing,args).rowcount,0)
  self.assertEqual(self.db.execute(listing,(*args[:6],2,"owner","property-draft",2)).rowcount,1)
 def test_limit_is_enforced_by_write_statement(self):
  for i in range(20):self.assertEqual(self.create(str(i),"listing"),1)
  self.assertEqual(self.create("21","listing"),0)
if __name__=="__main__":unittest.main()
