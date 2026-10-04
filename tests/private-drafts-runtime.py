"""Private questionnaire and idempotent publication checks against isolated API_BASE."""
import importlib.util,pathlib,unittest,uuid,concurrent.futures
spec=importlib.util.spec_from_file_location("runtime",pathlib.Path(__file__).with_name("api-runtime.py"))
runtime=importlib.util.module_from_spec(spec);spec.loader.exec_module(runtime)
Client=runtime.Client
def member(name):
 c=Client()
 status,result=c.call("/api/auth/signup",{"name":name,"email":uuid.uuid4().hex+"@example.test","password":"LongTestPassword2027!!"})
 assert status==200,result
 return c
class Drafts(unittest.TestCase):
 def test_privacy_revision_delete_and_incomplete_search(self):
  owner,other,guest=member("Draft owner"),member("Other draft owner"),Client()
  self.assertEqual(guest.call("/api/drafts")[0],401)
  payload=dict(kind="search",step=1,revision=0,data={"introduction":"PRIVATE DRAFT ONLY","areas":[],"maxBudget":""})
  status,result=owner.call("/api/drafts/search",payload);self.assertEqual(status,200,result)
  self.assertEqual(result["revision"],1)
  self.assertEqual(other.call("/api/drafts/search")[1]["draft"],None)
  self.assertEqual(other.call("/api/drafts")[1]["drafts"],[])
  self.assertEqual(owner.call("/api/my-search")[1]["search"],None)
  self.assertNotIn("PRIVATE DRAFT ONLY",str(guest.call("/api/searches")[1]))
  self.assertEqual(owner.call("/api/drafts/search",payload)[0],409)
  self.assertEqual(owner.call("/api/drafts/search",{**payload,"revision":1,"data":{"email":"secret@example.test"}})[0],400)
  self.assertEqual(owner.call("/api/drafts/search",{**payload,"revision":1,"data":{"introduction":"x"*501}})[0],400)
  updated=owner.call("/api/drafts/search",{**payload,"revision":1,"step":2})[1]
  self.assertEqual(updated["revision"],2)
  self.assertEqual(owner.call("/api/drafts/search/delete",{"revision":1})[0],409)
  self.assertEqual(owner.call("/api/drafts/search/delete",{"revision":2})[0],200)
  self.assertEqual(owner.call("/api/drafts")[1]["drafts"],[])
  self.assertEqual(owner.call("/api/drafts/search",payload)[0],409) # tombstone prevents stale resurrection
  current=owner.call("/api/drafts/search")[1];self.assertEqual(current,{"draft":None,"revision":3})
  self.assertEqual(owner.call("/api/drafts/search",{**payload,"revision":3})[1]["revision"],4)
 def test_concurrent_revision_and_publication_retry(self):
  owner,other=member("Publisher"),member("Second publisher")
  key=str(uuid.uuid4());path="/api/drafts/"+key
  payload=dict(kind="listing",step=2,revision=0,data={"title":"Private property draft"})
  self.assertEqual(owner.call(path,payload)[0],200)
  with concurrent.futures.ThreadPoolExecutor(2) as executor:
   results=list(executor.map(lambda i:owner.call(path,{**payload,"revision":1,"data":{"title":"Edit "+str(i)}}),range(2)))
  self.assertEqual(sorted(result[0] for result in results),[200,409])
  self.assertEqual(other.call(path)[1]["draft"],None)
  self.assertEqual(other.call(path+"/delete",{"revision":2})[0],409)
  listing=dict(clientPublishId=key,title="Publication retry test",neighborhood="Westcott",address="Near Westcott",price=800,beds=1,baths=1,roomType="Private room",startDate="2027-01-01",endDate="2027-05-31",description="A test of reliable publication retries, not a real listing.",amenities=[],images=[],lat=43.03,lng=-76.13)
  with concurrent.futures.ThreadPoolExecutor(2) as executor:
   results=list(executor.map(lambda _:owner.call("/api/listings",listing),range(2)))
  self.assertTrue(all(r[0] in (200,201) for r in results),results)
  ids={r[1]["listing"]["id"] for r in results};self.assertEqual(len(ids),1)
  retry=owner.call("/api/listings",{**listing,"title":"Accidental retry change"})
  self.assertEqual(retry[1]["listing"]["id"],next(iter(ids)))
  self.assertEqual(retry[1]["listing"]["title"],listing["title"])
  separate=other.call("/api/listings",listing)
  self.assertNotEqual(separate[1]["listing"]["id"],next(iter(ids)))
  self.assertEqual(owner.call("/api/listings",{**listing,"clientPublishId":"bad-key"})[0],400)
if __name__=="__main__":unittest.main()
