"""Standard-library checks for processor cleanup ordering; no training dependency."""
import contextlib
import hashlib
import importlib.util
import io
from pathlib import Path
import sys
import tempfile
import types
import unittest
import urllib.error
from unittest.mock import Mock, patch
spec=importlib.util.spec_from_file_location('worker','processing/tour_worker.py');worker=importlib.util.module_from_spec(spec);spec.loader.exec_module(worker)

class ProcessorCleanup(unittest.TestCase):
 def test_timeout_stops_child_before_private_directory_cleanup(self):
  data=b'synthetic';process=Mock();process.poll.return_value=None
  api=Mock();api.request.return_value=io.BytesIO(data)
  job={'id':'synthetic','claim':'claim','inputSize':len(data),'inputHash':hashlib.sha256(data).hexdigest()}
  events=[]
  with tempfile.TemporaryDirectory() as root:
   @contextlib.contextmanager
   def directory(**kwargs):
    try:yield root
    finally:events.append('cleanup')
   with patch.object(worker.tempfile,'TemporaryDirectory',directory),patch.object(worker.subprocess,'Popen',return_value=process),patch.object(worker,'stop_process',side_effect=lambda _:events.append('stop')) as stop,patch.object(worker.time,'monotonic',side_effect=[0,8000]):
    worker.process_job(api,job,Path(root))
   self.assertLess(events.index('stop'),events.index('cleanup'),'Training must stop before private files are removed')
   api.json.assert_called_once_with('synthetic/fail',{'code':'timeout'},job=job)

class RoomMesh(unittest.TestCase):
 def run_job(self,mesh_error=None,with_mesh=True):
  data=b'synthetic';process=Mock();process.poll.return_value=0;process.returncode=0
  calls=[]
  def respond(path,payload=None,job=None,file=None,metadata=None):
   calls.append(path.split('/')[-1])
   if path.endswith('/mesh') and mesh_error:raise urllib.error.HTTPError(path,mesh_error,'rejected',{},None)
   return {'ok':True}
  api=Mock();api.request.return_value=io.BytesIO(data);api.json.side_effect=respond
  job={'id':'synthetic','claim':'claim','inputSize':len(data),'inputHash':hashlib.sha256(data).hexdigest()}
  with tempfile.TemporaryDirectory() as root:
   result=Path(root)/'training/result';(result/'mesh').mkdir(parents=True)
   (result/'display.json').write_text('{}');(result/'export_3000.ply').write_bytes(b'model')
   if with_mesh:(result/'mesh/room-mesh.ply').write_bytes(b'mesh');(result/'mesh/mesh.json').write_text('{}')
   @contextlib.contextmanager
   def directory(**kwargs):yield root
   with patch.object(worker.tempfile,'TemporaryDirectory',directory),patch.object(worker.subprocess,'Popen',return_value=process),patch.object(worker,'stop_process'):
    with contextlib.redirect_stdout(io.StringIO()):worker.process_job(api,job,Path(root))
  return calls
 def test_mesh_is_uploaded_before_the_model_completes(self):
  self.assertEqual(self.run_job(),['mesh','complete'])
 def test_without_a_mesh_the_tour_completes_as_before(self):
  self.assertEqual(self.run_job(with_mesh=False),['complete'])
 def test_a_rejected_mesh_does_not_fail_the_tour(self):
  self.assertEqual(self.run_job(mesh_error=400),['mesh','complete'])
 def test_a_lost_lease_during_mesh_upload_stops_before_completion(self):
  calls=self.run_job(mesh_error=409)
  self.assertNotIn('complete',calls);self.assertEqual(calls[-1],'fail')
 def test_a_failed_mesh_build_leaves_no_partial_files(self):
  fake=types.ModuleType('room_mesh');fake.MODEL='model'
  def broken(frames,out,model,log):(out/'room-mesh.ply').write_bytes(b'partial');raise RuntimeError('/private/path')
  fake.build_mesh=broken
  with tempfile.TemporaryDirectory() as root,patch.dict(sys.modules,{'room_mesh':fake}):
   out=Path(root)/'mesh';out.mkdir();log=io.StringIO()
   with contextlib.redirect_stdout(log):worker.build_optional_mesh(Path(root)/'frames',out)
   self.assertFalse((out/'room-mesh.ply').exists())
   self.assertIn('RuntimeError',log.getvalue());self.assertNotIn('/private/path',log.getvalue())

import json
import tarfile

def tar_with(path,entries):
 with tarfile.open(path,'w',format=tarfile.USTAR_FORMAT) as archive:
  for name,data,kind in entries:
   info=tarfile.TarInfo(name);info.mode=0o600
   if kind=='link':info.type=tarfile.SYMTYPE;info.linkname='/etc/passwd';archive.addfile(info)
   else:info.size=len(data);archive.addfile(info,io.BytesIO(data))

class SpotTours(unittest.TestCase):
 def test_bundle_offsets_point_at_jpegs(self):
  with tempfile.TemporaryDirectory() as root:
   root=Path(root);a=root/'a.jpg';b=root/'b.jpg';a.write_bytes(b'\xff\xd8first\xff\xd9');b.write_bytes(b'\xff\xd8second panorama\xff\xd9')
   bundle=root/'spots.bundle';ranges=worker.write_bundle(bundle,[('panos/01.jpg',a),('panos/02.jpg',b)],b'{"spots":[]}')
   data=bundle.read_bytes()
   for name,source in [('panos/01.jpg',a),('panos/02.jpg',b)]:
    offset,length=ranges[name]
    self.assertEqual(offset%512,0);self.assertEqual(data[offset:offset+length],source.read_bytes());self.assertEqual(data[offset:offset+2],b'\xff\xd8')
   with tarfile.open(bundle) as archive:self.assertEqual(archive.getnames(),['panos/01.jpg','panos/02.jpg','spots.json'])
 def test_extract_accepts_a_capture_and_returns_its_manifest(self):
  with tempfile.TemporaryDirectory() as root:
   root=Path(root);capture=root/'c.roomcapture'
   tar_with(capture,[('manifest.json',b'{"frames":[]}',None),('images/00000.jpg',b'\xff\xd8',None)])
   self.assertEqual(worker.extract_capture(capture,root/'out'),{'frames':[]})
   self.assertEqual((root/'out/images/00000.jpg').read_bytes(),b'\xff\xd8')
 def test_extract_rejects_links_and_unknown_names(self):
  for entries in ([('manifest.json',b'{}',None),('images/00000.jpg',b'',"link")],
                  [('manifest.json',b'{}',None),('run.sh',b'echo',None)],
                  [('manifest.json',b'{}',None),('images/../../x.jpg',b'',None)],
                  [('manifest.json',b'{}',None),('manifest.json',b'{}',None)],
                  [('images/00000.jpg',b'',None)]):
   with tempfile.TemporaryDirectory() as root,self.assertRaisesRegex(ValueError,'capture_invalid'):
    root=Path(root);capture=root/'c.roomcapture';tar_with(capture,entries);worker.extract_capture(capture,root/'out')
 def test_spot_jobs_allow_96_mb_inputs(self):
  self.assertEqual(worker.input_limit({'kind':'spots'}),96*1024*1024)
  self.assertEqual(worker.input_limit({'kind':'splat'}),64*1024*1024)
  self.assertEqual(worker.input_limit({}),64*1024*1024)
 def run_spot_job(self,returncode=0,error_code=None):
  data=b'synthetic';process=Mock();process.poll.return_value=returncode;process.returncode=returncode
  calls=[]
  def respond(path,payload=None,job=None,file=None,metadata=None):
   calls.append((path.split('/')[-1],file.name if file else payload));return {'ok':True}
  api=Mock();api.request.return_value=io.BytesIO(data);api.json.side_effect=respond
  job={'id':'synthetic','claim':'claim','inputSize':len(data),'inputHash':hashlib.sha256(data).hexdigest(),'kind':'spots'}
  with tempfile.TemporaryDirectory() as root:
   training=Path(root)/'training';result=training/'result';result.mkdir(parents=True)
   (result/'display.json').write_text(json.dumps({'method':'m','slices':29,'spots':[]}));(result/'spots.bundle').write_bytes(b'bundle')
   if error_code:(training/'error_code').write_text(error_code)
   @contextlib.contextmanager
   def directory(**kwargs):yield root
   with patch.object(worker.tempfile,'TemporaryDirectory',directory),patch.object(worker.subprocess,'Popen',return_value=process) as popen,patch.object(worker,'stop_process'):
    with contextlib.redirect_stdout(io.StringIO()):worker.process_job(api,job,Path(root))
   return calls,popen.call_args[0][0]
 def test_spot_job_dispatch(self):
  calls,command=self.run_spot_job()
  self.assertIn('--reconstruct-spots',command)
  self.assertEqual(calls,[('complete','spots.bundle')])
 def test_spot_incomplete_is_forwarded(self):
  calls,_=self.run_spot_job(returncode=2,error_code='spot_incomplete')
  self.assertEqual(calls,[('fail',{'code':'spot_incomplete'})])
 def test_unknown_child_error_codes_are_not_forwarded(self):
  calls,_=self.run_spot_job(returncode=2,error_code='/private/path')
  self.assertEqual(calls,[('fail',{'code':'processing_failed'})])

if __name__=='__main__':unittest.main()
