"""Blocking and private member reports on the isolated local API."""
import importlib.util,unittest,uuid,os,json
from urllib.parse import urlsplit
spec=importlib.util.spec_from_file_location('runtime','tests/api-runtime.py');rt=importlib.util.module_from_spec(spec);spec.loader.exec_module(rt)
u=urlsplit(os.environ['API_BASE']);assert u.hostname in ('localhost','127.0.0.1') and u.port==8936
class Blocks(unittest.TestCase):
 def test_block_hides_content_and_fences_new_contact_but_keeps_history(self):
  a,b,admin,guest=rt.Client(),rt.Client(),rt.Client(),rt.Client();admin.login('admin')
  ids=[]
  for c in (a,b):
   status,r=c.call('/api/auth/signup',dict(email=uuid.uuid4().hex+'@example.test',name='Block test',password='synthetic-long-password'));self.assertEqual(status,200,r);ids.append(r['user']['id'])
  payload=dict(title='Block test listing',neighborhood='Westcott',address='Approximate test area',price=800,beds=1,baths=1,roomType='Private room',startDate='2027-01-01',endDate='2027-08-01',description='Synthetic block test',amenities=[],images=[],lat=43.04,lng=-76.13)
  key=a.call('/api/listings',payload)[1]['listing']['id'];thread=b.call('/api/conversations',dict(listingId=key))[1]['conversation']['id']
  self.assertEqual(b.call('/api/conversations/'+thread+'/messages',dict(body='Earlier message'))[0],201)
  social='/api/social/listing/'+key
  self.assertEqual(b.call(social+'/comments',dict(body='Earlier public comment',clientId=uuid.uuid4().hex))[0],201)
  area=dict(id='campus',label='Campus',points=[dict(lat=43.01,lng=-76.16),dict(lat=43.01,lng=-76.10),dict(lat=43.07,lng=-76.10),dict(lat=43.07,lng=-76.16)])
  search=dict(startDate='2027-02-01',endDate='2027-04-01',maxBudget=950,roomType='Any',requiredAmenities=[],preferredAmenities=[],areas=[area],introduction='Synthetic blocked search',status='active')
  status,result=b.call('/api/my-search',search);self.assertEqual(status,201,result);sid=result['search']['id']
  self.assertEqual(a.call('/api/social/search/'+sid+'/save',dict(saved=True))[0],200)
  self.assertEqual(a.call('/api/searches/'+sid)[0],200)
  self.assertTrue(any(m['search']['id']==sid for m in a.call('/api/matches?sourceType=listing&sourceId='+key)[1]['matches']))
  self.assertTrue(any(m['listing']['id']==key for m in b.call('/api/matches?sourceType=search&sourceId='+sid)[1]['matches']))
  self.assertEqual(guest.call('/api/members/'+ids[1]+'/block',{})[0],401)
  self.assertEqual(a.call('/api/members/'+ids[1]+'/block',{})[0],200)
  self.assertEqual(a.call('/api/blocked-members')[1]['members'][0]['id'],ids[1])
  self.assertEqual(b.call('/api/listings/'+key)[0],404)
  self.assertEqual(a.call('/api/searches/'+sid)[0],404)
  self.assertEqual(a.call('/api/requests/'+sid)[0],404)
  self.assertFalse(any(m['search']['id']==sid for m in a.call('/api/matches?sourceType=listing&sourceId='+key)[1]['matches']))
  self.assertFalse(any(m['listing']['id']==key for m in b.call('/api/matches?sourceType=search&sourceId='+sid)[1]['matches']))
  for saved in a.call('/api/social/saved')[1]['items']:
   if saved['targetId']==sid:self.assertEqual(a.call('/api/searches/'+saved['targetId'])[0],404)

  self.assertFalse(any(l['id']==key for l in b.call('/api/listings')[1]['listings']))
  self.assertEqual(b.call('/api/conversations/'+thread+'/messages',dict(body='Blocked message'))[0],403)
  self.assertEqual(a.call('/api/conversations/'+thread+'/messages',dict(body='Also blocked'))[0],403)
  self.assertEqual(b.call(social+'/comments',dict(body='Blocked comment',clientId=uuid.uuid4().hex))[0],403)
  self.assertEqual(a.call(social+'/comments')[1]['comments'],[])
  self.assertEqual(b.call('/api/conversations/'+thread)[0],200)
  status,result=a.call('/api/members/'+ids[1]+'/report',dict(reason='Synthetic harassment report'));self.assertEqual(status,201,result)
  self.assertEqual(guest.call('/api/admin')[0],401)
  report=next(r for r in admin.call('/api/admin')[1]['memberReports'] if r['targetId']==ids[1]);self.assertEqual(report['status'],'open')
  self.assertEqual(admin.call('/api/admin/member-reports/'+report['id']+'/resolve',dict(reason='Reviewed synthetic test'))[0],200)
  self.assertEqual(a.call('/api/members/'+ids[1]+'/unblock',{})[0],200)
  self.assertEqual(b.call('/api/conversations/'+thread+'/messages',dict(body='Contact restored'))[0],201)
if __name__=='__main__':unittest.main()
