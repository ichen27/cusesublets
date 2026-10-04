"""Exercise actual Worker mutation SQL against SQLite, including stale-read races and limits."""
import pathlib,re,sqlite3,json,unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
SOURCE=(ROOT/'worker/social.ts').read_text()
def query(prefix):
 value=next(s for s in re.findall(r'prepare\(\s*`([^`]+)`\s*,?\s*\)',SOURCE) if s.startswith(prefix))
 for name in ['visible','actor','staff']:
  constant=re.search(r'const '+name+r' =\s*"([^"]+)";',SOURCE).group(1)
  value=value.replace('${'+name+'}',constant)
 return value
CREATE=query('INSERT INTO social_comments(')
EDIT=query('UPDATE social_comments SET body=')
MODERATE=query('UPDATE social_comments SET removed=')
RESOLVE=query('UPDATE social_comment_reports SET status=')
REPORT=query('INSERT INTO social_comment_reports(')
class SocialSQL(unittest.TestCase):
 def setUp(self):
  self.db=sqlite3.connect(':memory:')
  for path in sorted((ROOT/'migrations').glob('*.sql')):self.db.executescript(path.read_text())
  for id,role in [('host','member'),('member','member'),('other','member'),('admin','admin')]:self.db.execute('INSERT INTO users(id,name,email,role) VALUES(?,?,?,?)',(id,id,id+'@example.com',role))
  self.db.execute("INSERT INTO listings(id,ownerId,status,data) VALUES('post','host','approved',?)",(json.dumps({'endDate':'2099-12-31'}),))
  self.db.execute("INSERT INTO seeker_requests(id,ownerId,status,data,createdAt,updatedAt,profileSearch) VALUES('search','host','active',?,'2026','2026',1)",(json.dumps({'endDate':'2099-12-31'}),))
 def create(self,key='c',parent=None,target='post',kind='listing',author='member',client=None):
  client=client or key+'-client'
  return self.db.execute(CREATE,(key,kind,target,author,parent,'Hello',client,'2026-10-04T12:00:00Z',kind,target,'2026-10-04',author,author,client)).rowcount
 def test_stale_listing_and_search_status_actor_owner_and_expiration(self):
  for sql in ["UPDATE listings SET status='pending'","UPDATE users SET suspended=1 WHERE id='member'","UPDATE users SET suspended=1 WHERE id='host'","UPDATE listings SET data='{\"endDate\":\"2020-01-01\"}'"]:
   with self.subTest(sql=sql):
    self.db.execute('SAVEPOINT race');self.db.execute(sql);self.assertEqual(self.create(),0);self.db.execute('ROLLBACK TO race');self.db.execute('RELEASE race')
  self.db.execute("UPDATE seeker_requests SET status='paused'");self.assertEqual(self.create(target='search',kind='search'),0)
 def test_single_reply_depth_same_target_and_tombstone_parent(self):
  self.create('parent');self.create('reply',parent='parent')
  for key,parent,target,kind in [('nested','reply','post','listing'),('other-post','parent','search','search')]:
   with self.assertRaisesRegex(sqlite3.IntegrityError,'Reply parent unavailable'):self.create(key,parent,target,kind)
  self.db.execute("UPDATE social_comments SET deleted=1 WHERE id='parent'")
  with self.assertRaisesRegex(sqlite3.IntegrityError,'Reply parent unavailable'):self.create('deleted-parent',parent='parent')
  self.assertEqual(self.db.execute("SELECT count(*) FROM social_comments WHERE parentId='parent'").fetchone()[0],1)
 def test_idempotency_and_rolling_limit(self):
  self.create('one');self.assertEqual(self.create('duplicate',client='one-client'),0)
  for i in range(9):self.create(str(i))
  self.assertEqual(self.db.execute('SELECT count(*) FROM social_comments').fetchone()[0],10)
  self.assertEqual(self.create('retry',client='one-client'),0)
  with self.assertRaisesRegex(sqlite3.IntegrityError,'Social comment rate limit'):self.create('eleven')
  self.db.execute('UPDATE social_rate_events SET at=at-601');self.assertEqual(self.create('after-window'),1)
 def test_edit_requires_owner_active_target_and_current_actor(self):
  self.create()
  values=('new',1,'2026-10-04',0,'c','other','listing','post','2026-10-04','other')
  self.assertIsNone(self.db.execute(EDIT,values).fetchone())
  self.db.execute("UPDATE listings SET status='pending'")
  values=('new',1,'2026-10-04',0,'c','member','listing','post','2026-10-04','member')
  self.assertIsNone(self.db.execute(EDIT,values).fetchone())
  self.assertEqual(self.db.execute("SELECT body FROM social_comments WHERE id='c'").fetchone()[0],'Hello')
 def test_admin_audit_atomic_restore_and_no_resurrection_of_author_delete(self):
  self.create();self.db.execute("UPDATE listings SET status='pending'")
  self.assertIsNone(self.db.execute(MODERATE,(1,'other','reason','c','other')).fetchone())
  self.assertEqual(self.db.execute(MODERATE,(1,'admin','Removed spam','c','admin')).fetchone()[0],'c')
  self.db.execute(MODERATE,(0,'admin','Reviewed appeal','c','admin')).fetchone()
  self.assertEqual(self.db.execute("SELECT count(*) FROM audit WHERE targetId='c'").fetchone()[0],2)
  self.db.execute("UPDATE social_comments SET deleted=1 WHERE id='c'")
  self.assertIsNone(self.db.execute(MODERATE,(0,'admin','restore','c','admin')).fetchone())
 def test_reports_hidden_guard_dedup_and_resolution_audit(self):
  self.create();values=('report','c','other','spam','2026','listing','post','2026-10-04','other','c','c','other')
  self.db.execute(REPORT,values);self.assertEqual(self.db.execute(REPORT,values).rowcount,0)
  self.assertIsNone(self.db.execute(RESOLVE,('other','done','report','other')).fetchone())
  self.db.execute(RESOLVE,('admin','Reviewed','report','admin')).fetchone()
  self.assertEqual(self.db.execute("SELECT count(*) FROM audit WHERE action='comment.report.resolve'").fetchone()[0],1)
 def test_reaction_insert_uses_current_target_and_actor(self):
  raw=next(s for s in re.findall(r'prepare\(\s*`([^`]+)`\s*,?\s*\)',SOURCE) if s.startswith('INSERT INTO ${table}'))
  for name in ['visible','actor']:
   raw=raw.replace('${'+name+'}',re.search(r'const '+name+r' =\s*"([^"]+)";',SOURCE).group(1))
  for table in ['social_likes','social_saves']:
   sql=raw.replace('${table}',table)
   values=('listing','post','member','2026','listing','post','2026-10-04','member','listing','post','member')
   self.db.execute("UPDATE listings SET status='pending'")
   self.assertEqual(self.db.execute(sql,values).rowcount,0)
   self.db.execute("UPDATE listings SET status='approved'")
   self.db.execute("UPDATE users SET suspended=1 WHERE id='member'")
   self.assertEqual(self.db.execute(sql,values).rowcount,0)
   self.db.execute("UPDATE users SET suspended=0 WHERE id='member'")
   self.assertEqual(self.db.execute(sql,values).rowcount,1)
   self.assertEqual(self.db.execute(sql,values).rowcount,0)
 def test_reaction_mutation_limit(self):
  for i in range(60):
   self.db.execute("INSERT INTO social_likes VALUES('listing','post','member','2026')")
   self.db.execute("DELETE FROM social_likes WHERE userId='member'")
  with self.assertRaisesRegex(sqlite3.IntegrityError,'Social reaction rate limit'):self.db.execute("INSERT INTO social_saves VALUES('listing','post','member','2026')")
if __name__=='__main__':unittest.main()
