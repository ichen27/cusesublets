import {describe,it,expect} from 'vitest';
import {fit,places,defaultSearch,searchReady,people} from '../prototype/model';
describe('community prototype housing fit',()=>{
 it('requires complete dates and at least one desired area',()=>{
 expect(searchReady({...defaultSearch,areas:[]})).toBe(false);
 expect(searchReady({...defaultSearch,end:'2026-01-01'})).toBe(false);
 });
 it('matches only full housing fits and excludes owned places',()=>{
 expect(fit(places[0],defaultSearch)).not.toBeNull();
 expect(fit(places[0],{...defaultSearch,budget:100})).toBeNull();
 expect(fit(places[0],{...defaultSearch,areas:['Downtown']})).toBeNull();
 expect(fit({...places[0],owner:'you'},defaultSearch)).toBeNull();
 expect(fit(places[0],{...defaultSearch,end:'2028-12-31'})).toBeNull();
 });
 it('host perspective can use the same fit without owner exclusion',()=>{
 expect(fit({...places[0],owner:'you'},people[0].search,false)).not.toBeNull();
 });
});
