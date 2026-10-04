import {useEffect,useRef,type ReactNode} from 'react';
import {X,ArrowRight,CheckCircle2} from 'lucide-react';
export function Avatar({src,name,size=''}:{src?:string;name:string;size?:string}){return <span className={'avatar '+size}>{src?<img src={src} alt="" onError={e=>{e.currentTarget.style.display='none';}}/>:name.split(' ').map(n=>n[0]).slice(0,2).join('')}</span>;}
export function Arrow(){return <ArrowRight size={17}/>;}
export function CheckBadge({checked}:{checked:boolean}){return <span className={'check-badge '+(checked?'':'pending')}><CheckCircle2 size={13}/>{checked?'Lease checked':'Documents not checked'}</span>;}
export function Modal({title,children,onClose,wide=false}:{title:string;children:ReactNode;onClose:()=>void;wide?:boolean}){
 const ref=useRef<HTMLDialogElement>(null),closeRef=useRef(onClose);closeRef.current=onClose;
 useEffect(()=>{const prev=document.activeElement as HTMLElement|null;const d=ref.current;d?.showModal();const cancel=(e:Event)=>{e.preventDefault();closeRef.current();};d?.addEventListener('cancel',cancel);document.body.style.overflow='hidden';return()=>{d?.removeEventListener('cancel',cancel);d?.close();document.body.style.overflow='';prev?.focus();};},[]);
 return <dialog ref={ref} className={'dialog '+(wide?'wide':'')} onClick={e=>{if(e.target===e.currentTarget)onClose();}}><div className="dialog-body"><header><h2>{title}</h2><button className="icon-button" aria-label="Close dialog" onClick={onClose}><X size={22}/></button></header>{children}</div></dialog>;
}
