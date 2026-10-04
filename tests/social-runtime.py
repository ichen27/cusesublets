"""Social API acceptance on an isolated seeded runtime; never run against member data."""
import importlib.util,pathlib,unittest,uuid
spec=importlib.util.spec_from_file_location('api_runtime',pathlib.Path(__file__).with_name('api-runtime.py'));m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);Client=m.Client
class SocialRuntime(unittest.TestCase):
 def test_public_threads_private_saves_and_moderation(self):
  guest=Client();member=Client();host=Client();admin=Client()
  member.login('renter');host.login('host');admin.login('admin')
  payload=dict(title='Social acceptance '+uuid.uuid4().hex[:6],neighborhood='Westcott',address='Near Westcott',lat=43.042,lng=-76.126,price=800,beds=1,baths=1,roomType='Private room',startDate='2027-01-01',endDate='2027-08-01',description='Integration fixture only, never a real property.',amenities=[],images=[])
  status,response=host.call('/api/listings',payload);self.assertEqual(status,201,response);listing=response['listing']['id'];post='/api/social/listing/'+listing
  self.assertEqual(guest.call(post)[0],200)
  self.assertEqual(guest.call(post+'/like',{'liked':True})[0],401)
  self.assertEqual(member.call(post+'/like',{'liked':True},'https://evil.example')[0],403)
  self.assertEqual(member.call(post+'/like',{'liked':True})[0],200)
  self.assertEqual(member.call(post+'/like',{'liked':True})[0],200)
  self.assertEqual(guest.call(post)[1]['likeCount'],1);self.assertFalse(guest.call(post)[1]['liked']);self.assertTrue(member.call(post)[1]['liked'])
  self.assertEqual(member.call(post+'/save',{'saved':True})[0],200)
  self.assertEqual(guest.call('/api/social/saved')[0],401)
  self.assertIn(listing,[x['targetId'] for x in member.call('/api/social/saved')[1]['items']]);self.assertNotIn(listing,[x['targetId'] for x in host.call('/api/social/saved')[1]['items']]);self.assertFalse(host.call(post)[1]['saved'])
  data=dict(body='<script>not rendered</script> public text',clientId=uuid.uuid4().hex)
  status,response=member.call(post+'/comments',data);self.assertEqual(status,201,response);comment=response['comment']['id']
  self.assertEqual(member.call(post+'/comments',data)[1]['comment']['id'],comment)
  self.assertEqual(member.call(post+'/comments',{**data,'body':'different'})[0],409)
  self.assertEqual(guest.call(post)[1]['commentCount'],1)
  self.assertNotIn('email',response['comment']);self.assertNotIn('moderationReason',response['comment'])
  self.assertEqual(host.call('/api/social/comments/'+comment+'/edit',{'body':'No'})[0],403)
  self.assertEqual(member.call('/api/social/comments/'+comment+'/edit',{'body':'Updated public text'})[0],200)
  status,response=host.call(post+'/comments',dict(body='One level reply',parentId=comment,clientId=uuid.uuid4().hex));self.assertEqual(status,201,response);reply=response['comment']['id']
  self.assertEqual(member.call(post+'/comments',dict(body='Nested',parentId=reply,clientId=uuid.uuid4().hex))[0],409)
  self.assertEqual(host.call('/api/social/comments/'+comment+'/report',{'reason':'Please review this test comment'})[0],200)
  self.assertEqual(member.call('/api/social/moderation')[0],403)
  reports=admin.call('/api/social/moderation')[1]['reports'];report=next(r for r in reports if r['commentId']==comment)
  self.assertEqual(admin.call('/api/social/comments/'+comment+'/moderate',{'removed':True,'reason':'Test removal'})[0],200)
  thread=guest.call(post+'/comments')[1]['comments'];c=next(x for x in thread if x['id']==comment);self.assertTrue(c['unavailable']);self.assertEqual(c['body'],'Comment unavailable');self.assertIsNone(c['authorId'])
  self.assertEqual(admin.call('/api/social/comments/'+comment+'/moderate',{'removed':False,'reason':'Test restoration'})[0],200)
  self.assertEqual(admin.call('/api/social/reports/'+report['id']+'/resolve',{'reason':'Reviewed fixture'})[0],200)
  self.assertEqual(member.call('/api/social/comments/'+comment+'/delete',{})[0],200)
  self.assertEqual(admin.call('/api/social/comments/'+comment+'/moderate',{'removed':False,'reason':'Cannot resurrect author deletion'})[0],409)
  self.assertEqual(host.call('/api/listings/'+listing+'/pause',{})[0],200)
  self.assertEqual(guest.call(post)[0],404);self.assertEqual(guest.call(post+'/comments')[0],404);self.assertEqual(member.call(post+'/like',{'liked':True})[0],404)
  self.assertEqual(member.call(post+'/comments',dict(body='Stale post',clientId=uuid.uuid4().hex))[0],404)
  self.assertFalse(next(x for x in member.call('/api/social/saved')[1]['items'] if x['targetId']==listing)['available'])
  self.assertEqual(member.call(post+'/save',{'saved':False})[0],200)
  area={"id":"near-campus","label":"Near campus","points":[{"lat":43.01,"lng":-76.16},{"lat":43.01,"lng":-76.10},{"lat":43.07,"lng":-76.10},{"lat":43.07,"lng":-76.16}]}
  search=dict(startDate='2027-02-01',endDate='2027-04-01',maxBudget=950,roomType='Any',requiredAmenities=[],preferredAmenities=[],areas=[area],introduction='Social search fixture',status='active')
  status,response=member.call('/api/my-search',search);self.assertIn(status,[200,201],response);sid=response['search']['id'];searchpost='/api/social/search/'+sid
  self.assertEqual(host.call(searchpost+'/like',{'liked':True})[0],200)
  self.assertEqual(host.call(searchpost+'/save',{'saved':True})[0],200)
  self.assertEqual(host.call(searchpost+'/comments',dict(body='Search discussion',clientId=uuid.uuid4().hex))[0],201)
  self.assertEqual(member.call('/api/my-search/status',{'status':'paused'})[0],200)
  self.assertEqual(guest.call(searchpost)[0],404)
  self.assertEqual(host.call(searchpost+'/comments',dict(body='Stale search',clientId=uuid.uuid4().hex))[0],404)
  self.assertEqual(member.call('/api/my-search/status',{'status':'active'})[0],200)
  restored=guest.call(searchpost)[1];self.assertEqual(restored['likeCount'],1);self.assertEqual(restored['commentCount'],1)

if __name__=='__main__':unittest.main()
