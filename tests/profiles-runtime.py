"""Only against an isolated local demo database. Exercises profiles and evidence boundaries."""
import importlib.util,unittest,json,sqlite3,glob,os
spec=importlib.util.spec_from_file_location('runtime','tests/api-runtime.py');rt=importlib.util.module_from_spec(spec);spec.loader.exec_module(rt)
Client=rt.Client
class Profiles(unittest.TestCase):
 def test_profiles(self):
  guest,host,renter,admin=Client(),Client(),Client(),Client()
  host.login('host');renter.login('renter');admin.login('admin')
  self.assertEqual(guest.call('/api/profile')[0],401)
  original=host.call('/api/profile')[1]['user']['name']
  status,data=host.call('/api/profile',dict(name=original,phone='PRIVATE-PHONE',bio='Public host biography',socials=dict(website='https://example.com/about')))
  self.assertEqual(status,200,data);self.assertEqual(host.call('/api/profile',dict(bio='Updated biography'))[1]['profile']['phone'],'PRIVATE-PHONE')
  self.assertEqual(host.call('/api/profile',dict(socials=dict(website='javascript:alert(1)')))[0],400)
  public=guest.call('/api/users/demo-host')[1];encoded=json.dumps(public)
  for secret in ['PRIVATE-PHONE','email','identityNote','identityDocuments','objectKey','nameVersion']:self.assertNotIn(secret,encoded)
  self.assertEqual(public['profile']['bio'],'Updated biography')
  self.assertEqual(host.upload('/api/profile/identity',data=b'not pdf')[0],400)
  self.assertEqual(host.upload('/api/profile/identity',data=b'%PDF-'+b'x'*(5*1024*1024))[0],413)
  status,result=host.upload('/api/profile/identity');self.assertEqual(status,201,result);doc=result['document']['id']
  for client,expected in [(guest,401),(renter,403),(host,200),(admin,200)]:
   status,headers,_=client.raw('/api/identity-documents/'+doc);self.assertEqual(status,expected)
   if status==200:self.assertEqual(headers['Cache-Control'],'no-store');self.assertIn('attachment',headers['Content-Disposition'])
  self.assertEqual(guest.raw('/api/profile-media/'+doc)[0],404)
  review=dict(status='verified',reason='Current test evidence manually reviewed',documentId=doc)
  self.assertEqual(renter.call('/api/admin/identities/demo-host/review',review)[0],403)
  self.assertEqual(admin.call('/api/admin/identities/demo-host/review',{**review,'documentId':'old'})[0],409)
  self.assertEqual(admin.call('/api/admin/identities/demo-host/review',review)[0],200)
  self.assertEqual(host.call('/api/profile')[1]['user']['identity'],'verified')
  new=host.upload('/api/profile/identity')[1]['document']['id']
  self.assertEqual(host.call('/api/profile')[1]['user']['identity'],'pending')
  self.assertEqual(admin.call('/api/admin/identities/demo-host/review',review)[0],409)
  review['documentId']=new
  self.assertEqual(admin.call('/api/admin/identities/demo-host/review',review)[0],200)
  self.assertEqual(host.call('/api/profile',dict(name=original+' Changed'))[1]['user']['identity'],'pending')
  self.assertEqual(admin.call('/api/admin/identities/demo-host/review',review)[0],409)
  host.call('/api/profile',dict(name=original))
  review['documentId']=host.upload('/api/profile/identity')[1]['document']['id']
  self.assertEqual(admin.call('/api/admin/identities/demo-host/review',review)[0],200)
  self.assertEqual(admin.call('/api/admin/identities/demo-admin/review',review)[0],403)
  status,result=host.upload('/api/profile/media',kind='avatar',mime='image/png',name='avatar.png',data=b'\x89PNG\r\n\x1a\n')
  self.assertEqual(status,201,result);url=result['url']
  self.assertEqual(guest.raw(url)[0],200)
  oldUrl=url
  status,result=host.upload('/api/profile/media',kind='avatar',mime='image/png',name='replacement.png',data=b'\x89PNG\r\n\x1a\n')
  self.assertEqual(status,201,result);url=result['url']
  self.assertEqual(guest.raw(oldUrl)[0],404)
  self.assertEqual(guest.raw(url)[0],200)
  self.assertEqual(guest.call('/api/users/demo-host')[1]['profile']['avatar'],url)
  self.assertEqual(renter.call('/api/profile/media/remove',dict(url=url))[0],404)
  self.assertEqual(host.call('/api/profile/media/remove',dict(url=url))[0],200)
  self.assertEqual(guest.raw(url)[0],404)
  self.assertNotIn('avatar',guest.call('/api/users/demo-host')[1]['profile'])
  self.assertEqual(guest.call('/api/listings/pending-ostrom')[0],404)
  # Advance only a reservation created by api-runtime in this isolated DB.
  dbpath=glob.glob(os.environ.get('CHECKS_STATE','.wrangler-checks')+'/v3/d1/miniflare-D1DatabaseObject/*.sqlite')[0]
  db=sqlite3.connect(dbpath)
  bid=db.execute("SELECT id FROM bookings WHERE buyerId='demo-renter' AND sellerId='demo-host' AND paymentStatus='demo_paid' ORDER BY rowid DESC LIMIT 1").fetchone()[0]
  self.assertNotIn(bid,[b['id'] for b in renter.call('/api/users/demo-host')[1]['reviewableBookings']])
  db.execute("UPDATE bookings SET startDate='2025-01-01',endDate='2025-02-01',moveInAt='2025-01-01T12:00:00Z',disputeStatus='none' WHERE id=?",(bid,));db.commit()
  body=dict(bookingId=bid,rating=5,body='The completed lease was handled very well.')
  self.assertIn(bid,[b['id'] for b in renter.call('/api/users/demo-host')[1]['reviewableBookings']])
  self.assertEqual(host.call('/api/users/demo-host/reviews',body)[0],409)
  self.assertEqual(admin.call('/api/users/demo-host/reviews',body)[0],409)
  self.assertEqual(renter.call('/api/users/demo-host/reviews',{**body,'rating':4.5})[0],400)
  db.execute("UPDATE bookings SET disputeStatus='open' WHERE id=?",(bid,));db.commit()
  self.assertEqual(renter.call('/api/users/demo-host/reviews',body)[0],409)
  db.execute("UPDATE bookings SET disputeStatus='resolved' WHERE id=?",(bid,));db.commit()
  status,result=renter.call('/api/users/demo-host/reviews',body);self.assertEqual(status,201,result)
  self.assertEqual(renter.call('/api/users/demo-host/reviews',body)[0],409)
  self.assertEqual(host.call('/api/users/demo-renter/reviews',body)[0],201)
  self.assertTrue(any(r['body']==body['body'] for r in guest.call('/api/users/demo-host')[1]['reviews']))
  # Real Access user IDs contain colons and are encoded by the browser.
  encodedId='access:runtime-profile'
  db.execute("INSERT OR IGNORE INTO users(id,name,email) VALUES(?,?,?)",(encodedId,'Encoded profile','encoded-profile@example.test'))
  db.execute("INSERT OR REPLACE INTO identity_documents VALUES('encoded-doc',?,'id.pdf','application/pdf','fixture-only','2026-01-01',0)",(encodedId,));db.commit()
  self.assertEqual(guest.call('/api/users/access%3Aruntime-profile')[1]['profile']['id'],encodedId)
  self.assertEqual(guest.call('/api/users/access%ZZruntime-profile')[0],400)
  self.assertEqual(guest.call('/api/users/access%2Fruntime-profile')[0],400)
  self.assertEqual(admin.call('/api/admin/identities/access%3Aruntime-profile/review',dict(status='needs_info',reason='Encoded profile review routing',documentId='encoded-doc'))[0],200)
  # Verify review target decoding using an eligible booking redirected solely in this fixture.
  db.execute("UPDATE bookings SET sellerId=? WHERE id=?",(encodedId,bid))
  db.execute("DELETE FROM profile_reviews WHERE bookingId=?",(bid,));db.commit()
  self.assertEqual(renter.call('/api/users/access%3Aruntime-profile/reviews',body)[0],201)
  db.close()
if __name__=='__main__':unittest.main()
