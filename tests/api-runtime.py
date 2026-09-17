"""Local integration check. Start wrangler :8789 with APP_ENV=development; apply schema+seed first."""
import json, urllib.request, urllib.error, http.cookiejar, unittest, os
BASE=os.environ.get('API_BASE','http://localhost:8789')
class Client:
 def __init__(self):self.opener=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
 def call(self,path,data=None,origin=None):
  req=urllib.request.Request(BASE+path,data=None if data is None else json.dumps(data).encode(),headers={'Origin':origin or BASE,'Content-Type':'application/json'})
  try:r=self.opener.open(req)
  except urllib.error.HTTPError as e:r=e
  return r.status,json.loads(r.read())
 def upload(self,path,kind='lease',name='test.pdf',mime='application/pdf',data=b'%PDF-1.4 sample-only'):
  boundary='cusesublets-test-boundary'
  value=(f'--{boundary}\r\nContent-Disposition: form-data; name="kind"\r\n\r\n{kind}\r\n--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{name}"\r\nContent-Type: {mime}\r\n\r\n').encode()+data+f'\r\n--{boundary}--\r\n'.encode()
  req=urllib.request.Request(BASE+path,data=value,headers={'Origin':BASE,'Content-Type':'multipart/form-data; boundary='+boundary})
  try:r=self.opener.open(req)
  except urllib.error.HTTPError as e:r=e
  return r.status,json.loads(r.read())
 def raw(self,path):
  try:r=self.opener.open(BASE+path)
  except urllib.error.HTTPError as e:r=e
  return r.status,r.headers,r.read()
 def login(self,role):assert self.call('/api/dev/session',{'role':role})[0]==200
class API(unittest.TestCase):
 def test_full_trust_flow(self):
  guest=Client();renter=Client();host=Client();admin=Client()
  self.assertEqual(guest.call('/api/listings',{})[0],401)
  self.assertEqual(guest.call('/api/dev/session',{'role':'admin'},'https://evil.example')[0],403)
  renter.login('renter');host.login('host');admin.login('admin')
  self.assertEqual(renter.call('/api/admin')[0],403)
  self.assertEqual(guest.call('/api/listings/pending-ostrom')[0],404)
  self.assertEqual(host.call('/api/listings/pending-ostrom')[0],200)
  payload=dict(title='Runtime test listing',neighborhood='Westcott',address='Near Westcott',price=800,beds=1,baths=1,roomType='Private room',startDate='2027-01-01',endDate='2027-08-01',description='Integration test only, not a real property.',amenities=[],images=[])
  status,result=host.call('/api/listings',payload);self.assertEqual(status,201,result);key=result['listing']['id']
  self.assertEqual(host.upload('/api/listings/'+key+'/documents','identity')[0],400)
  status,result=host.upload('/api/listings/'+key+'/documents');self.assertEqual(status,201,result);doc=result['document']['id']
  self.assertEqual(guest.raw('/api/documents/'+doc)[0],401)
  self.assertEqual(renter.raw('/api/documents/'+doc)[0],403)
  status,headers,data=admin.raw('/api/documents/'+doc);self.assertEqual(status,200);self.assertEqual(headers['Cache-Control'],'no-store');self.assertIn('attachment',headers['Content-Disposition'])
  status,result=host.upload('/api/listings/'+key+'/media',name='photo.png',mime='image/png',data=b'\x89PNG\r\n\x1a\n');self.assertEqual(status,201,result);media=result['url']
  self.assertEqual(guest.raw(media)[0],404);self.assertEqual(host.raw(media)[0],200)
  offer=dict(listingId=key,amount=700,startDate='2027-02-01',endDate='2027-03-01')
  self.assertEqual(renter.call('/api/offers',offer)[0],404)
  review=dict(status='approved',leaseStatus='verified',permissionStatus='verified',reason='Test-only reviewed supporting documents')
  self.assertEqual(admin.call('/api/admin/listings/'+key+'/review',review)[0],200)
  self.assertEqual(guest.raw(media)[0],200)
  self.assertEqual(host.call('/api/offers',offer)[0],400)
  self.assertEqual(renter.call('/api/offers',{**offer,'amount':-1})[0],400)
  self.assertEqual(renter.call('/api/offers',{**offer,'startDate':'2027-02-30'})[0],400)
  status,result=renter.call('/api/offers',offer);self.assertEqual(status,201,result);oid=result['offer']['id']
  self.assertEqual(renter.call('/api/offers/'+oid+'/accept',{})[0],403)
  self.assertEqual(admin.call('/api/admin/users/demo-host/review',dict(identity='needs_info',reason='Test identity gate'))[0],200)
  self.assertEqual(host.call('/api/offers/'+oid+'/accept',{})[0],409)
  self.assertEqual(admin.call('/api/admin/users/demo-host/review',dict(identity='verified',reason='Restore sample identity review'))[0],200)
  status,result=host.call('/api/offers/'+oid+'/accept',{});self.assertEqual(status,201,result);bid=result['booking']['id'];path='/api/bookings/'+bid+'/action'
  oid2=renter.call('/api/offers',offer)[1]['offer']['id']
  self.assertEqual(host.call('/api/offers/'+oid2+'/accept',{})[0],409)
  self.assertEqual(renter.call(path,dict(action='pay'))[0],409)
  self.assertEqual(renter.call(path,dict(action='sign'))[0],200)
  self.assertEqual(host.call(path,dict(action='sign'))[0],200)
  self.assertEqual(host.call(path,dict(action='pay'))[0],403)
  status,result=renter.call(path,dict(action='pay'));self.assertEqual(status,200,result);self.assertEqual(result['booking']['paymentStatus'],'demo_paid')
  self.assertEqual(renter.call(path,dict(action='confirm-move-in'))[0],409)
  status,result=renter.call(path,dict(action='dispute',reason='Test issue requiring review'));self.assertEqual(status,200);self.assertFalse(result['booking']['payoutEligible']);self.assertIn('Open dispute',result['booking']['payoutBlockers'])
  self.assertEqual(admin.call('/api/admin/bookings/'+bid+'/resolve',dict(reason=''))[0],400)
  self.assertEqual(admin.call('/api/admin/bookings/'+bid+'/resolve',dict(reason='Test dispute resolved by support'))[0],200)
  review['status']='paused';self.assertEqual(admin.call('/api/admin/listings/'+key+'/review',review)[0],200)
  self.assertEqual(guest.call('/api/listings/'+key)[0],404)
  self.assertTrue(any(x['targetId']==bid for x in admin.call('/api/admin')[1]['audit']))
  self.assertEqual(renter.call('/api/logout',{})[0],200);self.assertIsNone(renter.call('/api/session')[1]['user'])
if __name__=='__main__':unittest.main()
