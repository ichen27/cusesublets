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
  self.assertEqual(owner.call("/api/requests",SEARCH)[0],410)
  self.assertEqual(owner.call("/api/requests/"+sid,SEARCH)[0],410)
  self.assertEqual(owner.call("/api/my-search/status",{"status":"paused"})[0],200)
  self.assertFalse(any(s["id"]==sid for s in guest.call("/api/searches")[1]["searches"]))
  self.assertEqual(owner.call("/api/my-search/status",{"status":"active"})[1]["search"]["id"],sid)

if __name__=="__main__":unittest.main()
