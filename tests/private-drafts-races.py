"""Exercise production draft SQL directly in SQLite, including interleaved writes."""
import pathlib,re,sqlite3,unittest,json
ROOT=pathlib.Path(__file__).resolve().parents[1]
SOURCE=(ROOT/"worker/drafts.ts").read_text()
def sql(prefix):
 for encoded in re.findall(r'"((?:[^"\\]|\\.)*)"',SOURCE):
  statement=json.loads('"'+encoded+'"')
  if statement.startswith(prefix):return statement
 raise AssertionError(prefix)
class DraftWrites(unittest.TestCase):
 def setUp(self):
  self.db=sqlite3.connect(":memory:")
  for migration in sorted((ROOT/"migrations").glob("*.sql")):self.db.executescript(migration.read_text())
  self.db.execute("INSERT INTO users(id,name,email) VALUES('owner','Owner','owner@example.test')")
 def create(self,key="search",kind="search"):
  return self.db.execute(sql("INSERT INTO private_drafts"),("owner",key,kind,1,"{}", "now","owner","owner",kind,1 if kind=="search" else 20)).rowcount
 def edit(self,revision):
  return self.db.execute(sql("UPDATE private_drafts SET step="),(2,'{"introduction":"new"}',"later","owner","search",revision,"search","owner","owner","search",1)).rowcount
 def test_two_tabs_cannot_clobber_or_resurrect_deleted_work(self):
  self.assertEqual(self.create(),1)
  self.assertEqual(self.create(),0)
  self.assertEqual(self.edit(1),1)
  self.assertEqual(self.edit(1),0)
  delete=sql("UPDATE private_drafts SET deleted=")
  self.assertEqual(self.db.execute(delete,("later","owner","search",1,"owner")).rowcount,0)
  self.assertEqual(self.db.execute(delete,("later","owner","search",2,"owner")).rowcount,1)
  self.assertEqual(self.edit(2),0)
  self.assertEqual(self.create(),0)
  self.assertEqual(self.edit(3),1)
 def test_suspend_between_authentication_and_write(self):
  self.assertEqual(self.create(),1)
  self.db.execute("UPDATE users SET suspended=1 WHERE id='owner'")
  self.assertEqual(self.edit(1),0)
  self.assertEqual(self.create("listing-key","listing"),0)
  self.assertEqual(self.db.execute(sql("UPDATE private_drafts SET deleted="),("later","owner","search",1,"owner")).rowcount,0)
 def test_limit_is_enforced_by_write_statement(self):
  for i in range(20):self.assertEqual(self.create(str(i),"listing"),1)
  self.assertEqual(self.create("21","listing"),0)
if __name__=="__main__":unittest.main()
