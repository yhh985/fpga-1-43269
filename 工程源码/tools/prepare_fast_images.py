"""Create separate, aspect-fitted RGB24 BMPs for the 640x480 FPGA display.

Usage: python tools/prepare_fast_images.py INPUT_DIRECTORY OUTPUT_DIRECTORY
Never modifies the originals or overwrites existing output files.
"""
import argparse,json
from pathlib import Path
from PIL import Image,ImageOps

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('input',type=Path)
    ap.add_argument('output',type=Path)
    args=ap.parse_args()
    source=args.input.resolve();target=args.output.resolve()
    if not source.is_dir() or source==target:
        ap.error('Input must be an existing directory, different from output')
    images=sorted(p for p in source.iterdir() if p.suffix.lower() in {'.bmp','.png','.jpg','.jpeg','.webp'})
    if not images:ap.error('No supported images in input directory')
    if len(images)>32:ap.error('This FPGA project supports at most 32 pictures; select up to 32 first')
    outputs=[target/f'PIC{i:03}.BMP' for i in range(1,len(images)+1)]
    manifest=target/'images_manifest.json'
    if any(p.exists() for p in outputs+[manifest]):ap.error('Output files already exist; choose a new directory')
    target.mkdir(parents=True,exist_ok=True)
    rows=[]
    for path,out in zip(images,outputs):
        with Image.open(path) as raw:
            im=ImageOps.exif_transpose(raw).convert('RGBA')
            base=Image.new('RGBA',im.size,(0,0,0,255));base.alpha_composite(im)
            fitted=ImageOps.contain(base.convert('RGB'),(640,480),Image.Resampling.LANCZOS)
            canvas=Image.new('RGB',(640,480));canvas.paste(fitted,((640-fitted.width)//2,(480-fitted.height)//2))
            canvas.save(out,format='BMP')
            rows.append(dict(source=str(path),source_size=list(im.size),output=out.name,bytes=out.stat().st_size))
    manifest.write_text(json.dumps(rows,ensure_ascii=False,indent=2),encoding='utf-8')
    print(f'Created {len(rows)} RGB24 BMPs, each 640x480 / 921654 bytes, in {target}')
    print('Copy only these BMPs to the FAT32 card root. Keep original images on the computer.')

if __name__=='__main__':main()
