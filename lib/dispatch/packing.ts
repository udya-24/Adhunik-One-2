export const volume=(length:number,breadth:number,height:number)=>Math.max(0,length)*Math.max(0,breadth)*Math.max(0,height);
const orientations=(d:[number,number,number]):[number,number,number][]=>[[d[0],d[1],d[2]],[d[0],d[2],d[1]],[d[1],d[0],d[2]],[d[1],d[2],d[0]],[d[2],d[0],d[1]],[d[2],d[1],d[0]]];
export function theoreticalCapacity(pkg:[number,number,number],item:[number,number,number]){if([...pkg,...item].some(x=>x<=0))return 0;return Math.max(...orientations(item).map(([l,b,h])=>Math.floor(pkg[0]/l)*Math.floor(pkg[1]/b)*Math.floor(pkg[2]/h)))}
export const fitsAnyOrientation=(pkg:[number,number,number],item:[number,number,number])=>theoreticalCapacity(pkg,item)>0;
export const suggestedPackages=(quantity:number,capacity:number)=>capacity>0?Math.ceil(Math.max(0,quantity)/capacity):null;
export const utilization=(allocatedVolume:number,packageVolume:number)=>packageVolume>0?allocatedVolume/packageVolume*100:0;
