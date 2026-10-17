"""Account erasure against isolated local API only; every account created here is synthetic."""
import importlib.util,unittest,uuid,os,json
from urllib.parse import urlsplit
spec=importlib.util.spec_from_file_location('runtime','tests/api-runtime.py');rt=importlib.util.module_from_spec(spec);spec.loader.exec_module(rt)
url=urlsplit(os.environ['API_BASE']);assert url.hostname in ('localhost','127.0.0.1') and url.port==8936
class Deletion(unittest.TestCase):
 def test_account_content_removed_and_other_participant_history_preserved(self):
  owner,other,guest=rt.Client(),rt.Client(),rt.Client();other.login('renter')
  marker='erase-'+uuid.uuid4().hex;email=marker+'@example.test';password='synthetic-long-password'
  status,body=owner.call('/api/auth/signup',dict(name=marker,email=email,password=password));self.assertEqual(status,200,body);uid=body['user']['id']
  payload=dict(title=marker,neighborhood='Westcott',address=marker,price=800,beds=1,baths=1,roomType='Private room',startDate='2027-01-01',endDate='2027-08-01',description=marker,amenities=[],images=[])
  status,result=owner.call('/api/listings',payload);self.assertEqual(status,201,result);key=result['listing']['id']
  self.assertEqual(owner.call('/api/profile',dict(bio=marker,phone='5551234567'))[0],200)
  status,media=owner.upload('/api/listings/'+key+'/media',name='photo.png',mime='image/png',data=b'\x89PNG\r\n\x1a\n');self.assertEqual(status,201,media)
  status,result=other.call('/api/conversations',dict(listingId=key));self.assertEqual(status,201,result);thread=result['conversation']['id']
  self.assertEqual(owner.call('/api/conversations/'+thread+'/messages',dict(body=marker))[0],201)
  self.assertEqual(other.call('/api/conversations/'+thread+'/messages',dict(body='Other participant keeps this message'))[0],201)
  receipt=uuid.uuid4().hex+uuid.uuid4().hex
  self.assertEqual(guest.call('/api/account/delete',dict(receipt=receipt,confirmation='DELETE'))[0],401)
  self.assertEqual(owner.call('/api/account/delete',dict(receipt=receipt,confirmation='no'))[0],400)
  status,result=owner.call('/api/account/delete',dict(receipt=receipt,confirmation='DELETE'));self.assertEqual(status,202,result)
  self.assertIsNone(owner.call('/api/session')[1]['user'])
  self.assertEqual(owner.call('/api/mine')[0],401)
  self.assertEqual(owner.call('/api/auth/login',dict(email=email,password=password))[0],401)
  self.assertEqual(guest.call('/api/listings/'+key)[0],404)
  self.assertEqual(guest.call('/api/users/'+uid)[0],404)
  self.assertEqual(guest.raw(media['url'])[0],404)
  status,history=other.call('/api/conversations/'+thread);self.assertEqual(status,200,history)
  self.assertNotIn(marker,json.dumps(history));self.assertIn('Other participant keeps this message',json.dumps(history));self.assertIn('Deleted member',json.dumps(history))
  for field in ['lat','lng','sample']:self.assertIn(field,history['listing'])
  status,result=guest.call('/api/account/deletion/status',dict(receipt=receipt));self.assertEqual(status,200,result);self.assertEqual(result['status'],'processing')
  self.assertEqual(set(result),{'status','requestedAt','completedAt'})
  self.assertEqual(guest.call('/api/account/deletion/status',dict(receipt=uuid.uuid4().hex+uuid.uuid4().hex))[0],404)
if __name__=='__main__':unittest.main()
