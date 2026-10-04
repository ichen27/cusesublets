"""Profile search flow against isolated Wrangler state. Set API_BASE to :8925."""
import importlib.util, pathlib, unittest, uuid
spec=importlib.util.spec_from_file_location("runtime",pathlib.Path(__file__).with_name("api-runtime.py"))
runtime=importlib.util.module_from_spec(spec);spec.loader.exec_module(runtime)
Client=runtime.Client

AREA={"id":"campus","label":"Near campus","points":[
 {"lat":43.01,"lng":-76.16},{"lat":43.01,"lng":-76.10},
 {"lat":43.07,"lng":-76.10},{"lat":43.07,"lng":-76.16}]}
SEARCH=dict(startDate="2027-02-01",endDate="2027-04-01",minBudget=700,
 maxBudget=950,roomType="Private room",requiredAmenities=["Furnished"],
 preferredAmenities=["Wi-Fi"],areas=[AREA],introduction="Looking for a spring room.")

class HousingSearchFlow(unittest.TestCase):
 def test_owner_search_is_unique_private_when_off_and_public_when_on(self):
  guest,owner=Client(),Client()
  email="search-"+uuid.uuid4().hex+"@example.test"
  self.assertEqual(owner.call("/api/auth/signup",{"name":"Search Tester","email":email,"password":"VeryLongTestPassword2027!"})[0],200)
  self.assertEqual(guest.call("/api/my-search")[0],401)
  self.assertEqual(owner.call("/api/my-search")[1]["search"],None)
  # Each account has its own row; the renter creates only one stable row.
  status,result=owner.call("/api/my-search",SEARCH);self.assertEqual(status,201,result)
  first=result["search"];sid=first["id"];created=first["createdAt"]
  self.assertEqual(first["status"],"paused")
  self.assertFalse(any(s["id"]==sid for s in guest.call("/api/searches")[1]["searches"]))
  bad={**SEARCH,"areas":[{**AREA,"points":[AREA["points"][0],AREA["points"][2],AREA["points"][1],AREA["points"][3]]}]}
  self.assertEqual(owner.call("/api/my-search",bad)[0],400)
  self.assertEqual(owner.call("/api/my-search")[1]["search"]["id"],sid)
  status,result=owner.call("/api/my-search",{**SEARCH,"introduction":"Edited public introduction"})
  self.assertEqual(status,200,result)
  self.assertEqual(result["search"]["id"],sid)
  self.assertEqual(result["search"]["createdAt"],created)
  self.assertEqual(owner.call("/api/my-search/status",{"status":"active"})[0],200)
  public=guest.call("/api/searches")[1]["searches"]
  self.assertEqual(len([s for s in public if s["id"]==sid]),1)
  self.assertNotIn("email",str(public));self.assertNotIn("phone",str(public))
  self.assertNotIn("documents",str(public))
  self.assertEqual(guest.call("/api/requests",{})[0],401)
  atomic=owner.call("/api/my-search",{**SEARCH,"introduction":"Saved privately","status":"paused"})
  self.assertEqual(atomic[0],200,atomic)
  self.assertEqual(atomic[1]["search"]["status"],"paused")
  self.assertFalse(any(s["id"]==sid for s in guest.call("/api/searches")[1]["searches"]))
  owner.call("/api/my-search/status",{"status":"active"})
  self.assertEqual(owner.call("/api/requests",SEARCH)[0],410)
  self.assertEqual(owner.call("/api/requests/"+sid,SEARCH)[0],410)
  self.assertEqual(owner.call("/api/my-search/status",{"status":"paused"})[0],200)
  self.assertFalse(any(s["id"]==sid for s in guest.call("/api/searches")[1]["searches"]))
  self.assertEqual(owner.call("/api/my-search/status",{"status":"active"})[1]["search"]["id"],sid)

 def test_both_match_directions_contact_and_moderation(self):
  guest,owner,host,admin=Client(),Client(),Client(),Client()
  email="match-"+uuid.uuid4().hex+"@example.test"
  self.assertEqual(owner.call("/api/auth/signup",{"name":"Match Tester","email":email,"password":"VeryLongTestPassword2027!"})[0],200)
  host.login("host");admin.login("admin")
  status,result=owner.call("/api/my-search",SEARCH);self.assertEqual(status,201,result)
  sid=result["search"]["id"]
  owner.call("/api/my-search/status",{"status":"active"})
  listing_id="walnut-sunroom"
  self.assertEqual(guest.call("/api/matches?sourceType=search&sourceId="+sid)[0],401)
  self.assertEqual(host.call("/api/matches?sourceType=search&sourceId="+sid)[0],403)
  own_listing=dict(title="My own test room",neighborhood="University Hill",address="Near campus",
    lat=43.04,lng=-76.13,price=800,beds=1,baths=1,roomType="Private room",
    startDate="2027-01-01",endDate="2027-05-01",
    description="Runtime test listing owned by the person searching.",
    amenities=["Furnished"],images=[])
  own=owner.call("/api/listings",own_listing)
  self.assertEqual(own[0],201,own)
  own_id=own[1]["listing"]["id"]
  seeker=owner.call("/api/matches?sourceType=search&sourceId="+sid)
  self.assertEqual(seeker[0],200,seeker)
  self.assertTrue(any(m["listing"]["id"]==listing_id for m in seeker[1]["matches"]))
  self.assertFalse(any(m["listing"]["id"]==own_id for m in seeker[1]["matches"]))
  people=host.call("/api/matches?sourceType=listing&sourceId="+listing_id)
  self.assertEqual(people[0],200,people)
  self.assertEqual(len([m for m in people[1]["matches"] if m["search"]["id"]==sid]),1)
  self.assertEqual(owner.call("/api/conversations",{"listingId":listing_id,"requestId":sid})[0],403)
  status,result=host.call("/api/conversations",{"listingId":listing_id,"requestId":sid})
  self.assertEqual(status,201,result);cid=result["conversation"]["id"]
  self.assertEqual(owner.call("/api/my-search/status",{"status":"paused"})[0],200)
  self.assertEqual(host.call("/api/conversations",{"listingId":listing_id,"requestId":sid})[0],404)
  self.assertEqual(owner.call("/api/conversations/"+cid)[0],200)
  self.assertEqual(host.call("/api/conversations/"+cid)[0],200)
  owner.call("/api/my-search/status",{"status":"active"})
  report=host.call("/api/requests/"+sid+"/report",{"reason":"Review this public search"})
  self.assertEqual(report[0],201,report)
  self.assertEqual(admin.call("/api/admin/requests/"+sid+"/status",{"status":"removed","reason":"Test moderation"})[0],200)
  self.assertFalse(any(x["id"]==sid for x in guest.call("/api/searches")[1]["searches"]))
  self.assertEqual(owner.call("/api/my-search/status",{"status":"active"})[0],409)
  restored=admin.call("/api/admin/requests/"+sid+"/status",{"status":"active","reason":"Restore for owner review"})
  self.assertEqual(restored[0],200,restored)
  self.assertEqual(owner.call("/api/my-search")[1]["search"]["status"],"paused")
  self.assertFalse(any(x["id"]==sid for x in guest.call("/api/searches")[1]["searches"]))

if __name__=="__main__":unittest.main()
