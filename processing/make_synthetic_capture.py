"""Create camera/transport fixtures (walk-around, or --spots for a version 2 spot capture). They do
not depict or validate a real room."""
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
def write_spots(path, spots=((0.0, 0.0, 0.0), (1.5, 0.0, -0.5))):
    """A version 2 spot archive: every spot's slices rendered from a synthetic sphere."""
    import cv2
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import spot_synthetic as syn
    sphere = syn.test_sphere(2048)
    frames, records, files = [], [], []
    for number, position in enumerate(spots, start=1):
        names = []
        for yaw, pitch in syn.layout():
            name = f'images/{len(frames):05d}.jpg'
            rotation = syn.arkit_rotation(yaw + 0.3 * number, pitch)
            ok, jpeg = cv2.imencode('.jpg', syn.render_slice(sphere, rotation), [cv2.IMWRITE_JPEG_QUALITY, 80])
            frames.append(syn.frame_record(name, rotation, position=position, spot=number))
            files.append((name, jpeg.tobytes()))
            names.append(name)
        records.append(dict(spot=number, slices=names, position=list(position), floor_y=-1.45,
                            start_yaw=0.3 * number, exposure_duration=1 / 60, iso=400))
    manifest = dict(schema_version=2, source='arkit', coordinate_system='arkit-camera-to-world',
                    capability='camera', capture='spots', frames=frames, spots=records)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(path, 'w', format=tarfile.USTAR_FORMAT) as archive:
        for name, data in [('manifest.json', json.dumps(manifest).encode())] + files:
            info = tarfile.TarInfo(name); info.size = len(data); info.mode = 0o600; archive.addfile(info, io.BytesIO(data))

if __name__=='__main__':
    if sys.argv[1:2] == ['--spots']:write_spots(Path(sys.argv[2]))
    else:write(Path(sys.argv[1]))
