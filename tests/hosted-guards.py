"""Run against the existing mini staging service; never starts another runtime."""
import json, os, unittest, urllib.request, urllib.error
BASE = os.environ.get("API_BASE", "http://127.0.0.1:8918")
ORIGIN = "http://app-cusesublets.chenagent.com"  # Wrangler rewrites same-host HTTPS Origin locally.
def request(path, data=None, headers=None):
    req = urllib.request.Request(BASE + path, data=None if data is None else json.dumps(data).encode(), headers=headers or {})
    try:
        with urllib.request.urlopen(req) as res: return res.status, json.load(res)
    except urllib.error.HTTPError as err:
        with err: return err.code, json.load(err)
class HostedGuards(unittest.TestCase):
    def test_no_demo_identity(self):
        status, body = request("/api/session")
        self.assertEqual(status, 200)
        self.assertEqual((body["user"],body["demo"],body["staging"]),(None,False,True))
        self.assertEqual(request("/api/dev/session", {"role":"admin"}, {"Origin":ORIGIN})[0],404)
    def test_private_endpoints_need_signed_identity(self):
        for endpoint in ["/api/conversations","/api/chat-documents/not-a-document","/api/mine","/api/messages","/api/offers","/api/bookings","/api/admin/overview"]:
            self.assertEqual(request(endpoint,headers={"Cf-Access-Authenticated-User-Email":"ivan27chen@gmail.com"})[0],401,endpoint)
    def test_forged_token_rejected(self):
        self.assertEqual(request("/api/session",headers={"Cf-Access-Jwt-Assertion":"invalid"})[0],401)
    def test_mutations_require_identity_and_exact_origin(self):
        for endpoint in ["/api/conversations","/api/messages","/api/offers","/api/listings"]:
            self.assertEqual(request(endpoint,{}, {"Origin":ORIGIN})[0],401)
            self.assertEqual(request(endpoint,{}, {"Origin":"https://attacker.example"})[0],403)
            self.assertEqual(request(endpoint,{}, {"Origin":ORIGIN,"Sec-Fetch-Site":"cross-site"})[0],403)
    def test_pending_listing_not_public(self):
        status, body=request("/api/listings")
        self.assertEqual(status,200)
        self.assertTrue(all(l["status"]=="approved" for l in body["listings"]))
if __name__ == "__main__": unittest.main()
