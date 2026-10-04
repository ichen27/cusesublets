import {useEffect,useRef} from 'react';
import L from 'leaflet';
import 'leaflet/dist/leaflet.css';
import {regions,type Place} from './model';
export default function MapPanel({places,areas=[],onArea,onPlace,large=false}:{places:Place[];areas?:string[];onArea?:(area:string)=>void;onPlace?:(id:string)=>void;large?:boolean}){
 const ref=useRef<HTMLDivElement>(null);
 useEffect(()=>{
  if(!ref.current)return;
  const map=L.map(ref.current,{scrollWheelZoom:false,zoomControl:large}).setView([43.037,-76.126],large?14:13);
  L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',{attribution:'© OpenStreetMap',maxZoom:18}).addTo(map);
  for(const [name,bounds]of Object.entries(regions)){
   const selected=areas.includes(name);
   if(!selected&&!onArea)continue;
   const label=document.createElement('span');label.textContent=name;
   L.rectangle(bounds,{color:selected?'#8b6ec8':'#b2a9c4',weight:1.5,fillOpacity:selected?.18:.03}).addTo(map).bindTooltip(label).on('click',()=>onArea?.(name));
  }
  places.filter(p=>!p.paused).forEach(p=>{const label=document.createElement('span');label.textContent=p.title;L.marker([p.lat,p.lng],{icon:L.divIcon({className:'price-pin',html:`<span>$${Number(p.price)}</span>`,iconSize:[58,30],iconAnchor:[29,15]})}).addTo(map).bindTooltip(label).on('click',()=>onPlace?.(p.id));});
  const observer=new ResizeObserver(()=>map.invalidateSize());observer.observe(ref.current);
  return()=>{observer.disconnect();map.remove();};
 },[places,areas,onArea,onPlace,large]);
 return <div ref={ref} className={'map-canvas '+(large?'large':'')} aria-label="Map of sample places and desired areas"/>;
}
