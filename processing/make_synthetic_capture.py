"""Create a tiny camera/transport fixture. It does not depict or validate a real room."""
import io
import json
from pathlib import Path
import sys
import tarfile
from PIL import Image

def write(path):
    frames=[]
    image=io.BytesIO();Image.new('RGB',(96,64),(70,120,160)).save(image,format='JPEG')
    for i in range(30):
        transform=[[1,0,0,i*.02],[0,1,0,0],[0,0,1,0],[0,0,0,1]]
        frames.append(dict(file_path=f'images/{i:05}.jpg',timestamp=i*.6,width=96,height=64,
            fx=80,fy=80,cx=48,cy=32,transform_matrix=transform,tracking='normal',
            points=[[i*.02+x*.03,y*.03,-2] for x in range(-5,6) for y in range(-5,6)]))
    manifest=dict(schema_version=1,source='arkit',coordinate_system='arkit-camera-to-world',capability='camera',frames=frames)
    path.parent.mkdir(parents=True,exist_ok=True)
    with tarfile.open(path,'w',format=tarfile.USTAR_FORMAT) as archive:
        for name,data in [('manifest.json',json.dumps(manifest).encode())]+[(f['file_path'],image.getvalue()) for f in frames]:
            info=tarfile.TarInfo(name);info.size=len(data);info.mode=0o600;archive.addfile(info,io.BytesIO(data))
if __name__=='__main__':write(Path(sys.argv[1]))
