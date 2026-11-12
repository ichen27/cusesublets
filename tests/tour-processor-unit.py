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

if __name__=='__main__':unittest.main()
