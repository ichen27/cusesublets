"""Isolated API tests for private tour uploads, worker fencing and publication."""
import concurrent.futures
import hashlib
import importlib.util
import json
import os
import unittest
import urllib.error
import urllib.request
import uuid
from urllib.parse import urlsplit
spec=importlib.util.spec_from_file_location('runtime','tests/api-runtime.py');rt=importlib.util.module_from_spec(spec);spec.loader.exec_module(rt)
BASE=os.environ['API_BASE'];TOKEN=os.environ['TOUR_PROCESSOR_TOKEN']
assert urlsplit(BASE).hostname in ('localhost','127.0.0.1') and urlsplit(BASE).port==8936, 'Use only isolated port 8936'

def request(client,path,data=None,headers=None):
 h={'Origin':BASE,**(headers or {})}
 req=urllib.request.Request(BASE+path,data=data,headers=h)
 try:r=client.opener.open(req)
 except urllib.error.HTTPError as error:r=error
 with r:return r.status,r.read()

def processor(path,payload=None,job=None,data=None,extra=None,token=TOKEN):
 h={'Authorization':'Bearer '+token,**(extra or {})}
 if job:h['X-Tour-Claim']=job['claim']
 if payload is not None:data=json.dumps(payload).encode();h['Content-Type']='application/json'
 return request(rt.Client(),'/api/tour-processor/'+path,data,h)

class Tours(unittest.TestCase):
 def setUp(self):
  self.host=rt.Client();self.host.login('host');self.renter=rt.Client();self.renter.login('renter');self.guest=rt.Client()
  self.listing=self.host.call('/api/mine')[1]['listings'][0]['id'];self.base='/api/listings/'+self.listing+'/tours'
  self.host.call('/api/listings/'+self.listing+'/publish',{})
  self.ids=[]
 def tearDown(self):
  for id in self.ids:self.host.call(self.base+'/'+id+'/delete',{})
 def reserve(self):
  data=b'Synthetic archive used to test transport only';id=str(uuid.uuid4()).upper();self.ids.append(id)
  payload={'id':id,'name':'Synthetic tour','size':len(data),'sha256':hashlib.sha256(data).hexdigest()}
  status,result=self.host.call(self.base,payload);self.assertEqual(status,201,result);return id,data,payload
 def test_private_upload_retry_publication_and_deletion_fence(self):
  id,data,payload=self.reserve();route=self.base+'/'+id
  self.assertEqual(self.guest.call(self.base,payload)[0],401);self.assertEqual(self.renter.call(self.base,payload)[0],403)
  self.assertEqual(self.guest.call(route)[0],404)
  self.assertEqual(self.host.call(route+'/visibility',{'published':True})[0],409)
  self.assertEqual(request(self.host,route+'/upload',b'wrong')[0],400)
  self.assertEqual(request(self.host,route+'/upload',data)[0],200)
  self.assertEqual(request(self.host,route+'/upload',data)[0],200)
  self.assertEqual(processor('claim',{},token='wrong')[0],401)
  status,raw=processor('claim',{});self.assertEqual(status,200,raw);job=json.loads(raw)['job'];self.assertEqual(job['id'],id)
  self.assertEqual(processor(id+'/input',job={**job,'claim':str(uuid.uuid4())})[0],409)
  self.assertEqual(processor(id+'/input',job=job),(200,data))
  self.assertEqual(processor(id+'/fail',{'code':'capture_invalid'},job=job)[0],200)
  self.assertEqual(self.host.call(route)[1]['tour']['status'],'failed')
  self.assertEqual(self.renter.call(route+'/retry',{})[0],403)
  self.assertEqual(self.host.call(route+'/retry',{})[0],200)
  newer=json.loads(processor('claim',{})[1])['job'];self.assertNotEqual(newer['claim'],job['claim'])
  self.assertEqual(processor(id+'/heartbeat',{},job=job)[0],409)
  self.assertEqual(processor(id+'/heartbeat',{},job=newer)[0],200)
  # The trusted processor validates PLY before calling complete; this checks its bounded transport contract.
  model=b'Synthetic model transport';meta={'method':'Synthetic transport test','views':30,'gaussians':1,'camera':{'position':[0,0,0],'target':[0,0,-1],'up':[0,1,0]}}
  headers={'X-Tour-Result':json.dumps(meta),'X-File-Size':str(len(model)),'X-File-SHA256':hashlib.sha256(model).hexdigest()}
  self.assertEqual(processor(id+'/complete',job=job,data=model,extra=headers)[0],409)
  self.assertEqual(processor(id+'/complete',job=newer,data=model,extra=headers)[0],200)
  self.assertEqual(self.guest.raw(route+'/model')[0],404)
  self.assertEqual(self.host.raw(route+'/model')[2],model)
  self.assertEqual(self.host.call(route+'/visibility',{'published':True})[0],200)
  self.assertEqual(self.guest.raw(route+'/model')[2],model)
  self.host.call('/api/listings/'+self.listing+'/pause',{})
  self.assertEqual(self.guest.raw(route+'/model')[0],404)
  self.host.call('/api/listings/'+self.listing+'/publish',{})
  self.host.call(route+'/visibility',{'published':False})
  self.assertEqual(self.guest.raw(route+'/model')[0],404)
  self.host.call(route+'/delete',{})
  self.assertEqual(self.host.raw(route+'/model')[0],404)
  self.assertEqual(processor(id+'/complete',job=newer,data=model,extra=headers)[0],409)
 def test_simultaneous_upload_and_claim_are_single_winner(self):
  id,data,payload=self.reserve();route=self.base+'/'+id
  with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
   results=list(pool.map(lambda _:request(self.host,route+'/upload',data),range(2)))
  self.assertTrue(all(status==200 for status,_ in results),results)
  with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
   results=list(pool.map(lambda _:processor('claim',{}),range(2)))
  self.assertTrue(all(status==200 for status,_ in results),results)
  jobs=[json.loads(raw)['job'] for _,raw in results];self.assertEqual(sum(j is not None for j in jobs),1)
  job=next(j for j in jobs if j);self.host.call(route+'/delete',{})
  self.assertEqual(processor(id+'/heartbeat',{},job=job)[0],409)
if __name__=='__main__':unittest.main()
