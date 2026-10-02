"""Two-sided discovery integration check. Run only on isolated :8923 demo state."""
import importlib.util, pathlib, unittest, os
spec=importlib.util.spec_from_file_location("runtime",pathlib.Path(__file__).with_name("api-runtime.py"))
runtime=importlib.util.module_from_spec(spec);spec.loader.exec_module(runtime)
Client=runtime.Client

class Discovery(unittest.TestCase):
 def test_requests_matches_and_host_reply(self):
  guest,seeker,host,admin=Client(),Client(),Client(),Client()
  for client,role in [(seeker,"renter"),(host,"host"),(admin,"admin")]: client.login(role)
  self.assertEqual(guest.call("/api/requests")[0],200)
  self.assertEqual(guest.call("/api/requests",{})[0],401)
  payload=dict(title="Looking for a spring room",description="Seeking a furnished room near Syracuse University for spring.",neighborhood="Westcott",maxBudget=950,roomType="Private room",startDate="2027-02-01",endDate="2027-04-01",amenities=["Furnished"])
  self.assertEqual(seeker.call("/api/requests",{**payload,"maxBudget":-1})[0],400)
  code,result=seeker.call("/api/requests",payload);self.assertEqual(code,201,result)
  request_id=result["request"]["id"]
  public=guest.call("/api/requests")[1]["requests"]
  self.assertTrue(any(r["id"]==request_id for r in public))
  self.assertNotIn("email",str(public));self.assertNotIn("phone",str(public))
  mine=seeker.call("/api/requests/mine")[1]["requests"]
  self.assertTrue(any(r["id"]==request_id for r in mine))
  self.assertEqual(host.call("/api/requests/"+request_id,{"status":"paused"})[0],403)
  listing_payload=dict(title="Westcott room for spring",neighborhood="Westcott",address="Near Westcott",price=850,beds=1,baths=1,roomType="Private room",startDate="2027-01-01",endDate="2027-05-01",description="Isolated matching test listing, not a real property.",amenities=["Furnished"],images=[])
  listing_id=host.call("/api/listings",listing_payload)[1]["listing"]["id"]
  self.assertEqual(guest.call("/api/matches?sourceType=request&sourceId="+request_id)[0],401)
  self.assertEqual(host.call("/api/matches?sourceType=request&sourceId="+request_id)[0],403)
  seeker_matches=seeker.call("/api/matches?sourceType=request&sourceId="+request_id)[1]["matches"]
  self.assertTrue(any(m["listing"]["id"]==listing_id for m in seeker_matches))
  host_matches=host.call("/api/matches?sourceType=listing&sourceId="+listing_id)[1]["matches"]
  self.assertTrue(any(m["request"]["id"]==request_id for m in host_matches))
  self.assertEqual(seeker.call("/api/conversations",{"listingId":listing_id,"requestId":request_id})[0],403)
  code,result=host.call("/api/conversations",{"listingId":listing_id,"requestId":request_id});self.assertEqual(code,201,result)
  conversation_id=result["conversation"]["id"]
  detail=seeker.call("/api/conversations/"+conversation_id)[1]
  self.assertEqual(detail["request"]["id"],request_id)
  self.assertEqual(seeker.call("/api/requests/"+request_id,{"status":"paused"})[0],200)
  self.assertFalse(any(r["id"]==request_id for r in guest.call("/api/requests")[1]["requests"]))
  self.assertFalse(any(m["request"]["id"]==request_id for m in host.call("/api/matches?sourceType=listing&sourceId="+listing_id)[1]["matches"]))
  self.assertEqual(host.call("/api/conversations/"+conversation_id)[0],200)
  self.assertEqual(seeker.call("/api/requests/"+request_id,{"status":"active"})[0],200)
  self.assertEqual(guest.call("/api/requests/"+request_id+"/report",{"reason":"Public post needs review"})[0],401)
  self.assertEqual(seeker.call("/api/requests/"+request_id+"/report",{"reason":"I own this post"})[0],400)
  code,result=host.call("/api/requests/"+request_id+"/report",{"reason":"Public post needs review"});self.assertEqual(code,201,result)
  report_id=result["report"]["id"]
  self.assertEqual(host.call("/api/requests/"+request_id+"/report",{"reason":"Repeated report"})[0],409)
  self.assertTrue(any(report["id"]==report_id for report in admin.call("/api/admin")[1]["requestReports"]))
  self.assertEqual(seeker.call("/api/admin/requests/"+request_id+"/status",{"status":"removed","reason":"Bad post"})[0],403)
  self.assertEqual(admin.call("/api/admin/requests/"+request_id+"/status",{"status":"removed","reason":"Test moderation"})[0],200)
  self.assertFalse(any(r["id"]==request_id for r in guest.call("/api/requests")[1]["requests"]))
  self.assertEqual(admin.call("/api/admin/request-reports/"+report_id+"/resolve",{"reason":"Reviewed and removed"})[0],200)

if __name__=="__main__":unittest.main()
