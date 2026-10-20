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
