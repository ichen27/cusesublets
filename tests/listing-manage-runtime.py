"""Owner edit/pause/publish checks. Isolated demo runtime only."""
import importlib.util, pathlib, unittest
spec=importlib.util.spec_from_file_location("runtime",pathlib.Path(__file__).with_name("api-runtime.py"))
runtime=importlib.util.module_from_spec(spec);spec.loader.exec_module(runtime)
Client=runtime.Client
class Manage(unittest.TestCase):
 def test_edit_and_pause(self):
  host,renter,guest=Client(),Client(),Client()
  host.login("host");renter.login("renter")
  data=dict(title="Editable test listing",neighborhood="Westcott",address="Near Westcott",price=800,beds=1,baths=1,roomType="Private room",startDate="2027-01-01",endDate="2027-08-01",description="A sample listing for owner edit checks.",amenities=["Furnished"],images=[])
  created=host.call("/api/listings",data)[1]["listing"];key=created["id"]
  self.assertEqual(renter.call("/api/listings/"+key,{"price":850})[0],403)
  self.assertEqual(host.call("/api/listings/"+key,{"price":-1})[0],400)
  status,result=host.call("/api/listings/"+key,{"price":850,"title":"Updated test listing"})
  self.assertEqual(status,200,result)
  self.assertEqual(result["listing"]["price"],850)
  self.assertEqual(result["listing"]["status"],"approved")
  self.assertEqual(result["listing"]["leaseStatus"],created["leaseStatus"])
  self.assertEqual(host.call("/api/listings/"+key+"/pause",{})[0],200)
  self.assertEqual(guest.call("/api/listings/"+key)[0],404)
  self.assertEqual(renter.call("/api/listings/"+key+"/publish",{})[0],403)
  self.assertEqual(host.call("/api/listings/"+key+"/publish",{})[0],200)
  self.assertEqual(guest.call("/api/listings/"+key)[0],200)
if __name__=="__main__":unittest.main()
