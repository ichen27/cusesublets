"""Run only against the isolated iPhone demo runtime. No operational state."""
import importlib.util, unittest, uuid, urllib.request, urllib.error, json, os, hashlib, base64
spec=importlib.util.spec_from_file_location('runtime','tests/api-runtime.py');rt=importlib.util.module_from_spec(spec);spec.loader.exec_module(rt)
class NoRedirect(urllib.request.HTTPRedirectHandler):
 def redirect_request(self,*args,**kwargs): return None
class IPhoneRuntime(unittest.TestCase):
 def test_scan_privacy_publication_and_revocation(self):
  guest,host,renter=rt.Client(),rt.Client(),rt.Client();host.login('host');renter.login('renter')
  listing=host.call('/api/mine')[1]['listings'][0];key=listing['id'];base='/api/listings/'+key+'/scans'
  original=(listing['leaseStatus'],listing['permissionStatus'],listing['hostIdentity'])
  wall=dict(kind='wall',dimensions=[4,2.5,0],transform=[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1])
  payload=dict(id=str(uuid.uuid4()),name='Synthetic test room',layout=dict(version=1,elements=[wall]))
  self.assertEqual(guest.call(base,payload)[0],401);self.assertEqual(renter.call(base,payload)[0],403)
  status,data=host.call(base,payload);self.assertEqual(status,201,data);scan=data['scan'];self.assertFalse(scan['published'])
  self.assertEqual(host.call(base,payload)[0],200)
  self.assertEqual(host.call(base,{**payload,'name':'changed'})[0],409)
  self.assertEqual(host.call(base,{**payload,'id':str(uuid.uuid4()),'layout':dict(version=1,elements=[{**wall,'dimensions':[-1,2,0]}])})[0],400)
  self.assertFalse(any(x['id']==scan['id'] for x in guest.call(base)[1].get('scans',[])))
  route=base+'/'+scan['id']
  self.assertEqual(renter.call(route+'/visibility',dict(published=True))[0],403)
  self.assertEqual(host.call(route+'/visibility',dict(published='yes'))[0],400)
  self.assertEqual(host.call(route+'/visibility',dict(published=True))[0],200)
  # Ensure listing itself is public before testing guest visibility.
  if listing['status']!='approved':host.call('/api/listings/'+key+'/publish',{})
  self.assertTrue(any(x['id']==scan['id'] for x in guest.call(base)[1]['scans']))
  host.call('/api/listings/'+key+'/pause',{})
  self.assertEqual(guest.call(base)[0],404)
  self.assertEqual(host.call(base)[0],200)
  host.call('/api/listings/'+key+'/publish',{})
  self.assertEqual(host.call(route+'/visibility',dict(published=False))[0],200)
  self.assertFalse(any(x['id']==scan['id'] for x in guest.call(base)[1]['scans']))
  updated=host.call('/api/listings/'+key)[1]['listing'];self.assertEqual(original,(updated['leaseStatus'],updated['permissionStatus'],updated['hostIdentity']))
  self.assertEqual(host.call(route+'/delete',{})[0],200)
  self.assertEqual(host.call(route+'/visibility',dict(published=True))[0],404)
 def test_place_can_be_created_unpublished_and_published_later(self):
  import datetime
  guest,host=rt.Client(),rt.Client();host.login('host')
  day=lambda n:(datetime.date.today()+datetime.timedelta(days=n)).isoformat()
  body=dict(title='Synthetic unpublished place',neighborhood='Westcott',address='Approximate synthetic test area',price=800,beds=1,baths=1,roomType='Private room',startDate=day(30),endDate=day(180),description='Synthetic runtime listing only. Not an available property.',amenities=[],images=[],lat=43.04,lng=-76.13)
  self.assertEqual(host.call('/api/listings',{**body,'publish':'no'})[0],400)
  status,data=host.call('/api/listings',{**body,'publish':False,'clientPublishId':str(uuid.uuid4())});self.assertEqual(status,201,data)
  place=data['listing'];self.assertEqual(place['status'],'pending')
  route='/api/listings/'+place['id']
  self.assertEqual(guest.call(route)[0],404)
  self.assertNotIn(place['id'],[l['id'] for l in guest.call('/api/listings')[1]['listings']])
  self.assertEqual(host.call(route)[0],200)
  status,data=host.call(route+'/publish',{});self.assertEqual(status,200,data);self.assertEqual(data['listing']['status'],'approved')
  self.assertIn(place['id'],[l['id'] for l in guest.call('/api/listings')[1]['listings']])
  # Leaving `publish` out still publishes at once, as before.
  status,data=host.call('/api/listings',body);self.assertEqual(status,201,data);self.assertEqual(data['listing']['status'],'approved')
 def test_mobile_pkce_replay_and_logout(self):
  host=rt.Client();host.login('host')
  verifier='a'*64;challenge=base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip('=')
  state=str(uuid.uuid4());base=os.environ.get('API_BASE','http://127.0.0.1:8917')
  # Reuse the client's isolated demo cookie, but don't follow the custom-scheme redirect.
  request=urllib.request.Request(base+'/api/login?mobile_challenge='+challenge+'&state='+state)
  next(h.cookiejar for h in host.opener.handlers if isinstance(h,urllib.request.HTTPCookieProcessor)).add_cookie_header(request)
  try:urllib.request.build_opener(NoRedirect).open(request)
  except urllib.error.HTTPError as e:
   self.assertEqual(e.code,302);location=e.headers['Location'];e.close()
  from urllib.parse import urlparse,parse_qs
  query=parse_qs(urlparse(location).query);self.assertEqual(query['state'],[state]);code=query['code'][0]
  phone=rt.Client();self.assertEqual(phone.call('/api/auth/mobile',dict(code=code,verifier='b'*64))[0],401)
  self.assertEqual(phone.call('/api/auth/mobile',dict(code=code,verifier=verifier))[0],200)
  self.assertEqual(phone.call('/api/session')[1]['user']['id'],'demo-host')
  self.assertEqual(phone.call('/api/auth/mobile',dict(code=code,verifier=verifier))[0],401)
  self.assertEqual(phone.call('/api/logout',{})[0],200);self.assertIsNone(phone.call('/api/session')[1]['user'])
if __name__=='__main__':unittest.main()
