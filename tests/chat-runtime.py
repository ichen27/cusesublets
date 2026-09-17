"""Run only on isolated local demo persistence: API_BASE=http://127.0.0.1:8920 python3 tests/chat-runtime.py."""
import importlib.util, pathlib, unittest, sqlite3, concurrent.futures, json
spec=importlib.util.spec_from_file_location("runtime",pathlib.Path(__file__).with_name("api-runtime.py"))
runtime=importlib.util.module_from_spec(spec);spec.loader.exec_module(runtime)
Client=runtime.Client

class Chat(unittest.TestCase):
 def test_migration_backfill(self):
  db=sqlite3.connect(":memory:")
  root=pathlib.Path(__file__).resolve().parents[1]
  for name in ["0001_initial.sql","0002_transaction_guards.sql","0003_moderation.sql"]:
   db.executescript((root/"migrations"/name).read_text())
  db.executescript((root/"seeds/demo.sql").read_text())
  db.execute("INSERT INTO offers VALUES('old','walnut-sunroom','demo-renter','demo-host',700,'2027-01-01','2027-02-01','pending')")
  db.executescript((root/"migrations/0004_conversations.sql").read_text())
  self.assertEqual(db.execute("SELECT count(*) FROM conversations").fetchone()[0],1)
  c=db.execute("SELECT id FROM conversations").fetchone()[0]
  self.assertEqual(db.execute("SELECT conversationId,proposedBy,kind FROM offers WHERE id='old'").fetchone(),(c,"demo-renter","offer"))
  self.assertEqual(db.execute("SELECT count(*) FROM messages").fetchone()[0],2)

 def test_chat_flow_and_guards(self):
  renter,host,admin,guest=Client(),Client(),Client(),Client()
  for c,r in [(renter,"renter"),(host,"host"),(admin,"admin")]:c.login(r)
  payload=dict(title="Chat runtime property",neighborhood="Westcott",address="Near Westcott",price=800,beds=1,baths=1,roomType="Private room",startDate="2027-01-01",endDate="2027-08-01",description="Isolated integration test only; not a real property.",amenities=[],images=[])
  key=host.call("/api/listings",payload)[1]["listing"]["id"]
  lease=host.upload('/api/listings/'+key+'/documents','lease')[1]['document']['id']
  permission=host.upload('/api/listings/'+key+'/documents','permission')[1]['document']['id']
  identity=host.upload('/api/profile/identity')[1]['document']['id']
  self.assertEqual(admin.call('/api/admin/identities/demo-host/review',dict(status='verified',reason='Sample identity review',documentId=identity))[0],200)
  review=dict(leaseDocumentId=lease,permissionDocumentId=permission,status="approved",leaseStatus="verified",permissionStatus="verified",reason="PRIVATE-REVIEW-MARKER for chat test")
  self.assertEqual(renter.call("/api/conversations",dict(listingId=key))[0],201)
  self.assertEqual(admin.call("/api/admin/listings/"+key+"/review",review)[0],200)
  try:
   self.assertEqual(guest.call("/api/conversations")[0],401)
   self.assertEqual(host.call("/api/conversations",dict(listingId=key))[0],400)
   code,result=renter.call("/api/conversations",dict(listingId=key));self.assertEqual(code,201,result)
   c=result["conversation"]["id"];path="/api/conversations/"+c
   self.assertEqual(renter.call("/api/conversations",dict(listingId=key))[1]["conversation"]["id"],c)
   self.assertEqual(admin.call(path)[0],403)
   detail=renter.call(path)[1]
   self.assertEqual(detail["messages"],[])
   self.assertNotIn("reviewNote",detail["listing"])
   self.assertEqual(detail["peer"]["id"],"demo-host")
   self.assertEqual(admin.call(path+"/messages",dict(body="Unauthorized"))[0],403)
   self.assertEqual(renter.call(path+"/messages",dict(body="Hello from the listing"))[0],201)
   self.assertEqual(host.call("/api/messages",dict(listingId=key,recipientId="demo-renter",body="Legacy reply"))[0],201)
   self.assertEqual(len(renter.call(path)[1]["messages"]),2)
   self.assertIn(c,[x["id"] for x in host.call("/api/conversations")[1]["conversations"]])
   self.assertEqual(renter.upload(path+"/documents",data=b"not a PDF")[0],400)
   self.assertEqual(renter.upload(path+"/documents",data=b"%PDF-"+b"x"*(5*1024*1024))[0],413)
   status,result=renter.upload(path+"/documents",data=b"%PDF-1.4 test")
   self.assertEqual(status,201,result);doc=result["attachment"]["id"]
   for client,expected in [(guest,401),(admin,403),(host,200),(renter,200)]:
    self.assertEqual(client.raw("/api/chat-documents/"+doc)[0],expected)
   _,headers,content=host.raw("/api/chat-documents/"+doc)
   self.assertEqual(content,b"%PDF-1.4 test")
   self.assertIn("no-store",headers["Cache-Control"])
   self.assertIn("attachment",headers["Content-Disposition"])
   self.assertNotIn("objectKey",json.dumps(renter.call(path)[1]))
   proposal=dict(amount=700,startDate="2027-02-01",endDate="2027-03-01",kind="request")
   oid=renter.call(path+"/offers",proposal)[1]["offer"]["id"]
   self.assertEqual(renter.call("/api/offers/"+oid+"/accept",{})[0],403)
   self.assertEqual(admin.call("/api/offers/"+oid+"/accept",{})[0],403)
   self.assertEqual(renter.call(path+"/offers",{**proposal,"parentOfferId":oid})[0],403)
   # Competing counters: exactly one replaces the pending parent.
   counter={**proposal,"amount":750,"parentOfferId":oid}
   with concurrent.futures.ThreadPoolExecutor() as pool:
    responses=list(pool.map(lambda _:host.call(path+"/offers",counter),range(2)))
   self.assertEqual(sorted(x[0] for x in responses),[201,409],responses)
   counter_id=next(x[1]["offer"]["id"] for x in responses if x[0]==201)
   self.assertEqual(host.call("/api/offers/"+oid+"/accept",{})[0],409)
   self.assertEqual(host.call("/api/offers/"+counter_id+"/accept",{})[0],403)
   with concurrent.futures.ThreadPoolExecutor() as pool:
    responses=list(pool.map(lambda _:renter.call("/api/offers/"+counter_id+"/accept",{}),range(2)))
   self.assertEqual(sorted(x[0] for x in responses),[201,409],responses)
   booking=next(x[1]["booking"] for x in responses if x[0]==201)
   self.assertEqual(booking["amount"],750)
   detail=renter.call(path)[1]
   self.assertEqual(len(detail["bookings"]),1)
   self.assertEqual(next(x["status"] for x in detail["offers"] if x["id"]==oid),"countered")
   self.assertIn("accepted",[x["kind"] for x in detail["events"]])
   # Legacy offers enter the thread; withdrawal and decline enforce proposer identity.
   oid=renter.call("/api/offers",{**proposal,"listingId":key,"startDate":"2027-04-01","endDate":"2027-05-01"})[1]["offer"]["id"]
   self.assertEqual(host.call("/api/offers/"+oid+"/withdraw",{})[0],403)
   self.assertEqual(host.call("/api/offers/"+oid+"/decline",{})[0],200)
   self.assertEqual(host.call("/api/offers/"+oid+"/accept",{})[0],409)
   oid=host.call(path+"/offers",{**proposal,"startDate":"2027-05-01","endDate":"2027-06-01"})[1]["offer"]["id"]
   self.assertEqual(host.call("/api/offers/"+oid+"/withdraw",{})[0],200)
   self.assertEqual(host.call("/api/offers/"+oid+"/withdraw",{})[0],409)
   # Decline and acceptance race: one final state, no accepted-but-declined booking.
   oid=renter.call(path+"/offers",{**proposal,"startDate":"2027-06-01","endDate":"2027-07-01"})[1]["offer"]["id"]
   with concurrent.futures.ThreadPoolExecutor() as pool:
    responses=list(pool.map(lambda a:host.call("/api/offers/"+oid+"/"+a,{}),["accept","decline"]))
   self.assertEqual(sum(x[0] in (200,201) for x in responses),1,responses)
   self.assertEqual(sum(x[0]==409 for x in responses),1,responses)
   self.assertEqual(renter.call(path+"/offers",{**proposal,"endDate":"2028-01-01"})[0],400)
   # Existing threads survive moderation; new proposals fail closed.
   self.assertEqual(admin.call("/api/admin/listings/"+key+"/review",{**review,"status":"paused"})[0],200)
   self.assertEqual(renter.call(path)[0],200)
   self.assertEqual(renter.call(path+"/offers",proposal)[0],409)
   admin.call("/api/admin/users/demo-renter/status",dict(suspended=True,reason="Chat test suspension"))
   self.assertEqual(renter.call(path)[0],200)
   self.assertEqual(renter.call(path+"/messages",dict(body="Blocked"))[0],403)
   self.assertEqual(host.call(path+"/offers",proposal)[0],409)
  finally:
   admin.call("/api/admin/users/demo-renter/status",dict(suspended=False,reason="Restore after chat test"))
   admin.call("/api/admin/listings/"+key+"/review",{**review,"status":"paused"})

if __name__=="__main__":unittest.main()
