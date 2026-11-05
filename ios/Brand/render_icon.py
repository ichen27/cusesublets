"""Render the editable house-mark geometry to Apple's opaque 1024px icon. Requires Pillow."""
from pathlib import Path
from PIL import Image, ImageDraw
scale=4
im=Image.new('RGB',(1024*scale,1024*scale),'#D14717');d=ImageDraw.Draw(im)
def pts(values):return [(int(x*scale),int(y*scale)) for x,y in values]
d.polygon(pts([(180,463),(512,194),(844,463),(778,545),(748,521),(748,800),(276,800),(276,521),(246,545)]),fill='#FFF8EE')
d.rectangle((425*scale,582*scale,599*scale,800*scale),fill='#D14717')
d.ellipse((425*scale,493*scale,599*scale,667*scale),fill='#D14717')
d.ellipse((538*scale,646*scale,570*scale,678*scale),fill='#FFF8EE')
im.resize((1024,1024),Image.Resampling.LANCZOS).save(Path(__file__).resolve().parents[1]/'CuseSublets/Assets.xcassets/AppIcon.appiconset/AppIcon.png')
