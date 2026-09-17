import importlib.util, unittest
spec = importlib.util.spec_from_file_location("runtime", "tests/api-runtime.py")
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)
Client = runtime.Client

class Publish(unittest.TestCase):
    def test_owner_publish(self):
        guest, host, other = Client(), Client(), Client()
        host.login("host")
        other.login("renter")
        path = "/api/listings/publish-pending/publish"
        self.assertEqual(guest.call(path, {})[0], 401)
        self.assertEqual(other.call(path, {})[0], 403)
        self.assertEqual(guest.call("/api/listings/publish-pending")[0], 404)
        status, result = host.call(path, {})
        self.assertEqual(status, 200, result)
        listing = result["listing"]
        self.assertEqual(listing["status"], "approved")
        for key in ["hostIdentity", "leaseStatus", "permissionStatus"]:
            self.assertEqual(listing[key], "pending")
        self.assertEqual(guest.call("/api/listings/publish-pending")[0], 200)
        self.assertIn("publish-pending", [l["id"] for l in guest.call("/api/listings")[1]["listings"]])
        self.assertEqual(host.call(path, {})[0], 200) # safe retry
        for key in ["publish-paused", "publish-rejected", "publish-needs-info", "publish-held"]:
            self.assertEqual(host.call("/api/listings/" + key + "/publish", {})[0], 409, key)
        self.assertEqual(host.call(path, {}, origin="https://evil.example")[0], 403)

if __name__ == "__main__":
    unittest.main()
