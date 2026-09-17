"""Run only against the isolated password-test staging runtime on port 8922."""
import json, uuid, urllib.request, urllib.error, unittest, sqlite3, pathlib, concurrent.futures
BASE="http://127.0.0.1:8922"
ORIGIN="http://localhost:8922"
STATE=pathlib.Path("/Volumes/SamsungSSD1/tools/cusesublets/.wrangler-password-test/v3/d1/miniflare-D1DatabaseObject")
def sql(query,args=()):
    files=[p for p in STATE.glob("*.sqlite") if p.name!="metadata.sqlite"]
    assert len(files)==1
    with sqlite3.connect(files[0]) as db:
        return db.execute(query,args).fetchall()
def req(path,data=None,cookie="",extra=None):
    headers={"Origin":ORIGIN,"Content-Type":"application/json"}
    if cookie: headers["Cookie"]=cookie
    headers.update(extra or {})
    request=urllib.request.Request(BASE+path,data=None if data is None else json.dumps(data).encode(),headers=headers)
    try: response=urllib.request.urlopen(request)
    except urllib.error.HTTPError as error: response=error
    with response:
        return response.status,json.load(response),response.headers.get("Set-Cookie","")
class PasswordRuntime(unittest.TestCase):
    def test_complete_password_flow(self):
        sql("DELETE FROM auth_limits")
        email="user-"+uuid.uuid4().hex+"@example.test"
        old="runtime example password one"; new="runtime example password two"
        data={"name":"Runtime member","email":email,"password":old,"role":"admin","identity":"verified"}
        status,result,cookie=req("/api/auth/signup",data)
        self.assertEqual(status,200,result)
        self.assertEqual((result["user"]["role"],result["user"]["identity"]),("member","pending"))
        self.assertNotIn("passwordHash",result["user"])
        for flag in ("Secure","HttpOnly","SameSite=Lax","Path=/","Max-Age=28800"):self.assertIn(flag,cookie)
        cookie=cookie.split(";")[0]; uid=result["user"]["id"]
        self.assertEqual(req("/api/auth/status")[0],401)
        self.assertEqual(req("/api/auth/status",cookie=cookie)[1],{"hasPassword":True})
        self.assertEqual(req("/api/auth/signup",data)[0],409)
        self.assertEqual(req("/api/auth/login",{"email":email,"password":"incorrect password value"})[0],401)
        status,result,second=req("/api/auth/login",{"email":email.upper(),"password":old},extra={"Cookie":"CF_Authorization=expired"})
        self.assertEqual(status,200,result);second=second.split(";")[0]
        self.assertEqual(req("/api/session",cookie=cookie+"; CF_Authorization=invalid")[1]["user"]["id"],uid)
        self.assertEqual(req("/api/auth/password",{"currentPassword":"incorrect password value","newPassword":new},cookie)[0],401)
        status,result,fresh=req("/api/auth/password",{"currentPassword":old,"newPassword":new},cookie)
        self.assertEqual(status,200,result);fresh=fresh.split(";")[0]
        self.assertIsNone(req("/api/session",cookie=cookie)[1]["user"])
        self.assertIsNone(req("/api/session",cookie=second)[1]["user"])
        self.assertEqual(req("/api/auth/login",{"email":email,"password":old})[0],401)
        self.assertEqual(req("/api/auth/login",{"email":email,"password":new})[0],200)
        self.assertEqual(req("/api/logout",{},fresh+"; CF_Authorization=expired")[0],200)
        self.assertIsNone(req("/api/session",cookie=fresh)[1]["user"])
        sql("UPDATE users SET suspended=1 WHERE id=?",(uid,))
        self.assertEqual(req("/api/auth/login",{"email":email,"password":new})[0],401)
    def test_concurrent_login_and_rotation(self):
        sql("DELETE FROM auth_limits")
        email="race-"+uuid.uuid4().hex+"@example.test"
        old="race test original password";new="race test updated password"
        status,result,cookie=req("/api/auth/signup",{"name":"Race","email":email,"password":old})
        self.assertEqual(status,200,result);uid=result["user"]["id"];cookie=cookie.split(";")[0]
        with concurrent.futures.ThreadPoolExecutor() as pool:
            login=pool.submit(req,"/api/auth/login",{"email":email,"password":old})
            rotate=pool.submit(req,"/api/auth/password",{"currentPassword":old,"newPassword":new},cookie)
            loginResult,rotationResult=login.result(),rotate.result()
        self.assertEqual(rotationResult[0],200,rotationResult)
        self.assertIn(loginResult[0],(200,401))
        if loginResult[0]==200:
            self.assertIsNone(req("/api/session",cookie=loginResult[2].split(";")[0])[1]["user"])
        self.assertEqual(sql("SELECT count(*) FROM password_sessions WHERE userId=?",(uid,))[0][0],1)
    def test_guards_and_collisions(self):
        sql("DELETE FROM auth_limits")
        email="google-"+uuid.uuid4().hex+"@example.test"
        sql("INSERT INTO users(id,name,email) VALUES(?,?,?)",("access:"+uuid.uuid4().hex,"Google user",email))
        self.assertEqual(req("/api/auth/signup",{"name":"Collision","email":email,"password":"runtime password example"})[0],409)
        self.assertEqual(req("/api/auth/login",{"email":email,"password":"runtime password example"})[0],401)
        data={"name":"Staff","email":"staff@example.test","password":"runtime staff password"}
        # This email is in ADMIN_EMAILS but password signup cannot grant privileges.
        sql("DELETE FROM password_sessions WHERE userId IN (SELECT id FROM users WHERE email=?)",(data["email"],))
        sql("DELETE FROM password_credentials WHERE userId IN (SELECT id FROM users WHERE email=?)",(data["email"],))
        sql("DELETE FROM users WHERE email=?",(data["email"],))
        status,result,_=req("/api/auth/signup",data)
        self.assertEqual(status,200,result);self.assertEqual(result["user"]["role"],"member")
        for path in ("/api/auth/signup","/api/auth/login","/api/auth/password","/api/logout"):
            self.assertEqual(req(path,{},extra={"Origin":"https://attacker.example"})[0],403)
            self.assertEqual(req(path,{},extra={"Sec-Fetch-Site":"cross-site"})[0],403)
        self.assertEqual(req("/api/dev/session",{"role":"admin"})[0],404)
        self.assertIsNone(req("/api/session",cookie="cuse_password_session="+("f"*64))[1]["user"])
        self.assertEqual(req("/api/auth/signup",{"email":"large@example.test","password":"x"*5000})[0],413)
    def test_throttle(self):
        sql("DELETE FROM auth_limits")
        data={"email":"unknown@example.test","password":"runtime password example"}
        for _ in range(10):self.assertEqual(req("/api/auth/login",data)[0],401)
        self.assertEqual(req("/api/auth/login",data)[0],429)
        # Atomic IP budget remains effective even with rotating email addresses.
        for i in range(29):self.assertEqual(req("/api/auth/login",{**data,"email":f"unknown{i}@example.test"})[0],401)
        self.assertEqual(req("/api/auth/login",{**data,"email":"different@example.test"})[0],429)
if __name__=="__main__":unittest.main()

